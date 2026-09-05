#!/usr/bin/env python3
"""Repin PRODUCTION OpenClaw (~/.openclaw/openclaw.json) to a GGUF path: backs up to
openclaw.json.bak-pre-<tag> first (existing convention), rewrites every llama.cpp model ref, verifies.
Usage: set_prod_pin.py <abs gguf path> <tag>   — then: openclaw gateway restart"""
import json, os, re, shutil, sys
path, tag = sys.argv[1], sys.argv[2]
p = os.path.expanduser('~/.openclaw/openclaw.json')
bak = f'{p}.bak-pre-{tag}'
shutil.copy2(p, bak)
s = open(p).read(); json.loads(s)
s2 = re.sub(r'llama\.cpp//[^"]+', 'llama.cpp/' + path, s)
json.loads(s2)
open(p, 'w').write(s2)
ids = set(re.findall(r'llama\.cpp//[^"]+', s2))
assert len(ids) == 1 and path in ids.pop(), ids
print("prod pin verified ->", path.split('/')[-1], "| backup:", bak)
