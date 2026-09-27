#!/usr/bin/env python3
"""Replays public captures through QuickCaptureChatRouting's prompt (copied
verbatim) with four project-context variants. GLM 5.3 on the Mistral API,
reasoning_effort low, as the app sends it. Same 0.9 bar."""
import json, os, re, sys, glob, concurrent.futures as cf, urllib.request, collections

HERE = os.path.dirname(os.path.abspath(__file__))
def key():
    k = os.environ.get("VIBE_MISTRAL_API_KEY")
    if k: return k
    for line in open(os.path.expanduser("~/.vibe/.env")):
        if line.startswith("MISTRAL_API_KEY="): return line.split("=", 1)[1].strip().strip('"\'')
KEY = key()
SYSTEM = ('You route a spoken note to one of the speaker\'s software projects. '
          'Read the note and the project descriptions, then pick the one project '
          'the note is about. Pick "inbox" when it fits '
          'none of them, when two fit equally, or when you would be guessing. '
          'Reply with JSON only: {"project": "<id>", "confidence": <0 to 1>}.')
CATCH = "None of the projects above: a personal note, a task or an idea about something else, or too vague to place."

def readme_summary(md, paras=2, limit=400):
    lines = md.replace("\r\n", "\n").split("\n")
    out, cur, fence, comment = [], [], False, False
    def end():
        t = " ".join(cur); t = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", t); t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t)
        t = re.sub(r"<[^>]+>", "", t); t = re.sub(r"&[#A-Za-z0-9]+;", " ", t)
        for m in ["**", "__", "`"]: t = t.replace(m, "")
        t = re.sub(r"\s+", " ", t).strip()
        if t: out.append(t)
        cur.clear()
    for raw in lines:
        if len(out) >= paras: break
        l = raw.strip()
        if l.startswith("```") or l.startswith("~~~"): fence = not fence; end(); continue
        if fence: continue
        if comment:
            if "-->" in l: comment = False
            continue
        if l.startswith("<!--"):
            if "-->" not in l: comment = True
            continue
        stripped = re.sub(r"\[?!\[[^\]]*\]\([^)]*\)\]?(\([^)]*\))?", "", l).strip()
        if (not l or l[0] in "#<>|" or l[:2] in ("- ", "* ", "+ ") or set(l) <= set("=-_*")
                or re.match(r"^<?https?://\S+>?$", l) or not stripped):
            end(); continue
        cur.append(l)
    if len(out) < paras: end()
    t = " ".join(out[:paras])
    return (t[:limit - 1] + "…") if len(t) > limit else (t or None)

projects = []
for meta in sorted(glob.glob(f"{HERE}/*.meta.json")):
    m = json.load(open(meta)); n = m["name"]
    md = open(f"{HERE}/{n}.README.md").read() if os.path.exists(f"{HERE}/{n}.README.md") else ""
    issues = [l.split("\t", 2)[2] for l in open(f"{HERE}/{n}.issues.tsv").read().splitlines() if l.count("\t") >= 2]
    projects.append(dict(name=n, summary=readme_summary(md), desc=m["description"], topics=m["topics"],
                         fork=m.get("parent"), issues=issues[:8]))

def describe(p, variant):
    parts = [f"Project {p['name']}."]
    if variant in ("gh", "gh+issues") and p["desc"]:
        parts.append(p["desc"] if p["desc"].endswith(".") else p["desc"] + ".")
        if p["fork"]: parts.append(f"A fork of {p['fork']}.")
    if variant != "name" and p["summary"]: parts.append(p["summary"])
    if variant in ("gh", "gh+issues") and p["topics"]: parts.append("Topics: " + ", ".join(p["topics"]) + ".")
    if variant == "gh+issues" and p["issues"]: parts.append("Recent issues: " + "; ".join(p["issues"]) + ".")
    return " ".join(parts)

CALIB = (' Confidence: 0.95 when the note names the project or can only be about it; '
         '0.5 or less when you are guessing.')
