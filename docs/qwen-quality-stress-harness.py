#!/usr/bin/env python3
"""Extended stress battery: 8 hard tasks x 3 servers, temp 0, 20K budget, executable validation."""
import os
import json, re, subprocess, sys, time, urllib.request

SERVERS = {
    "local-strix": "http://127.0.0.1:40801",
    "m5090-cuda": os.environ.get("QWEN_PEER2_URL", "http://127.0.0.1:40801"),
    "fable-fusion": os.environ.get("QWEN_FABLE_FUSION_URL", "http://127.0.0.1:40801")  # remote peer: set env var,
}

PLANTED_MODULE = '''
def clamp(x, lo, hi):
    """Clamp x into [lo, hi]."""
    return max(lo, min(hi, x))

def mean(xs):
    """Arithmetic mean of a non-empty list."""
    return sum(xs) / len(xs)

def median(xs):
    """Median; for even length, average of the two middle values."""
    s = sorted(xs)
    n = len(s)
    if n % 2 == 1:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2

def chunk(lst, n):
    """Split lst into consecutive non-overlapping chunks of size n (last may be shorter)."""
    out = []
    for i in range(0, len(lst), n - 1):
        out.append(lst[i:i + n])
    return out

def flatten1(lst):
    """Flatten one level of nesting."""
    out = []
    for x in lst:
        if isinstance(x, list):
            out.extend(x)
        else:
            out.append(x)
    return out

def rle(s):
    """Run-length encode a string into (char, count) pairs."""
    out = []
    for ch in s:
        if out and out[-1][0] == ch:
            out[-1] = (ch, out[-1][1] + 1)
        else:
            out.append((ch, 1))
    return out

def moving_average(xs, k):
    """Moving average with window k; returns len(xs)-k+1 values."""
    out = []
    acc = sum(xs[:k])
    out.append(acc / k)
    for i in range(k, len(xs)):
        acc += xs[i] - xs[i - k]
        out.append(acc / k)
    return out

def dedupe_keep_order(xs):
    """Remove duplicates, keeping first occurrence order."""
    seen = set()
    out = []
    for x in xs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out
'''

