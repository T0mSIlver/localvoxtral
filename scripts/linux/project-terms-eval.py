#!/usr/bin/env python3
"""Rebuilds EvalCorpus/learned-terms/project-term-proposals.json (#914).

Asks Claude Code and Vibe for each public repository's terms with the
project-terms prompt as a given git revision shipped it, the command lines the
app uses, then has a blind judge label every proposed term: would a builder
who talks to coding agents and does not read the code say it aloud?
ProjectTermProposalEvalTests scores the frozen answers with and without the
filter.

  scripts/linux/project-terms-eval.py run   <dir> <arm> <git-rev>   # arm: claude-old, vibe-new, ...
  scripts/linux/project-terms-eval.py judge <dir>
  scripts/linux/project-terms-eval.py freeze <dir>

<dir> holds repos/<name> (shallow clones of REPOS) and gets results/ and
labels/. Linux only, like every live run: about $1 of Claude tokens per arm
over the ten repositories, and Vibe plan credits. The judge is GLM 5.3 on the
Mistral API with the Vibe plan key (VIBE_MISTRAL_API_KEY, else ~/.vibe/.env).
"""
import concurrent.futures, json, os, random, re, subprocess, sys, tempfile, time, urllib.request

REPOS = {
    "localvoxtral": "T0mSIlver/localvoxtral", "working-set": "T0mSIlver/working-set",
    "vidtheque": "T0mSIlver/vidtheque", "glossator": "T0mSIlver/glossator",
    "fastcontext": "T0mSIlver/fastcontext", "hither": "T0mSIlver/hither", "toklen": "T0mSIlver/toklen",
    "mlx-audio": "Blaizzy/mlx-audio", "llm": "simonw/llm", "ollama": "ollama/ollama",
}
ARMS = ["claude-old", "claude-new", "vibe-old", "vibe-new"]
TERMS_SH = "integrations/claude-code/plugins/localvoxtral-remote/hooks/terms.sh"
SCHEMA = ('{"type":"object","properties":{"terms":{"type":"array","items":{"type":"string"},"maxItems":40},'
          '"description":{"type":"string"}},"required":["terms","description"],"additionalProperties":false}')
JUDGE = """You judge terms for a dictation app. The user is a builder who talks to coding agents by voice and does not read the code. They say model names, repository and project names, tool and product names, service names, people and team names, and words of the project's domain. They rarely say code identifiers (class, function, variable or module names), and never say environment variables, file names, file paths or command-line flags.

For each term, answer "say" if this user would plausibly say it aloud while talking about the project, else "no". Judge the term as written: a term that only exists as a code identifier, file name, flag or environment variable is "no" even if its words could be spoken. A product or project name that happens to contain a dash, a dot or capitals is "say"."""


def shipped_prompt(rev):
    """The prompt and system prompt the remote runner shipped at `rev`,
    which RemoteProjectTermsTests pins to ProjectTermProposal's."""
    text = subprocess.run(["git", "show", f"{rev}:{TERMS_SH}"], capture_output=True, text=True, check=True).stdout
    prompt = re.search(r"cat <<'PROMPT'\n(.*?)\nPROMPT", text, re.S).group(1)
    system = re.search(r"--system-prompt '(.*?)' \\\n", text, re.S).group(1).replace("'\"'\"'", "'")
    return prompt, system


def answer_in(text):
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0]
    try:
        return json.loads(text)
    except ValueError:
        start, end = text.rfind("{", 0, text.find('"terms"') + 1), text.rfind("}")
        try:
            return json.loads(text[start:end + 1])
        except ValueError:
            return None


