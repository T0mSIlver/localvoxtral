#!/usr/bin/env python3
"""Cut the recorded demo take into the README story and one clip per beat.

usage: edit-demo.py <raw video> <timeline.json> <out dir>

scripts/record-demo.sh (story scene) writes the timeline while it records:

  {"offset": 0.4,
   "beats": [{"id": "live", "caption": "Hold to dictate into Claude Code"}, ...],
   "segments": [{"beat": "live", "start": 3.1, "end": 9.8, "speed": 1}, ...]}

Times are seconds since the recorder started; `offset` is how long the
recorder took to write its first frame, subtracted from every time. A
segment with speed 0 is dropped, speed 4 plays four times faster (waits on
the agent or the polish). Each beat's caption is burned in over all of its
segments, so the muted autoplay on GitHub still names each feature.

Writes <out>/story.mp4 (every beat in order), <out>/clips/<n>-<id>.mp4 and
<out>/frames/<n>-<id>.png, one still per beat (70 % into its clip).
Needs an ffmpeg with drawtext (libfreetype): the hosted Ubuntu runner's has
it, Homebrew's on the Mini does not, which is why this runs in its own job.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

WIDTH = 1280
FPS = 30


def font_file():
    for candidate in (
        os.environ.get("DEMO_CAPTION_FONT", ""),
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ):
        if candidate and os.path.isfile(candidate):
            return candidate
    found = subprocess.run(["fc-match", "-f", "%{file}", "sans:bold"], capture_output=True, text=True)
    if found.returncode == 0 and os.path.isfile(found.stdout):
        return found.stdout
    sys.exit("No caption font found; set DEMO_CAPTION_FONT to a .ttf file.")


def drawtext_escape(text):
    # drawtext's own escaping, then the filtergraph's: \ ' : and % are special.
    return (
        text.replace("\\", "\\\\\\\\")
        .replace("'", "’")
        .replace(":", "\\:")
        .replace("%", "\\%")
        .replace(",", "\\,")
    )


def caption_filter(caption, font):
    return (
        f"drawtext=fontfile='{font}':text='{drawtext_escape(caption)}'"
        ":fontsize=34:fontcolor=white:box=1:boxcolor=black@0.72:boxborderw=18"
        ":x=(w-text_w)/2:y=h-text_h-48"
    )


def render_segment(raw, segment, offset, caption, font, out):
    start = max(0.0, segment["start"] - offset)
    end = segment["end"] - offset
    if end - start < 0.05:
        return False
    speed = float(segment["speed"])
    filters = [f"setpts=(PTS-STARTPTS)/{speed}", f"scale={WIDTH}:-2:flags=lanczos", f"fps={FPS}"]
    if caption:
        filters.append(caption_filter(caption, font))
    subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", f"{start:.3f}", "-to", f"{end:.3f}", "-i", raw,
            "-vf", ",".join(filters), "-an",
            "-c:v", "libx264", "-crf", "20", "-preset", "slow", "-pix_fmt", "yuv420p",
            out,
        ],
        check=True,
    )
    return True


def concat(parts, out, workdir):
    listing = os.path.join(workdir, os.path.basename(out) + ".txt")
    with open(listing, "w") as f:
        for part in parts:
            f.write(f"file '{part}'\n")
    subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "concat", "-safe", "0", "-i", listing,
            "-c", "copy", "-movflags", "+faststart", out,
        ],
        check=True,
    )


def duration(path):
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True,
    )
    return float(probe.stdout.strip())


def main(argv):
    if len(argv) != 4:
        sys.exit(__doc__)
    raw, timeline_path, out_dir = argv[1:]
    with open(timeline_path) as f:
        timeline = json.load(f)
    offset = float(timeline.get("offset", 0))
    beats = timeline["beats"]
    captions = {beat["id"]: beat.get("caption", "") for beat in beats}
    unknown = {s["beat"] for s in timeline["segments"]} - set(captions)
    if unknown:
        sys.exit(f"segments name beats the timeline does not declare: {sorted(unknown)}")
    font = font_file()

    os.makedirs(os.path.join(out_dir, "clips"), exist_ok=True)
    os.makedirs(os.path.join(out_dir, "frames"), exist_ok=True)
    workdir = tempfile.mkdtemp(prefix="edit-demo.")
    try:
        parts_by_beat = {beat["id"]: [] for beat in beats}
        for index, segment in enumerate(timeline["segments"]):
            if float(segment["speed"]) <= 0:
                continue
            part = os.path.join(workdir, f"seg-{index:03d}.mp4")
            if render_segment(raw, segment, offset, captions[segment["beat"]], font, part):
                parts_by_beat[segment["beat"]].append(part)

        story_parts = []
        for number, beat in enumerate(beats, start=1):
            parts = parts_by_beat[beat["id"]]
            if not parts:
                sys.exit(f"beat {beat['id']} has no footage")
            story_parts.extend(parts)
            clip = os.path.join(out_dir, "clips", f"{number}-{beat['id']}.mp4")
            concat(parts, clip, workdir)
            length = duration(clip)
            frame = os.path.join(out_dir, "frames", f"{number}-{beat['id']}.png")
            subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                 "-ss", f"{length * 0.7:.2f}", "-i", clip, "-frames:v", "1", frame],
                check=True,
            )
            print(f"{clip}: {length:.1f}s  {beat.get('caption', '')}")
        story = os.path.join(out_dir, "story.mp4")
        concat(story_parts, story, workdir)
        print(f"{story}: {duration(story):.1f}s")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main(sys.argv)
