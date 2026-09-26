"""Decode-time term biasing for Voxtral Realtime on vLLM, the #316 prototype.

Load it into the server with

    PYTHONPATH=scripts/linux VOXTRAL_VLLM_LOGITS_PROCESSOR=vllm_term_bias:TermBias \\
        scripts/linux/voxtral-vllm.sh up

The realtime endpoint drops every session.update field but the model, so the
term list comes through a side file instead (VOXTRAL_TERM_BIAS_FILE, default
~/work/voxtral-vllm/run/term-bias.json), reloaded when it changes:

    {"session": "<id>", "terms": [...], "first": 1.5, "continuation": 4.0, "margin": 3.0}

The file applies to every request, so run one session at a time. Per-session
counts (never the terms) go to <stats dir>/<session>.json.

Rules, as #316 states them:
- A token trie of the terms with the model's tokenizer: leading-space and
  capitalized variants, and hyphens spoken as spaces.
- Boost only when the unbiased top token is a text token, never over
  [STREAMING_PAD] or [STREAMING_WORD].
- `first` on a term's first token, `continuation` on the next token of a live
  match. [STREAMING_WORD] ends a match unless the term's next token starts a
  new word ("Claude Code"); a text token that does not continue it ends it too.
  Padding does neither: a word's tokens can be spread over several steps.
- Flip only to a candidate within `margin` (in log-probability, which greedy
  logit gaps equal) of the top token.

Each 80 ms step reaches the processor as a new request whose prompt carries
every token generated so far, so match state is rebuilt from the prompt.
"""

import itertools
import json
import os
import time
from pathlib import Path

import torch

from vllm.v1.sample.logits_processor import BatchUpdate, LogitsProcessor

STREAMING_PAD = 32
STREAMING_WORD = 33
FIRST_TEXT_TOKEN = 1000  # Tekken: ids below are special tokens

DEFAULT_FILE = Path.home() / "work/voxtral-vllm/run/term-bias.json"


class _Node:
    __slots__ = ("children", "starts_word")

    def __init__(self):
        self.children: dict[int, "_Node"] = {}
        # True when a child token begins with a space: the match may survive
        # a [STREAMING_WORD] boundary.
        self.starts_word = False


def variants(term: str) -> set[str]:
    spellings = {term, term.replace("-", " ")}
    spellings |= {s[:1].upper() + s[1:] for s in spellings}
    return {" " + s for s in spellings if s.strip()}


def build_trie(terms: list[str], encode, piece) -> _Node:
    root = _Node()
    for term in terms:
        for text in variants(term):
            node = root
            for token in encode(text):
                child = node.children.get(token)
                if child is None:
                    child = node.children[token] = _Node()
                    if piece(token).startswith(" "):
                        node.starts_word = True
                node = child
    return root


def live_matches(root: _Node, history) -> list[_Node]:
    """The trie nodes a match reached after `history`, root excluded."""
    live: list[_Node] = []
    for token in history:
        if token == STREAMING_PAD:
            continue
        if token == STREAMING_WORD:
            live = [n for n in live if n.starts_word]
            continue
        if token < FIRST_TEXT_TOKEN:
            live = []
            continue
        nxt = [n.children[token] for n in live if token in n.children]
        if token in root.children:
            nxt.append(root.children[token])
        live = nxt
    return live


def decide(root: _Node, live: list[_Node], top: int, logit, cfg: dict) -> tuple[int, str | None]:
    """The token to emit and the flip kind, if any. `logit(ids)` returns floats."""
    boosts: dict[int, float] = {t: cfg["first"] for t in root.children}
    for node in live:
        for t in node.children:
            boosts[t] = max(boosts.get(t, 0.0), cfg["continuation"])
    ids = list(boosts)
    values = logit(ids + [top])
    top_value = values[-1]
    best, best_score = top, top_value + boosts.get(top, 0.0)
    for t, v in zip(ids, values):
        if t != top and top_value - v <= cfg["margin"] and v + boosts[t] > best_score:
            best, best_score = t, v + boosts[t]
    if best == top:
        return top, None
    return best, ("continuation" if boosts[best] > cfg["first"] else "first")


class TermBias(LogitsProcessor):
    def __init__(self, vllm_config, device, is_pin_memory):
        from vllm.tokenizers import cached_tokenizer_from_config

        tekken = cached_tokenizer_from_config(vllm_config.model_config).instruct.tokenizer
        self._encode = lambda s: tekken.encode(s, bos=False, eos=False)
        self._piece = tekken.id_to_piece
        self._file = Path(os.environ.get("VOXTRAL_TERM_BIAS_FILE", DEFAULT_FILE))
        self._stats_dir = self._file.parent / (self._file.stem + "-stats")
        self._stats_dir.mkdir(parents=True, exist_ok=True)
        self._stamp = None
        self._cfg: dict = {}
        self._root = _Node()
        self._rows: dict[int, tuple[list[int], list[int]]] = {}
        self._stats: dict = {}

    def is_argmax_invariant(self) -> bool:
        return False

    def _reload(self):
        try:
            st = self._file.stat()
        except FileNotFoundError:
            self._stamp, self._cfg, self._root = None, {}, _Node()
            return
        stamp = (st.st_ino, st.st_mtime_ns, st.st_size)
        if stamp == self._stamp:
            return
        cfg = json.loads(self._file.read_text())
        self._root = build_trie(cfg.get("terms", []), self._encode, self._piece)
        if cfg.get("session") != self._cfg.get("session"):
            # A rerun reuses session ids; start its counts from zero.
            self._stats = {}
        self._cfg, self._stamp = cfg, stamp

    def update_state(self, batch_update: BatchUpdate | None):
        if batch_update is None:
            return
        for index in batch_update.removed:
            self._rows.pop(index, None)
        for index, _params, prompt, output in batch_update.added:
            # The realtime path feeds generated tokens back as prompt and
            # leaves `output` empty. Elsewhere `output` is vLLM's live list.
            self._rows[index] = (prompt or [], output)
        for a, b, _direction in batch_update.moved:
            ra, rb = self._rows.pop(a, None), self._rows.pop(b, None)
            if ra is not None:
                self._rows[b] = ra
            if rb is not None:
                self._rows[a] = rb
        self._reload()

    def apply(self, logits: torch.Tensor) -> torch.Tensor:
        if not self._root.children or not self._rows:
            return logits
        started = time.perf_counter()
        session = str(self._cfg.get("session", "default"))
        stats = self._stats or {"steps": 0, "textSteps": 0, "flipsFirst": 0, "flipsContinuation": 0, "applySeconds": 0.0}
        self._stats = stats
        for row, (prompt, output) in self._rows.items():
            if row >= logits.shape[0]:
                continue
            stats["steps"] += 1
            top = int(logits[row].argmax())
            if top < FIRST_TEXT_TOKEN:
                continue
            stats["textSteps"] += 1
            live = live_matches(self._root, itertools.chain(prompt, output))
            chosen, kind = decide(
                self._root, live, top,
                lambda ids, r=row: logits[r, torch.tensor(ids, device=logits.device)].tolist(),
                self._cfg,
            )
            if kind is not None:
                logits[row, chosen] = logits[row, top] + 1.0
                stats["flipsFirst" if kind == "first" else "flipsContinuation"] += 1
        stats["applySeconds"] += time.perf_counter() - started
        (self._stats_dir / f"{session}.json").write_text(json.dumps(stats))
        return logits
