# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="ikemen-screenpack"
# Screenpack ufficiale di IKEMEN GO con Kung Fu Man e gli stage di base, cioe'
# le cartelle chars data font sound stages video che i rilasci ufficiali
# mettono accanto al motore. Il flusso di rilascio le prende da "master" senza
# fissarne la versione; questo commit (12/9/2026, il giorno dopo il tag v1.0.0)
# ha gli stessi file di gioco del rilascio: i commit successivi a quelli del
# 11/9 toccano solo i file di lavoro (PSD, work/), che qui non si installano.
PKG_VERSION="11d6ea7223fc15209664730503412841045f7939"
PKG_LICENSE="CC-BY-3.0 CC-BY-NC-3.0"
PKG_SITE="https://github.com/ikemen-engine/Ikemen_GO-Elecbyte-Screenpack"
PKG_URL="https://github.com/ikemen-engine/Ikemen_GO-Elecbyte-Screenpack.git"
PKG_GIT_SKIP_SUBMODULE="yes"
PKG_DEPENDS_TARGET="toolchain"
PKG_LONGDESC="Screenpack ufficiale di IKEMEN GO (menu, lifebar, Kung Fu Man, stage di base)."
PKG_TOOLCHAIN="manual"

makeinstall_target() {
  local d
  mkdir -p ${INSTALL}/usr/share/ikemen
  for d in chars data font sound stages video; do
    [ -d ${PKG_BUILD}/${d} ] || die "ikemen-screenpack: manca ${d}/ nel commit ${PKG_VERSION}"
    cp -a ${PKG_BUILD}/${d} ${INSTALL}/usr/share/ikemen/
  done
  # Licenze: font Elecbyte CC BY-NC 3.0, grafica e suoni dei contributori
  # CC BY 3.0. Uso non commerciale.
  cp ${PKG_BUILD}/LICENCE.txt ${INSTALL}/usr/share/ikemen/LICENCE-screenpack.txt

  # Elenco per rf35h-ikemen: questi file si copiano nella cartella di gioco
  # solo se mancano, cosi' le modifiche dell'utente (select.def!) restano.
  (cd ${INSTALL}/usr/share/ikemen && find chars data font sound stages video -type f | LC_ALL=C sort) \
    > ${INSTALL}/usr/share/ikemen/screenpack.list
  echo "${PKG_VERSION:0:12}" > ${INSTALL}/usr/share/ikemen/screenpack.version
}
