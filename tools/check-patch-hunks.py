import re,sys
bad=0
for f in sys.argv[1:]:
    raw=open(f, errors='replace').read()
    lines=raw.split('\n')
    if lines and lines[-1]=='': lines.pop()      # la riga vuota dopo l'ultimo \n non e' contenuto
    i=0
    while i < len(lines):
        m=re.match(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', lines[i])
        if m:
            wo=int(m.group(2) or 1); wn=int(m.group(4) or 1)
            o=n=0; j=i+1
            while j < len(lines):
                l=lines[j]
                if l.startswith('@@') or l.startswith('--- ') or l.startswith('diff '): break
                if l.startswith('-'): o+=1
                elif l.startswith('+'): n+=1
                elif l.startswith(' ') or l=='': o+=1; n+=1
                elif l.startswith('\\'): pass
                else: break
                j+=1
            if o!=wo or n!=wn:
                print(f"  {f.split('/')[-1]}: @@ dice {wo}/{wn}, reali {o}/{n}"); bad+=1
            i=j; continue
        i+=1
print("conteggi @@ corretti in tutte le patch" if not bad else f"{bad} blocchi incoerenti")
sys.exit(1 if bad else 0)
