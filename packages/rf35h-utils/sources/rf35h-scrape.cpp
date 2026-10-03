// rf35h-scrape - miniature per le playlist di RetroArch, da ScreenScraper con
// ArcadeDB di riserva. E' lo scraper di devaOS (lume/src/scraper.cpp) portato
// a tool a riga di comando: stesso parser JSON minimo, stessa scelta delle
// fonti, stesso CRC; cambiano ingresso e uscita, che qui sono quelli di
// RetroArch.
//
//   ingresso  /storage/playlists/*.lpl   (path, label, crc32, db_name)
//   uscita    /storage/thumbnails/<db_name senza .lpl>/
//                Named_Boxarts/<label>.png    ScreenScraper box-2D / ArcadeDB flyer
//                Named_Snaps/<label>.png      ss / ingame
//                Named_Titles/<label>.png     sstitle / title
//             (.png o .jpg secondo i byte veri del file: RetroArch prova
//             entrambe, ma decodifica in base all'estensione)
//             con nel nome i caratteri &*/:`"<>?\| sostituiti da _, come fa
//             gfx_thumbnail_fill_content_img in RetroArch.
//   config    /storage/.config/rf35h/scraper.conf
//                DEVID= DEVPASSWORD=      credenziali developer ScreenScraper:
//                                         senza, l'API rifiuta ogni richiesta;
//                                         si chiedono sul sito e non sono qui.
//                SSID= SSPASSWORD=        account utente: alza la quota giornaliera
//                ONLY_MISSING=1           salta i giochi che hanno gia' la copertina
//                ARCADE=1                 ArcadeDB quando ScreenScraper non trova
//   stato     /storage/.config/rf35h/scraper.status  (il menu lo mostra)
//   log       /storage/.config/rf35h/scraper.log
//
//   rf35h-scrape                tutte le playlist
//   rf35h-scrape --all          come sopra ma anche i giochi gia' coperti
//   rf35h-scrape --region us    regione preferita per le copertine (eu us jp wor)
//   rf35h-scrape --playlist "Nintendo - Game Boy"
//   rf35h-scrape --status
//   rf35h-scrape --init         scrive un scraper.conf commentato da compilare
//
// Solo PNG: RetroArch sceglie il decoder dall'estensione e cerca .png, un JPEG
// rinominato non si carica; ScreenScraper dichiara il formato di ogni media e
// si prendono solo quelli png. A 512 px: e' la taglia di libretro-thumbnails,
// il server ridimensiona (maxwidth/maxheight), e su 640x480 non serve altro.
//
// Perche' ArcadeDB come seconda fonte e non altro: non vuole credenziali, non
// ha quote, e risponde per id MAME - proprio dove ScreenScraper e' piu' debole.
#include <curl/curl.h>
#include <dirent.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cctype>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <strings.h>
#include <string>
#include <vector>

static std::string ROOT = getenv("RF35H_ROOT") ? getenv("RF35H_ROOT") : "";   // test: radice alternativa a /storage
static std::string CONF_S, STATUS_S, LOG_S, PL_S, TH_S;
static const char *CONF, *STATUS, *LOG, *PLAYLISTS, *THUMBS;
static void initPaths() {
	CONF_S = ROOT + "/storage/.config/rf35h/scraper.conf"; STATUS_S = ROOT + "/storage/.config/rf35h/scraper.status";
	LOG_S = ROOT + "/storage/.config/rf35h/scraper.log"; PL_S = ROOT + "/storage/playlists"; TH_S = ROOT + "/storage/thumbnails";
	CONF = CONF_S.c_str(); STATUS = STATUS_S.c_str(); LOG = LOG_S.c_str(); PLAYLISTS = PL_S.c_str(); THUMBS = TH_S.c_str();
}
// Ganci di test, vuoti in produzione: gli endpoint sono redirigibili cosi' lo
// scraping si prova per intero contro un server locale (devaOS faceva uguale).
static std::string envOr(const char *k, const char *def) { const char *v = getenv(k); return (v && *v) ? v : def; }

static volatile sig_atomic_t g_stop = 0;
static void onsig(int) { g_stop = 1; }

