#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx>=0.24", "huggingface_hub>=0.26"]
# ///
"""Fork the pinned speech checkpoint with a quantized tied head.

The pinned mlx-community conversion stores `decoder.tok_embeddings.weight` as
unquantized fp16 (768 MiB): its converter skips embeddings, so the tied LM head
pays a 768 MiB fp16 gemv per decoded token — measured ~30 ms of every 100 ms
live-streaming step. The quantized head ships in the CHECKPOINT (owner direction: loading a
checkpoint that quantizes it beats quantizing at load, and a checkpoint whose
head is already quantized never reaches the engine's load-time quantize path):
this script produces that checkpoint — the same snapshot with ONLY the tied
embedding quantized (same affine scheme and group/bits as the rest), ready to
upload as a fork repo. ~540 MiB smaller; the engine loads it directly via the
quantized-tied-embedding loader fix staged upstream as
Blaizzy/mlx-audio-swift#232 (pinned by localvoxtral PR #169).

Run on a Mac (Apple Silicon; uv self-provisions Python + mlx):

    ./scripts/mac/convert-qhead-checkpoint.py --out ~/qhead-checkpoint
    ./scripts/mac/convert-qhead-checkpoint.py --out ~/qhead-checkpoint \
        --upload T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead

Upload uses your cached Hugging Face credentials (`hf auth login`).
The quantization is deterministic, so the bench + eval evidence recorded on
mlx-audio-swift PR #11 (closed; measured with identical tensors) applies to
this checkpoint unchanged: lm-head 30 -> 3 ms/step, eval-e2e level-to-better
vs the fp16-head nightly.
"""

import argparse
import json
import shutil
import sys
from pathlib import Path

import mlx.core as mx
from huggingface_hub import snapshot_download

SOURCE_REPO = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
# Frozen conversion-input snapshot of SOURCE_REPO. SpeechModelCatalog now pins the
# qhead OUTPUT repo (T0mSIlver/...-4bit-qhead @ 247f2eec...), not this one — do not
# sync these two. Changing this SHA re-derives qhead from a different source snapshot.
SOURCE_REVISION = "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e"
EMBED_KEY = "decoder.tok_embeddings.weight"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=SOURCE_REPO)
    parser.add_argument("--revision", default=SOURCE_REVISION)
    parser.add_argument("--out", required=True, help="output directory for the forked checkpoint")
    parser.add_argument("--upload", default=None, help="target HF repo id (e.g. T0mSIlver/...-qhead)")
    parser.add_argument("--group-size", type=int, default=None, help="default: checkpoint's own")
    parser.add_argument("--bits", type=int, default=None, help="default: checkpoint's own")
    args = parser.parse_args()

    src = Path(snapshot_download(args.source, revision=args.revision))
    out = Path(args.out).expanduser()
    if out.exists() and any(out.iterdir()):
        print(f"error: {out} exists and is not empty", file=sys.stderr)
        return 1
    out.mkdir(parents=True, exist_ok=True)

    config = json.loads((src / "config.json").read_text())
    quant = config.get("quantization") or {}
    group_size = args.group_size or quant.get("group_size")
    bits = args.bits or quant.get("bits")
    if not group_size or not bits:
        print("error: no quantization config found and none given", file=sys.stderr)
        return 1
    print(f"quantizing {EMBED_KEY} at {bits}-bit, group {group_size}")

    index_path = src / "model.safetensors.index.json"
    index = json.loads(index_path.read_text())
    weight_map = index["weight_map"]
    shard_name = weight_map[EMBED_KEY]
    for suffix in (".scales", ".biases"):
        if EMBED_KEY.removesuffix(".weight") + suffix in weight_map:
            print("error: source already ships a quantized embedding", file=sys.stderr)
            return 1

    shard = mx.load(str(src / shard_name))
    w = shard[EMBED_KEY]
    if w.dtype != mx.float16:
        print(f"error: expected fp16 embedding, found {w.dtype}", file=sys.stderr)
        return 1
    if w.shape[-1] % group_size:
        print(f"error: dim {w.shape[-1]} not divisible by group {group_size}", file=sys.stderr)
        return 1

    wq, scales, biases = mx.quantize(w, group_size=group_size, bits=bits)
    roundtrip = mx.dequantize(wq, scales, biases, group_size=group_size, bits=bits)
    err = mx.abs(roundtrip.astype(mx.float32) - w.astype(mx.float32)).max().item()
    print(f"packed {tuple(w.shape)} fp16 -> {tuple(wq.shape)} {wq.dtype}; "
          f"round-trip max-abs-err {err:.5f}")

    base = EMBED_KEY.removesuffix(".weight")
    shard[EMBED_KEY] = wq
    shard[f"{base}.scales"] = scales
    shard[f"{base}.biases"] = biases
    mx.save_safetensors(str(out / shard_name), shard,
                        metadata={"format": "safetensors"})

    weight_map[f"{base}.scales"] = shard_name
    weight_map[f"{base}.biases"] = shard_name
    copied = 0
    for f in src.iterdir():
        # Skip HF cache internals but keep .gitattributes — the promise is
        # "the same snapshot with only the tied embedding quantized".
        if f.name in (shard_name, index_path.name):
            continue
        if f.name.startswith(".") and f.name != ".gitattributes":
            continue
        shutil.copy2(f, out / f.name)
        copied += 1
    # total_size = actual bytes of all safetensors now in `out` (shard rewritten
    # above). `metadata` is optional per the safetensors spec, and --source /
    # --revision overrides may point at an index without it.
    index.setdefault("metadata", {})["total_size"] = sum(
        p.stat().st_size for p in out.glob("*.safetensors"))
    (out / index_path.name).write_text(json.dumps(index, indent=2, sort_keys=True))
    print(f"wrote {out} ({copied} files copied, 1 shard rewritten, index updated)")

    if args.upload:
        from huggingface_hub import HfApi

        api = HfApi()
        api.create_repo(args.upload, repo_type="model", exist_ok=True)
        api.upload_folder(folder_path=str(out), repo_id=args.upload, repo_type="model",
                          commit_message=f"Fork of {args.source}@{args.revision[:12]} "
                                         f"with the tied head quantized ({bits}-bit/g{group_size})")
        print(f"uploaded to https://huggingface.co/{args.upload}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
