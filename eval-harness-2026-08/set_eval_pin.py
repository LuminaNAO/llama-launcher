#!/usr/bin/env python3
"""Set every llama.cpp model reference in the eval profile to the given GGUF path, then verify."""
import json, os, re, sys
path = sys.argv[1]  # absolute gguf path
p = os.path.expanduser('~/.openclaw-eval/openclaw.json')
c = json.load(open(p))
s = json.dumps(c)
s2 = re.sub(r'llama\.cpp//[^"]+', 'llama.cpp/' + path, s)
json.loads(s2)
open(p, 'w').write(s2)
ids = set(re.findall(r'llama\.cpp//[^"]+', s2))
assert len(ids) == 1 and path in ids.pop(), ids
print("eval pin verified ->", path.split('/')[-1])