// ------------------------------------------------------------------ utilita'
static FILE *g_log = nullptr;
static void logf(const char *fmt, ...) {
	if (!g_log) return;
	va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
	fputc('\n', g_log); fflush(g_log);
}
static void setStatus(const std::string &s) {
	FILE *f = fopen(STATUS, "w");
	if (!f) return;
	fputs(s.c_str(), f); fputc('\n', f); fclose(f);
}
static bool exists(const std::string &p) { struct stat st; return stat(p.c_str(), &st) == 0; }
static void mkdirs(const std::string &p) {
	std::string cur;
	for (size_t i = 0; i < p.size(); ++i) {
		cur += p[i];
		if (p[i] == '/' && cur.size() > 1) mkdir(cur.c_str(), 0755);
	}
	mkdir(p.c_str(), 0755);
}
static std::string basenameNoExt(const std::string &path) {
	// dentro un archivio: "a/b/game.zip#game.rom" -> l'archivio conta
	std::string p = path;
	const size_t h = p.find('#');
	if (h != std::string::npos) p = p.substr(0, h);
	const size_t s = p.rfind('/');
	if (s != std::string::npos) p = p.substr(s + 1);
	const size_t d = p.rfind('.');
	if (d != std::string::npos && d > 0) p = p.substr(0, d);
	return p;
}
static std::string fileName(const std::string &path) {   // "game.gb", senza cartelle
	std::string p = path;
	const size_t h = p.find('#');
	if (h != std::string::npos) p = p.substr(0, h);
	const size_t s = p.rfind('/');
	return (s != std::string::npos) ? p.substr(s + 1) : p;
}
static std::string romFile(const std::string &path) {
	std::string p = path;
	const size_t h = p.find('#');
	if (h != std::string::npos) p = p.substr(0, h);
	return p;
}
// Come gfx_thumbnail_fill_content_img: gli stessi caratteri, lo stesso ordine.
// Cartella delle miniature per un db_name, con le stesse regole di
// gfx_thumbnail_set_content_playlist: se il nome contiene "|" (piu' database
// dal core info) vale il primo; e qualunque nome che inizia con "MAME" va in
// "MAME", perche' esiste un solo repository di miniature MAME. Senza questa
// regola una playlist "MAME 2010" avrebbe le immagini dove RetroArch non guarda.
static std::string thumbDir(const std::string &db) {
	std::string d = db;
	const size_t bar = d.find('|');
	if (bar != std::string::npos) d = d.substr(0, bar);
	if (d.compare(0, 4, "MAME") == 0) return "MAME";
	return d;
}
static std::string thumbBase(const std::string &label) {   // senza estensione
	std::string s = label;
	for (char &c : s) if (strchr("&*/:`\"<>?\\|", c)) c = '_';
	return s;
}
// RetroArch prova .png e poi .jpg/.jpeg/.bmp/.tga con lo stesso nome
// (SUPPORTED_THUMBNAIL_EXTENSIONS in gfx_thumbnail_path.c).
static bool haveThumb(const std::string &base) {
	static const char *exts[] = { ".png", ".jpg", ".jpeg", ".bmp", ".tga" };
	for (const char *e : exts) if (exists(base + e)) return true;
	return false;
}
static std::string urlEncode(const std::string &s) {
	static const char *hex = "0123456789ABCDEF";
	std::string o;
	for (unsigned char c : s) {
		if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') o += (char)c;
		else { o += '%'; o += hex[c >> 4]; o += hex[c & 15]; }
	}
	return o;
}
static std::string trim(const std::string &s) {
	size_t a = 0, b = s.size();
	while (a < b && isspace((unsigned char)s[a])) ++a;
	while (b > a && isspace((unsigned char)s[b - 1])) --b;
	return s.substr(a, b - a);
}

// ------------------------------------------------------------------ CRC32
static uint32_t crcTable[256];
static bool crcInit = false;
static void initCrc() {
	for (uint32_t i = 0; i < 256; ++i) {
		uint32_t c = i;
		for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		crcTable[i] = c;
	}
	crcInit = true;
}
// Oltre maxBytes non si calcola: su una card lenta costa piu' di quanto rende.
static uint32_t crc32File(const std::string &path, size_t maxBytes, bool *ok) {
	*ok = false;
	if (!crcInit) initCrc();
	FILE *f = fopen(path.c_str(), "rb");
	if (!f) return 0;
	fseek(f, 0, SEEK_END); const long sz = ftell(f); fseek(f, 0, SEEK_SET);
	if (sz < 0 || (maxBytes && (size_t)sz > maxBytes)) { fclose(f); return 0; }
	uint32_t c = 0xFFFFFFFFu;
	static unsigned char buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
		for (size_t i = 0; i < n; ++i) c = crcTable[(c ^ buf[i]) & 0xFF] ^ (c >> 8);
	fclose(f);
	*ok = true;
	return c ^ 0xFFFFFFFFu;
}