JEV_INSTR = "A developer dictated this note. Which of their software projects is it about? Choose inbox unless the note clearly concerns one project."
def ask_jev(capture, opts):
    body = dict(model="typesafe-ai/jev", state=capture, questions={"project": dict(type="choice", instructions=JEV_INSTR, criteria=dict(opts))})
    k = open(os.path.expanduser("~/.config/localvoxtral/ai_gateway_api_key")).read().strip()
    import time
    for attempt in range(6):
        try:
            req = urllib.request.Request("https://ai-gateway.vercel.sh/v1/evaluate", json.dumps(body).encode(),
                                         {"Authorization": f"Bearer {k}", "Content-Type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=30))
            a = (r.get("answers") or r["result"]["answers"])["project"]
            pr = a.get("probabilities") or {a["choice"]: a.get("confidence", 1)}
            best = sorted(pr.items(), key=lambda x: -x[1])
            top, p = best[0]; second = best[1][1] if len(best) > 1 else 0
            return (top if p - second >= 0.15 else "inbox"), p, r.get("usage", {}).get("inputTokens")
        except Exception as e:
            time.sleep(2 ** attempt)
    return "FAILED", 0.0, None

def ask(capture, variant):
    variant, _, mode = variant.partition(":")
    opts = [(p["name"].lower(), describe(p, variant)) for p in projects] + [("inbox", CATCH)]
    if mode == "jev": return ask_jev(capture, opts)
    user = "Projects:\n" + "\n".join(f"- {i}: {d}" for i, d in opts) + f"\n\nNote:\n{capture}"
    body = dict(model="zai-glm-5-3", temperature=0, max_tokens=4096, reasoning_effort="high" if mode == "high" else "low",
                messages=[{"role": "system", "content": SYSTEM + (CALIB if mode == "calib" else "")}, {"role": "user", "content": user}])
    for attempt in range(4):
        try:
            req = urllib.request.Request("https://api.mistral.ai/v1/chat/completions", json.dumps(body).encode(),
                                         {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=90))
            c = r["choices"][0]["message"]["content"]
            if isinstance(c, list): c = "".join(x.get("text", "") for x in c if x.get("type") == "text")
            c = c.split("</think>")[-1]
            a = json.loads(c[c.index("{"): c.rindex("}") + 1])
            return a["project"], float(a.get("confidence", 1)), r.get("usage", {}).get("prompt_tokens")
        except Exception as e:
            err = e
    return "FAILED", 0.0, None

caps = [json.loads(l) for l in open(f"{HERE}/captures.jsonl")]
variants = sys.argv[1:] or ["name", "readme", "gh", "gh+issues"]
if "--show" in variants:
    for p in projects: print(describe(p, "gh+issues"), "\n")
    sys.exit()
for v in variants:
    with cf.ThreadPoolExecutor(2 if v.endswith(":jev") else 6) as ex:
        res = list(ex.map(lambda c: ask(c["text"], v), caps))
    s = collections.Counter(); rows = []; toks = []
    for c, (got, conf, tk) in zip(caps, res):
        exp = c["expected"].lower(); routed = got if (got != "inbox" and conf >= 0.9) else "inbox"
        if tk: toks.append(tk)
        s["right"] += routed == exp
        if exp != "inbox":
            s["proj"] += 1; s["proj_right"] += routed == exp
            s["raw_right"] += got == exp
        else:
            s["inb"] += 1; s["inb_right"] += routed == "inbox"
        s["wrong_project"] += routed not in ("inbox", exp)
        s["failed"] += got == "FAILED"
        mark = "ok " if routed == exp else ("inb" if routed == "inbox" else "BAD")
        rows.append(f"  {mark} {c['id']:5} exp={exp:22} raw={got}@{conf:.2f}")
    print(f"== {v}: right {s['right']}/{len(caps)}; project captures routed right {s['proj_right']}/{s['proj']} "
          f"(model's pick right before the bar {s['raw_right']}/{s['proj']}); inbox kept {s['inb_right']}/{s['inb']}; "
          f"wrong project {s['wrong_project']}; failed {s['failed']}; prompt tokens ~{sum(toks)//max(len(toks),1)}")
    print("\n".join(r for r in rows if not r.startswith("  ok")))
