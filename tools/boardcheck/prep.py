#!/usr/bin/env python3
# prep.py <project dir> <Board> <appearance> <theme> <out.html>
# Turns a board into static HTML: resolves light wrappers, fills {{vars}}.
import sys, re, subprocess, os
proj, name, app, theme, out = sys.argv[1:6]
src = open(os.path.join(proj, name + '.dc.html')).read()
m = re.search(r'<dc-import name="(\w+)"([^>]*)>', src)
if m and '{{vars}}' not in src:
    attrs = dict(re.findall(r'(\w+)="([^"]*)"', m.group(2)))
    app = attrs.get('appearance', app); theme = attrs.get('theme', theme)
    src = open(os.path.join(proj, m.group(1) + '.dc.html')).read()
here = os.path.dirname(os.path.abspath(__file__))
vars_ = subprocess.check_output(['node', '-e', "process.stdout.write(require('%s/tokens.js')('%s','%s'))" % (here, theme, app)]).decode()
src = src.replace('{{vars}}', vars_)
for t in ['system', 'sage', 'clay', 'slate', 'aubergine', 'nordic']:
    if '{{th_' + t + '}}' in src:
        tv = subprocess.check_output(['node', '-e', "process.stdout.write(require('%s/tokens.js')('%s','%s'))" % (here, t, app)]).decode()
        src = src.replace('{{th_' + t + '}}', tv)
if '{{' in src: sys.exit('unresolved hole in ' + name)
import base64, re as _re
here = os.path.dirname(os.path.abspath(__file__))
F=os.path.join(here, '../../server/web/assets/fonts/')
ff=''.join("@font-face{font-family:'Inter';font-style:normal;font-weight:100 900;src:url(data:font/woff2;base64,%s) format('woff2');unicode-range:%s}" % (base64.b64encode(open(F+f,'rb').read()).decode(), r) for f, r in [('inter-latin-ext.woff2','U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+1E00-1EFF,U+20A0-20C4,U+2113,U+2C60-2C7F,U+A720-A7FF'),('inter-latin.woff2','U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD')])
src = _re.sub(r'<link rel="stylesheet" href="https://fonts.googleapis.com[^>]*>', '<style>'+ff+'</style>', src)
src = src.replace('<script src="./support.js"></script>', '').replace('<x-dc>', '').replace('</x-dc>', '').replace('<helmet>', '').replace('</helmet>', '')
src = re.sub(r'<script type="text/x-dc".*?</script>', '', src, flags=re.S)
open(out, 'w').write(src)