// ------------------------------------------------------------------ HTTP
static size_t writeStr(void *p, size_t s, size_t n, void *u) { ((std::string*)u)->append((char*)p, s * n); return s * n; }
static size_t writeFile(void *p, size_t s, size_t n, void *u) { return fwrite(p, s, n, (FILE*)u); }
static long g_lastHttp = 0;   // codice dell'ultima httpGet, per distinguere "non trovato" da "rifiutato"
// Un solo handle per tutta la corsa: curl riusa la connessione (keep-alive) e
// la sessione TLS, quindi un handshake per host invece di uno per richiesta.
// Su centinaia di giochi e' la differenza fra minuti e decine di minuti.
static CURL *g_curl = nullptr;
static CURL *curlHandle() {
	if (!g_curl) g_curl = curl_easy_init();
	if (g_curl) {
		curl_easy_reset(g_curl);
		curl_easy_setopt(g_curl, CURLOPT_FOLLOWLOCATION, 1L);
		curl_easy_setopt(g_curl, CURLOPT_CONNECTTIMEOUT, 10L);
		curl_easy_setopt(g_curl, CURLOPT_USERAGENT, "rf35h-scrape/1.0");
		curl_easy_setopt(g_curl, CURLOPT_NOSIGNAL, 1L);
		curl_easy_setopt(g_curl, CURLOPT_TCP_KEEPALIVE, 1L);
	}
	return g_curl;
}
static bool httpGet(const std::string &url, std::string &out, long timeoutSec = 30) {
	CURL *c = curlHandle();
	if (!c) return false;
	out.clear();
	g_lastHttp = 0;
	curl_easy_setopt(c, CURLOPT_URL, url.c_str());
	curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, writeStr);
	curl_easy_setopt(c, CURLOPT_WRITEDATA, &out);
	curl_easy_setopt(c, CURLOPT_TIMEOUT, timeoutSec);
	const CURLcode rc = curl_easy_perform(c);
	long code = 0;
	curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
	g_lastHttp = code;
	return rc == CURLE_OK && code >= 200 && code < 300;
}
// Scarica in <base>.part, legge la firma e rinomina .png o .jpg: RetroArch
// sceglie il decoder dall'estensione, una JPEG chiamata .png non la carica.
// Tutto il resto (html di errore, gif, webp) si scarta.
static bool saveImage(const std::string &url, const std::string &base, long timeoutSec = 60) {
	const std::string tmp = base + ".part";
	FILE *f = fopen(tmp.c_str(), "wb");
	if (!f) return false;
	CURL *c = curlHandle();
	if (!c) { fclose(f); remove(tmp.c_str()); return false; }
	curl_easy_setopt(c, CURLOPT_URL, url.c_str());
	curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, writeFile);
	curl_easy_setopt(c, CURLOPT_WRITEDATA, f);
	curl_easy_setopt(c, CURLOPT_TIMEOUT, timeoutSec);
	const CURLcode rc = curl_easy_perform(c);
	long code = 0;
	curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
	fclose(f);
	struct stat st;
	if (rc != CURLE_OK || code < 200 || code >= 300 || stat(tmp.c_str(), &st) != 0 || st.st_size < 100) {
		remove(tmp.c_str()); return false;
	}
	unsigned char sig[8] = { 0 };
	FILE *r = fopen(tmp.c_str(), "rb");
	if (r) { if (fread(sig, 1, 8, r) < 8) memset(sig, 0, 8); fclose(r); }
	const char *ext = nullptr;
	if (!memcmp(sig, "\x89PNG\r\n\x1a\n", 8)) ext = ".png";
	else if (sig[0] == 0xFF && sig[1] == 0xD8 && sig[2] == 0xFF) ext = ".jpg";
	if (!ext) { remove(tmp.c_str()); return false; }
	// Scrittura atomica: mezza immagine e' peggio di nessuna.
	return rename(tmp.c_str(), (base + ext).c_str()) == 0;
}

