<h1 align="center">localvoxtral</h1>

<p align="center">
  <img src="assets/icons/app/AppIcon.png" alt="localvoxtral app icon" width="128" height="128" />
</p>

<p align="center">
  <strong>Talk to your coding agents. Keep every word on your Mac.</strong><br />
  Realtime, fully local dictation for the menu bar. Press a key and speak — your words appear while you're still talking.
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="docs/README.md">Documentation</a> ·
  <a href="docs/coding-agents.md">Coding agents</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <a href="https://github.com/T0mSIlver/localvoxtral/stargazers"><img src="https://img.shields.io/github/stars/T0mSIlver/localvoxtral?style=social" alt="GitHub stars" /></a>
  &nbsp;
  <a href="https://github.com/T0mSIlver/localvoxtral/releases/latest"><img src="https://img.shields.io/github/v/release/T0mSIlver/localvoxtral?label=release" alt="Latest release" /></a>
  &nbsp;
  <a href="LICENSE"><img src="https://img.shields.io/github/license/T0mSIlver/localvoxtral" alt="License" /></a>
</p>

https://github.com/user-attachments/assets/81a341ff-0c53-4fcf-9b7f-ef148b24dfae

Unlike tools that transcribe after you stop speaking, localvoxtral streams text as the audio arrives, powered by Mistral AI's [Voxtral Mini 4B Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) running on your own Apple Silicon. It is built first for [prompting coding agents by voice](docs/coding-agents.md), and it stays a solid general dictation app everywhere else. Everything runs on-device — no account, no subscription, nothing leaving your Mac.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | bash
```

Or download the latest `.dmg` from [Releases](https://github.com/T0mSIlver/localvoxtral/releases/latest). Requires an Apple Silicon Mac on macOS 15+. A first-launch wizard handles permissions and the engine download; if Gatekeeper complains about a hand-installed DMG, see the [install guide](docs/install.md).

## Features

- **Built for coding agents** — dictate prompts straight into any CLI agent ([opencode](integrations/opencode/README.md) gets its own plugin), in any terminal — Warp, WezTerm, kitty, Alacritty, and more; polishing understands developer speech: "dash dash force" → `--force`, "use auth dot t s" → `useAuth.ts` ([details](docs/coding-agents.md))
- **Claude Code aware** — dictation joins the *exact* session under your cursor — Ghostty, iTerm2, Terminal.app, a single [herdr](https://herdr.dev) or [cmux](https://github.com/manaflow-ai/cmux) pane, over SSH, or a [claude.ai/code](https://claude.ai/code) Remote Control tab in your browser — and grounds polishing in its screen, your last prompt, the files Claude just touched, and that repo's vocabulary ([details](docs/coding-agents.md#dictating-into-claude-code))
- **One key, two modes** — tap for a reviewable overlay with optional LLM polishing, hold to stream words live into the focused app ([shortcuts](docs/dictation.md))
- **Private by default** — audio, transcription, and polishing are local processes; no telemetry, no account, no cloud fallback ([how it works](docs/under-the-hood.md))
- **Menu bar native** — instant popover with dictation status at a glance, microphone picker, auto-copy of the final text, and the raw transcript one click away after a polished commit
- **Bring your own server** — dictation and polishing can each point at any OpenAI-compatible endpoint instead of the built-in local engines
- **Multilingual** — dictate in English, French, or any language [Voxtral](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) understands; polishing answers in the language you spoke (English and French are covered by the test suite)

> [!TIP]
> If localvoxtral is useful to you, a ⭐ on this repo helps others find it.

## Documentation

- [Install](docs/install.md) — one-liner, requirements, Gatekeeper notes
- [Dictating](docs/dictation.md) — shortcuts, output modes, settings, screenshots
- [Terminals & coding agents](docs/coding-agents.md) — Claude Code session joins, the SSH remote plugin, repo vocabulary
- [Under the hood](docs/under-the-hood.md) — privacy, the bundled engines and their pinned models, vLLM example
- [Building from source](docs/building.md) · [Roadmap](docs/roadmap.md)

## License

[MIT](LICENSE)