TASKS = [
 dict(name="S1-kbooking",
  prompt=("Implement a Python class Calendar with a method book(start, end) (half-open interval "
          "[start, end)) that records the event and returns the maximum number of concurrently "
          "overlapping events among all events booked so far. Reply with ONLY the code in one "
          "python code block."),
  test=r'''
{code}
c = Calendar()
got = [c.book(10,20), c.book(50,60), c.book(10,40), c.book(5,15), c.book(5,10), c.book(25,55)]
assert got == [1,1,2,3,3,3], got
c2 = Calendar()
assert c2.book(0,1) == 1 and c2.book(1,2) == 1 and c2.book(0,2) == 2
print("PASS")
'''),
 dict(name="S2-topo-lex",
  prompt=("Write a Python function order(n, pairs) where courses are 0..n-1 and each pair (a, b) "
          "means b must be taken before a. Return the lexicographically smallest valid ordering as "
          "a list, or [] if impossible. No imports except heapq. Reply with ONLY the code in one "
          "python code block."),
  test=r'''
{code}
assert order(4, [(1,0),(2,0),(3,1),(3,2)]) == [0,1,2,3]
assert order(2, [(0,1),(1,0)]) == []
assert order(3, []) == [0,1,2]
assert order(5, [(1,4),(2,4),(3,1),(3,2),(0,3)]) == [4,1,2,3,0]
assert order(1, []) == [0]
print("PASS")
'''),
 dict(name="S3-lev-lcs",
  prompt=("Write a Python function analyze(a, b) returning a tuple (d, s) where d is the Levenshtein "
          "edit distance between strings a and b (insert/delete/substitute, each cost 1) and s is any "
          "one longest common subsequence of a and b. No imports. Reply with ONLY the code in one "
          "python code block."),
  test=r'''
{code}
def ref_lev(a,b):
    m,n=len(a),len(b)
    dp=list(range(n+1))
    for i in range(1,m+1):
        prev=dp[0]; dp[0]=i
        for j in range(1,n+1):
            cur=dp[j]
            dp[j]=min(dp[j]+1, dp[j-1]+1, prev+(a[i-1]!=b[j-1]))
            prev=cur
    return dp[n]
def ref_lcs_len(a,b):
    m,n=len(a),len(b)
    dp=[[0]*(n+1) for _ in range(m+1)]
    for i in range(m):
        for j in range(n):
            dp[i+1][j+1]=dp[i][j]+1 if a[i]==b[j] else max(dp[i][j+1],dp[i+1][j])
    return dp[m][n]
def is_subseq(s,t):
    it=iter(t); return all(c in it for c in s)
for a,b in [("kitten","sitting"),("abcde","ace"),("","abc"),("same","same"),("abcxyz","xyzabc"),("flaw","lawn")]:
    d,s = analyze(a,b)
    assert d == ref_lev(a,b), (a,b,d)
    assert is_subseq(s,a) and is_subseq(s,b), (a,b,s)
    assert len(s) == ref_lcs_len(a,b), (a,b,s)
print("PASS")
'''),
 dict(name="S4-expr-eval",
  prompt=("Write a Python function ev(s) that evaluates an arithmetic expression string with "
          "Python semantics for + - * / // % ** and unary minus, parentheses, integers and floats. "
          "Operator precedence and associativity must match Python exactly (** is right-associative; "
          "unary minus binds tighter than * but looser than **). Do NOT use eval, exec, ast, or any "
          "import. Reply with ONLY the code in one python code block."),
  test=r'''
{code}
cases = ["2+3*4","(2+3)*4","2**3**2","-2**2","3*-2","7//2","7%3","(1+2)*(3+4)/7",
         "10-4-3","2*3**2","-(2+3)*2","1.5*4","2**-1","100//7%5","-3--4"]
for c in cases:
    got = ev(c); want = eval(c)
    assert abs(got - want) < 1e-9 and type(got) == type(want), (c, got, want)
print("PASS")
'''),
 dict(name="S5-csv-parser",
  prompt=("Write a Python function parse_csv(text) implementing RFC 4180: rows separated by \\n or "
          "\\r\\n, fields separated by commas, fields may be quoted with double quotes, quoted fields "
          "may contain commas, newlines, and escaped quotes written as two double quotes. A trailing "
          "newline does not produce an empty final row. Return a list of rows (lists of strings). "
          "No imports. Reply with ONLY the code in one python code block."),
  test=r'''
{code}
assert parse_csv('a,b,c\n1,2,3') == [['a','b','c'],['1','2','3']]
assert parse_csv('"a,b",c') == [['a,b','c']]
assert parse_csv('"he said ""hi""",x') == [['he said "hi"','x']]
assert parse_csv('a,"multi\nline",b') == [['a','multi\nline','b']]
assert parse_csv('a,,b\n') == [['a','','b']]
assert parse_csv('a,b\r\nc,d\r\n') == [['a','b'],['c','d']]
assert parse_csv('""') == [['']]
assert parse_csv('x') == [['x']]
print("PASS")
'''),
 dict(name="S6-bigint-mul",
  prompt=("Write a Python function mul(a, b) that multiplies two non-negative integers given as "
          "decimal strings and returns the product as a decimal string. You may convert single "
          "characters to digits, but you must NOT convert the whole strings (or slices of them) "
          "with int(); implement the arithmetic yourself. No imports. Reply with ONLY the code in "
          "one python code block."),
  test=r'''
{code}
import random
random.seed(7)
assert mul("0","12345") == "0" and mul("12345","0") == "0"
assert mul("1","1") == "1"
assert mul("99","99") == "9801"
for _ in range(20):
    x = random.randrange(0, 10**random.randrange(1,60))
    y = random.randrange(0, 10**random.randrange(1,60))
    assert mul(str(x), str(y)) == str(x*y), (x,y)
print("PASS")
'''),
 dict(name="S7-trie-top3",
  prompt=("Write a Python class AC with methods add(word, freq) and query(prefix) -> list of up to 3 "
          "added words starting with prefix, ordered by freq descending, ties broken alphabetically. "
          "Adding an existing word replaces its freq. No imports. Reply with ONLY the code in one "
          "python code block."),
  test=r'''
{code}
t = AC()
for w,f in [("car",5),("card",7),("care",5),("cat",9),("dog",3),("cart",5)]:
    t.add(w,f)
assert t.query("car") == ["card","car","care"], t.query("car")
assert t.query("ca") == ["cat","card","car"]
assert t.query("d") == ["dog"]
assert t.query("x") == []
t.add("car", 100)
assert t.query("ca") == ["car","cat","card"]
print("PASS")
'''),
 dict(name="S8-planted-bug",
  prompt=("One function in this module does not match its docstring. Name the buggy function and "
          "give the one-line fix. Reply with ONLY a JSON object: {\"function\": name, \"fix\": string}."
          "\n```python\n" + PLANTED_MODULE + "```"),
  test=None),
]