// ------------------------------------------------------------------ JSON minimo
// Non un parser generale: cammina sulla stringa rispettando virgolette ed
// escape e risolve percorsi di chiavi. Basta, e non ha dipendenze. (devaOS)
static size_t skipWs(const std::string &s, size_t i) { while (i < s.size() && isspace((unsigned char)s[i])) ++i; return i; }
static size_t skipString(const std::string &s, size_t i) {
	++i;
	while (i < s.size()) {
		if (s[i] == '\\') { i += 2; continue; }
		if (s[i] == '"') return i + 1;
		++i;
	}
	return i;
}
static size_t skipValue(const std::string &s, size_t i) {
	i = skipWs(s, i);
	if (i >= s.size()) return i;
	if (s[i] == '"') return skipString(s, i);
	if (s[i] == '{' || s[i] == '[') {
		const char open = s[i], close = (open == '{') ? '}' : ']';
		int depth = 0;
		while (i < s.size()) {
			if (s[i] == '"') { i = skipString(s, i); continue; }
			if (s[i] == open) ++depth;
			else if (s[i] == close) { --depth; if (!depth) return i + 1; }
			++i;
		}
		return i;
	}
	while (i < s.size() && s[i] != ',' && s[i] != '}' && s[i] != ']') ++i;
	return i;
}
static std::string unescape(const std::string &s) {
	std::string o;
	for (size_t i = 0; i < s.size(); ++i) {
		if (s[i] == '\\' && i + 1 < s.size()) {
			++i;
			switch (s[i]) {
			case 'n': o += '\n'; break;
			case 't': o += '\t'; break;
			case 'u': i += 4; o += '?'; break;
			default: o += s[i];
			}
		} else o += s[i];
	}
	return o;
}
static size_t objFind(const std::string &s, size_t from, const std::string &key) {
	size_t i = skipWs(s, from);
	if (i >= s.size() || s[i] != '{') return std::string::npos;
	++i;
	while (i < s.size()) {
		i = skipWs(s, i);
		if (i >= s.size() || s[i] == '}') return std::string::npos;
		if (s[i] != '"') return std::string::npos;
		const size_t ks = i + 1, ke = skipString(s, i) - 1;
		const std::string k = s.substr(ks, ke - ks);
		i = skipWs(s, ke + 1);
		if (i < s.size() && s[i] == ':') ++i;
		i = skipWs(s, i);
		if (k == key) return i;
		i = skipValue(s, i);
		i = skipWs(s, i);
		if (i < s.size() && s[i] == ',') ++i;
	}
	return std::string::npos;
}
static bool scalarAt(const std::string &s, size_t i, std::string &out) {
	i = skipWs(s, i);
	if (i >= s.size()) return false;
	if (s[i] == '"') { const size_t e = skipString(s, i); out = unescape(s.substr(i + 1, e - i - 2)); return true; }
	const size_t e = skipValue(s, i);
	out = s.substr(i, e - i);
	return !out.empty();
}
static bool jsonFind(const std::string &json, size_t from, const std::vector<std::string> &path, std::string &out) {
	size_t i = from;
	for (const std::string &k : path) { i = objFind(json, i, k); if (i == std::string::npos) return false; }
	return scalarAt(json, i, out);
}
template <typename F>
static bool forEachInArray(const std::string &s, size_t arr, F fn) {
	size_t i = skipWs(s, arr);
	if (i >= s.size() || s[i] != '[') return false;
	++i;
	while (i < s.size()) {
		i = skipWs(s, i);
		if (i >= s.size() || s[i] == ']') return false;
		const size_t start = i;
		i = skipValue(s, i);
		if (fn(start, i)) return true;
		i = skipWs(s, i);
		if (i < s.size() && s[i] == ',') ++i;
	}
	return false;
}
// Un media di ScreenScraper del tipo voluto, preferendo le regioni nell'ordine
// dato (wor, eu, us, jp) e poi qualunque: cosi' una copertina europea vince su
// una giapponese quando ci sono entrambe, e una giapponese vince sul niente.
static std::vector<std::string> g_regions = { "eu", "wor", "us", "jp" };
static void setRegion(const std::string &r) {
	if (r == "us")       g_regions = { "us", "wor", "eu", "jp" };
	else if (r == "jp")  g_regions = { "jp", "wor", "eu", "us" };
	else if (r == "wor") g_regions = { "wor", "eu", "us", "jp" };
	else                 g_regions = { "eu", "wor", "us", "jp" };
}
static bool ssMediaUrl(const std::string &json, const char *type, std::string &out) {
	size_t jeu = objFind(json, 0, "response");
	if (jeu == std::string::npos) return false;
	jeu = objFind(json, jeu, "jeu");
	if (jeu == std::string::npos) return false;
	const size_t medias = objFind(json, jeu, "medias");
	if (medias == std::string::npos) return false;
	std::vector<std::string> order = g_regions; order.push_back("");   // "" = qualunque regione
	for (const std::string &reg : order) {
		std::string url;
		const bool hit = forEachInArray(json, medias, [&](size_t a, size_t b) {
			const std::string obj = json.substr(a, b - a);
			std::string t, u, r, f;
			if (!jsonFind(obj, 0, { "type" }, t) || t != type) return false;
			if (!reg.empty()) { if (!jsonFind(obj, 0, { "region" }, r) || r != reg) return false; }
			if (jsonFind(obj, 0, { "format" }, f) && f != "png") return false;   // solo PNG
			if (!jsonFind(obj, 0, { "url" }, u)) return false;
			url = u; return true;
		});
		if (hit) { out = url + "&maxwidth=512&maxheight=512"; return true; }
	}
	return false;
}
// ArcadeDB risponde con un oggetto piatto dentro "result": [ ]; i campi hanno
// nomi unici, si leggono per chiave direttamente. (devaOS, verificato sulla
// risposta vera.)
static bool flatField(const std::string &body, const char *key, std::string &out) {
	const std::string pat = std::string("\"") + key + "\"";
	const size_t k = body.find(pat);
	if (k == std::string::npos) return false;
	const size_t c = body.find(':', k + pat.size());
	if (c == std::string::npos) return false;
	const size_t q1 = body.find('"', c);
	if (q1 == std::string::npos) return false;
	std::string v;
	for (size_t i = q1 + 1; i < body.size(); ++i) {
		if (body[i] == '\\' && i + 1 < body.size()) { v += body[i + 1]; ++i; continue; }
		if (body[i] == '"') break;
		v += body[i];
	}
	out = v;
	return !out.empty();
}