def run(root, arm, rev):
    agent = arm.split("-")[0]
    prompt, system = shipped_prompt(rev)
    out_dir = os.path.join(root, "results", arm)
    os.makedirs(out_dir, exist_ok=True)
    base = {k: os.environ[k] for k in ("HOME", "PATH", "LANG", "USER", "LOGNAME") if k in os.environ}

    def one(repo):
        cwd, env = os.path.join(root, "repos", repo), dict(base)
        if agent == "claude":
            command = ["claude", "-p", prompt, "--model", "sonnet", "--system-prompt", system,
                       "--tools", "Read,Glob,Grep", "--settings", '{"disableAllHooks":true}', "--strict-mcp-config",
                       "--no-session-persistence", "--max-turns", "12", "--max-budget-usd", "0.50",
                       "--output-format", "json", "--json-schema", SCHEMA]
        else:
            files = subprocess.run(["git", "-c", "core.quotePath=false", "ls-files"], cwd=cwd,
                                   capture_output=True, text=True).stdout.splitlines()[:200]
            listed = prompt + ("\n\nTracked files (read_file takes these paths):\n" + "\n".join(files) if files else "")
            # A home of its own keeps the user's Vibe hooks out, as the app's run does.
            env["VIBE_HOME"] = tempfile.mkdtemp(prefix="vibe-home-", dir=root)
            for name in ("config.toml", ".env"):
                if os.path.exists(os.path.expanduser(f"~/.vibe/{name}")):
                    os.symlink(os.path.expanduser(f"~/.vibe/{name}"), os.path.join(env["VIBE_HOME"], name))
            command = ["vibe", "--experimental-harness", "--auto-approve", "-p", listed, "--enabled-tools",
                       "re:^(read_file|grep|file_system[.](read_file|grep|glob|list_dir))$",
                       "--max-turns", "12", "--max-price", "0.30", "--output", "json"]
        started = time.time()
        try:
            stdout = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=240,
                                    stdin=subprocess.DEVNULL).stdout
        except subprocess.TimeoutExpired:
            stdout = ""
        terms = None
        try:
            if agent == "claude":
                result = json.loads(stdout)
                terms = (result.get("structured_output") or answer_in(result.get("result", "")) or {}).get("terms")
            else:
                last = [e for e in json.loads(stdout) if e.get("type") == "message" and e.get("role") == "assistant"][-1]
                text = "".join(p.get("text", "") for p in last.get("content", []) if isinstance(p, dict))
                terms = (answer_in(text) or {}).get("terms")
        except (ValueError, IndexError, AttributeError):
            pass
        with open(os.path.join(out_dir, repo + ".json"), "w") as f:
            json.dump({"repo": repo, "seconds": round(time.time() - started), "terms": terms}, f, indent=1)
        return repo, None if terms is None else len(terms)

    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        for repo, count in pool.map(one, sorted(REPOS)):
            print(arm, repo, count, flush=True)


def vibe_key():
    if key := os.environ.get("VIBE_MISTRAL_API_KEY"):
        return key.strip()
    for line in open(os.path.expanduser("~/.vibe/.env")):
        if line.startswith("MISTRAL_API_KEY="):
            return line.split("=", 1)[1].strip().strip("\"'")
    sys.exit("no Vibe key")


def judge(root):
    key = vibe_key()
    os.makedirs(os.path.join(root, "labels"), exist_ok=True)
    for repo in sorted(REPOS):
        path = os.path.join(root, "labels", repo + ".json")
        if os.path.exists(path):
            continue
        terms = set()
        for arm in ARMS:
            with open(os.path.join(root, "results", arm, repo + ".json")) as f:
                terms.update(t for t in json.load(f)["terms"] or [] if isinstance(t, str))
        # Pooled and shuffled: the judge never sees which prompt or agent proposed a term.
        terms = sorted(terms)
        random.Random(repo).shuffle(terms)
        readme = os.path.join(root, "repos", repo, "README.md")
        about = open(readme).read()[:600].replace("\n", " ") if os.path.exists(readme) else repo
        labels = {}
        for start in range(0, len(terms), 60):
            chunk = terms[start:start + 60]
            body = {"model": "zai-glm-5-3", "temperature": 0, "reasoning_effort": "low",
                    "response_format": {"type": "json_object"},
                    "messages": [{"role": "system", "content": JUDGE}, {"role": "user", "content":
                        f"Project: {repo}\nAbout: {about}\n\nTerms:\n" + "\n".join(chunk)
                        + '\n\nReply with JSON only: {"labels": {"<term exactly as given>": "say" | "no", ...}} covering every term.'}]}
            request = urllib.request.Request("https://api.mistral.ai/v1/chat/completions", json.dumps(body).encode(),
                                             {"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
            content = json.load(urllib.request.urlopen(request, timeout=300))["choices"][0]["message"]["content"]
            if isinstance(content, list):
                content = "".join(p.get("text", "") for p in content if p.get("type") == "text")
            got = json.loads(re.sub(r"^```(json)?|```$", "", content.strip()).strip())["labels"]
            labels.update({t: got.get(t, "no") for t in chunk})
        with open(path, "w") as f:
            json.dump(labels, f, indent=1, sort_keys=True)
        print(repo, len(terms), sum(v == "say" for v in labels.values()), flush=True)


def freeze(root):
    corpus = {"judged": time.strftime("%Y-%m-%d"), "repos": []}
    for repo in sorted(REPOS):
        with open(os.path.join(root, "labels", repo + ".json")) as f:
            labels = json.load(f)
        answers = {}
        for arm in ARMS:
            with open(os.path.join(root, "results", arm, repo + ".json")) as f:
                answers[arm] = [t for t in json.load(f)["terms"] or [] if isinstance(t, str)]
        corpus["repos"].append({"repo": REPOS[repo], "answers": answers,
                                "say": sorted(t for t, v in labels.items() if v == "say"),
                                "no": sorted(t for t, v in labels.items() if v != "say")})
    with open("EvalCorpus/learned-terms/project-term-proposals.json", "w") as f:
        f.write(json.dumps(corpus, indent=1, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    verb, root = sys.argv[1], os.path.abspath(sys.argv[2])
    {"run": lambda: run(root, sys.argv[3], sys.argv[4]), "judge": lambda: judge(root), "freeze": lambda: freeze(root)}[verb]()