def ask(base, prompt):
    body = {"model":"q","max_tokens":20480,"temperature":0,
            "messages":[{"role":"user","content":prompt}]}
    req = urllib.request.Request(base+"/v1/chat/completions", json.dumps(body).encode(),
            {"Content-Type":"application/json","Authorization":"Bearer ollama-local"})
    d = json.loads(urllib.request.urlopen(req, timeout=2400).read())
    m = d["choices"][0]["message"]
    return (m.get("content") or "").strip(), d["choices"][0].get("finish_reason"), len(m.get("reasoning_content") or "")

def validate(task, answer):
    if task["name"] == "S8-planted-bug":
        mj = re.search(r"\{.*\}", answer, re.S)
        if not mj: return False, "no JSON found"
        try: d = json.loads(mj.group(0))
        except Exception as e: return False, f"bad JSON: {e}"
        fn = str(d.get("function","")).strip().lower().replace("()","")
        fix = str(d.get("fix","")).lower()
        ok = fn == "chunk" and ("n)" in fix or "range" in fix or "n - 1" in fix or "n-1" in fix or "step" in fix)
        return ok, f"function={d.get('function')} fix={str(d.get('fix'))[:60]}"
    blocks = re.findall(r"```(?:python|py)?\s*\n(.*?)```", answer, re.S)
    code = blocks[-1] if blocks else answer
    script = task["test"].replace("{code}", code)
    try:
        r = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT 60s"
    if r.returncode == 0 and "PASS" in r.stdout:
        return True, "pass"
    err = (r.stderr or r.stdout).strip().splitlines()
    return False, (err[-1][:180] if err else f"rc={r.returncode}")

t0 = time.time()
scores = {s: 0 for s in SERVERS}
for task in TASKS:
    for sname, base in SERVERS.items():
        try:
            answer, finish, think = ask(base, task["prompt"])
            ok, note = validate(task, answer)
            if finish == "length" and not ok: note += " [hit max_tokens]"
        except Exception as e:
            ok, note, answer, think = False, f"request failed: {e}", "", 0
        scores[sname] += ok
        print(f"[{int(time.time()-t0)}s] {sname} | {task['name']}: {'PASS' if ok else 'FAIL'} ({note}) think={think}", flush=True)
        with open("/tmp/claude-1004/-home-claude/e2c154c2-09b7-4611-adf2-3de0e82effd3/scratchpad/quality-stress-transcripts.txt","a") as f:
            f.write(f"\n===== {sname} | {task['name']} | {'PASS' if ok else 'FAIL'} | {note}\n{answer}\n")

print("\n===== STRESS SUMMARY =====")
for s, sc in scores.items():
    print(f"{s}: {sc}/{len(TASKS)}")