// ------------------------------------------------------------------ sistemi
// db_name di RetroArch -> systemeid di ScreenScraper. Aiuta il match per nome
// quando il CRC non c'e' o non e' noto; senza, ScreenScraper cerca tra tutte
// le piattaforme. 0 = non passare systemeid.
struct SysMap { const char *db; int ssid; bool arcade; };
static const SysMap SYSTEMS[] = {
	{ "Nintendo - Game Boy",                    9, false }, { "Nintendo - Game Boy Color",           10, false },
	{ "Nintendo - Game Boy Advance",           12, false }, { "Nintendo - Nintendo Entertainment System", 3, false },
	{ "Nintendo - Super Nintendo Entertainment System", 4, false }, { "Nintendo - Nintendo 64",     14, false },
	{ "Nintendo - Nintendo DS",                15, false }, { "Nintendo - Family Computer Disk System", 106, false },
	{ "Sega - Mega Drive - Genesis",            1, false }, { "Sega - Master System - Mark III",     2, false },
	{ "Sega - Game Gear",                      21, false }, { "Sega - 32X",                          19, false },
	{ "Sega - Mega-CD - Sega CD",              20, false }, { "Sega - Dreamcast",                    23, false },
	{ "Sega - SG-1000",                       109, false },
	{ "NEC - PC Engine - TurboGrafx 16",       31, false }, { "NEC - PC Engine SuperGrafx",         105, false },
	{ "NEC - PC Engine CD - TurboGrafx-CD",   114, false },
	{ "SNK - Neo Geo Pocket",                  25, false }, { "SNK - Neo Geo Pocket Color",          82, false },
	{ "Atari - 2600",                          26, false }, { "Atari - Lynx",                        28, false },
	{ "Amstrad - CPC",                         65, false }, { "Sony - PlayStation",                  57, false },
	{ "Bandai - WonderSwan",                   45, false }, { "Bandai - WonderSwan Color",           46, false },
	{ "FBNeo - Arcade Games",                  75, true  }, { "MAME",                                75, true  },
	{ "MAME 2003-Plus",                        75, true  }, { "MAME 2010",                           75, true  },
	{ "MAME 2015",                             75, true  }, { "SNK - Neo Geo",                      142, true  },
	{ "Arcade",                                75, true  },
};
static const SysMap *findSystem(const std::string &db) {
	for (const SysMap &m : SYSTEMS) if (db == m.db) return &m;
	// prefissi: "MAME 2010", "FBNeo - ..." e simili gia' coperti; arcade per nome
	if (db.find("MAME") != std::string::npos || db.find("FBNeo") != std::string::npos ||
	    db.find("FinalBurn") != std::string::npos || db.find("Arcade") != std::string::npos) {
		static const SysMap arcade = { "", 75, true };
		return &arcade;
	}
	return nullptr;
}

// ------------------------------------------------------------------ config
struct Conf { std::string devId, devPass, user, pass, region = "eu"; bool onlyMissing = true, arcade = true; };
static Conf readConf() {
	Conf c;
	FILE *f = fopen(CONF, "r");
	if (!f) return c;
	char line[512];
	while (fgets(line, sizeof(line), f)) {
		std::string l = trim(line);
		if (l.empty() || l[0] == '#') continue;
		const size_t eq = l.find('=');
		if (eq == std::string::npos) continue;
		const std::string k = trim(l.substr(0, eq)), v = trim(l.substr(eq + 1));
		if (k == "DEVID") c.devId = v; else if (k == "DEVPASSWORD") c.devPass = v;
		else if (k == "SSID") c.user = v; else if (k == "SSPASSWORD") c.pass = v;
		else if (k == "ONLY_MISSING") c.onlyMissing = (v != "0"); else if (k == "ARCADE") c.arcade = (v != "0");
		else if (k == "REGION") c.region = v;
	}
	fclose(f);
	return c;
}

// ------------------------------------------------------------------ playlist
struct Item { std::string path, label, crc, db; };
static bool readFile(const std::string &p, std::string &out) {
	FILE *f = fopen(p.c_str(), "rb");
	if (!f) return false;
	char buf[65536]; size_t n;
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.append(buf, n);
	fclose(f);
	return true;
}
static void readPlaylist(const std::string &file, const std::string &defaultDb, std::vector<Item> &items) {
	std::string json;
	if (!readFile(file, json)) return;
	const size_t arr = objFind(json, 0, "items");
	if (arr == std::string::npos) return;
	forEachInArray(json, arr, [&](size_t a, size_t b) {
		const std::string obj = json.substr(a, b - a);
		Item it;
		jsonFind(obj, 0, { "path" }, it.path);
		jsonFind(obj, 0, { "label" }, it.label);
		jsonFind(obj, 0, { "crc32" }, it.crc);   // "XXXXXXXX|crc" oppure "00000000|crc"
		jsonFind(obj, 0, { "db_name" }, it.db);
		const size_t bar = it.crc.find('|');
		if (bar != std::string::npos) it.crc = it.crc.substr(0, bar);
		if (it.crc == "00000000" || it.crc.size() != 8) it.crc.clear();
		if (it.db.size() > 4 && it.db.compare(it.db.size() - 4, 4, ".lpl") == 0) it.db = it.db.substr(0, it.db.size() - 4);
		if (it.db.empty()) it.db = defaultDb;
		if (it.label.empty()) it.label = basenameNoExt(it.path);
		if (!it.path.empty()) items.push_back(it);
		return false;
	});
}

// ------------------------------------------------------------------ main
int main(int argc, char **argv) {
	initPaths();
	bool all = false, statusOnly = false, init = false;
	std::string onlyPlaylist, regionArg;
	for (int i = 1; i < argc; ++i) {
		const std::string a = argv[i];
		if (a == "--all") all = true;
		else if (a == "--status") statusOnly = true;
		else if (a == "--playlist" && i + 1 < argc) onlyPlaylist = argv[++i];
		else if (a == "--region" && i + 1 < argc) regionArg = argv[++i];
		else if (a == "--init") init = true;
		else { fprintf(stderr, "uso: rf35h-scrape [--all] [--region eu|us|jp|wor] [--playlist NOME] [--status] [--init]\n"); return 2; }
	}
	if (init) {
		mkdirs(ROOT + "/storage/.config/rf35h");
		if (exists(CONF)) { fprintf(stderr, "%s esiste gia', non lo tocco\n", CONF); return 1; }
		FILE *f = fopen(CONF, "w");
		if (!f) { perror(CONF); return 1; }
		fputs("# rf35h-scrape: credenziali e opzioni. Le credenziali developer di\n"
		      "# ScreenScraper si chiedono su screenscraper.fr (forum, sezione API):\n"
		      "# senza, l'API rifiuta ogni richiesta. L'account utente alza la quota.\n"
		      "DEVID=\nDEVPASSWORD=\nSSID=\nSSPASSWORD=\n"
		      "# eu | us | jp | wor : quale copertina vince quando ce n'e' piu' d'una\nREGION=eu\n"
		      "# 1 = salta i giochi che hanno gia' la copertina\nONLY_MISSING=1\n"
		      "# 1 = ArcadeDB (senza credenziali) quando ScreenScraper non trova un arcade\nARCADE=1\n", f);
		fclose(f);
		printf("scritto %s: compila DEVID e DEVPASSWORD\n", CONF);
		return 0;
	}
	if (statusOnly) {
		std::string s; if (readFile(STATUS, s)) fputs(s.c_str(), stdout); else puts("idle");
		return 0;
	}
	mkdirs(ROOT + "/storage/.config/rf35h");
	g_log = fopen(LOG, "w");
	Conf conf = readConf();
	if (all) conf.onlyMissing = false;
	setRegion(regionArg.empty() ? conf.region : regionArg);
	if (conf.devId.empty() || conf.devPass.empty()) {
		setStatus("error: no ScreenScraper credentials in scraper.conf");
		logf("DEVID/DEVPASSWORD mancanti in %s", CONF);
		fprintf(stderr, "rf35h-scrape: servono DEVID e DEVPASSWORD in %s\n", CONF);
		return 1;
	}
	{
		const std::string pidf = ROOT + "/storage/.config/rf35h/scraper.pid";
		std::string old;
		if (readFile(pidf, old) && kill(atoi(old.c_str()), 0) == 0 && atoi(old.c_str()) != getpid()) {
			fprintf(stderr, "rf35h-scrape: gia' in esecuzione (pid %s)\n", trim(old).c_str());
			return 1;
		}
		FILE *f = fopen(pidf.c_str(), "w"); if (f) { fprintf(f, "%d\n", getpid()); fclose(f); }
	}
	signal(SIGTERM, onsig); signal(SIGINT, onsig);
	curl_global_init(CURL_GLOBAL_DEFAULT);

	// playlist
	std::vector<Item> items;
	DIR *d = opendir(PLAYLISTS);
	if (!d) { setStatus("error: no playlists"); return 1; }
	struct dirent *e;
	while ((e = readdir(d))) {
		std::string n = e->d_name;
		if (n.size() < 5 || n.compare(n.size() - 4, 4, ".lpl") != 0) continue;
		if (n.rfind("content_", 0) == 0) continue;          // history, favorites, images, music, video
		const std::string db = n.substr(0, n.size() - 4);
		if (!onlyPlaylist.empty() && db != onlyPlaylist) continue;
		readPlaylist(std::string(PLAYLISTS) + "/" + n, db, items);
	}
	closedir(d);
	logf("%zu voci nelle playlist", items.size());
	if (items.empty()) { setStatus("done 0/0: no games in playlists"); return 0; }

	size_t done = 0, found = 0, failed = 0, skipped = 0;
	const size_t total = items.size();
	setStatus("running 0/" + std::to_string(total));
	auto withAuth = [&](std::string u) {
		if (!conf.user.empty())
			u += (u.find('?') == std::string::npos ? "?" : "&") + std::string("ssid=") + urlEncode(conf.user) + "&sspassword=" + urlEncode(conf.pass);
		return u;
	};
	for (const Item &it : items) {
		if (g_stop) { setStatus("stopped " + std::to_string(done) + "/" + std::to_string(total) + " found=" + std::to_string(found)); logf("interrotto"); return 0; }
		const std::string dir = std::string(THUMBS) + "/" + thumbDir(it.db);
		const std::string name = thumbBase(it.label);
		const std::string box = dir + "/Named_Boxarts/" + name, snap = dir + "/Named_Snaps/" + name, title = dir + "/Named_Titles/" + name;
		if (conf.onlyMissing && haveThumb(box)) { ++skipped; ++done; continue; }
		const SysMap *sys = findSystem(it.db);
		const std::string base = basenameNoExt(it.path);

		// CRC: dalla playlist se RetroArch l'ha calcolato, altrimenti dal file (fino a 64 MB).
		// Il CRC calcolato da noi vale solo per file nudi: quello di uno zip e'
		// il CRC dell'archivio, non della ROM, e un CRC sbagliato mandato a
		// ScreenScraper fa peggio di nessun CRC. Dentro la playlist invece
		// RetroArch mette il CRC del contenuto, anche per gli archivi.
		std::string crc = it.crc;
		const std::string rf = romFile(it.path);
		const bool archive = it.path.find('#') != std::string::npos ||
		    (rf.size() > 4 && (!strcasecmp(rf.c_str() + rf.size() - 4, ".zip") || !strcasecmp(rf.c_str() + rf.size() - 3, ".7z")));
		if (crc.empty() && !archive) {
			bool ok = false;
			const uint32_t c = crc32File(rf, 64u * 1024u * 1024u, &ok);
			if (ok) { char h[16]; snprintf(h, sizeof(h), "%08X", c); crc = h; }
		}
		std::string url = envOr("RF35H_SS_BASE", "https://api.screenscraper.fr/api2") + "/jeuInfos.php?output=json"
		    + "&devid=" + urlEncode(conf.devId) + "&devpassword=" + urlEncode(conf.devPass)
		    + "&softname=rf35h&romtype=rom&romnom=" + urlEncode(fileName(it.path));
		if (!conf.user.empty()) url += "&ssid=" + urlEncode(conf.user) + "&sspassword=" + urlEncode(conf.pass);
		if (!crc.empty()) url += "&crc=" + crc;
		if (sys && sys->ssid) url += "&systemeid=" + std::to_string(sys->ssid);

		std::string body;
		bool got = false;
		mkdirs(dir + "/Named_Boxarts"); mkdirs(dir + "/Named_Snaps"); mkdirs(dir + "/Named_Titles");
		const bool ssOk = httpGet(url, body);
		if (!ssOk && (g_lastHttp == 401 || g_lastHttp == 403 || body.find("Erreur de login") != std::string::npos)) {
			setStatus("error: ScreenScraper rejected the credentials (check scraper.conf)");
			logf("HTTP %ld: credenziali rifiutate, mi fermo", g_lastHttp);
			return 1;
		}
		if (!ssOk && (g_lastHttp == 429 || g_lastHttp == 430 || g_lastHttp == 431)) {
			setStatus("error: ScreenScraper quota exhausted, try again tomorrow (" + std::to_string(done) + "/" + std::to_string(total) + " done, found=" + std::to_string(found) + ")");
			logf("HTTP %ld: quota esaurita a %zu/%zu", g_lastHttp, done, total);
			return 1;
		}
		if (ssOk && body.find("\"jeu\"") != std::string::npos) {
			std::string u;
			if (!haveThumb(box)   && (ssMediaUrl(body, "box-2D", u) || ssMediaUrl(body, "flyer", u))) got |= saveImage(withAuth(u), box);
			else if (haveThumb(box)) got = true;
			if (!haveThumb(snap)  && ssMediaUrl(body, "ss", u))      saveImage(withAuth(u), snap);
			if (!haveThumb(title) && ssMediaUrl(body, "sstitle", u)) saveImage(withAuth(u), title);
			// Un gioco arcade senza box: ScreenScraper da' spesso solo schermate.
			// Se non c'e' la copertina, la locandina di ArcadeDB e' la copertina.
		}
		if (!haveThumb(box) && conf.arcade && sys && sys->arcade) {
			const std::string aurl = envOr("RF35H_ADB_BASE", "http://adb.arcadeitalia.net") + "/service_scraper.php?ajax=query_mame&game_name=" + urlEncode(base);
			std::string abody, img;
			if (httpGet(aurl, abody) && abody.find("\"title\"") != std::string::npos) {
				// Locandina prima: i giochi arcade non avevano scatole, e la
				// locandina e' quello che uno scaffale di copertine vuole.
				if (!haveThumb(box)   && (flatField(abody, "url_image_flyer", img) || flatField(abody, "url_image_title", img))) got |= saveImage(img, box);
				if (!haveThumb(snap)  && flatField(abody, "url_image_ingame", img)) saveImage(img, snap);
				if (!haveThumb(title) && flatField(abody, "url_image_title", img))  saveImage(img, title);
			}
		}
		if (got || haveThumb(box)) { ++found; logf("ok    %s", it.label.c_str()); }
		else { ++failed; logf("nulla %s (%s%s)", it.label.c_str(), base.c_str(), crc.empty() ? "" : (", crc " + crc).c_str()); }
		++done;
		setStatus("running " + std::to_string(done) + "/" + std::to_string(total) + " found=" + std::to_string(found));
		usleep(150000);   // ScreenScraper ha quote per minuto: un po' di respiro
	}
	setStatus("done " + std::to_string(total) + ": found=" + std::to_string(found) + " missing=" + std::to_string(failed) + " skipped=" + std::to_string(skipped));
	logf("fine: trovate %zu, mancanti %zu, saltate %zu", found, failed, skipped);
	if (g_curl) curl_easy_cleanup(g_curl);
	curl_global_cleanup();
	if (g_log) fclose(g_log);
	return 0;
}
