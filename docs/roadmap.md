# Roadmap

- [ ] Developer ID signing + notarization — install with no Gatekeeper
      workarounds
- [ ] Hotword boosting in the speech model itself — bias transcription (not
      only polishing) toward your repo's vocabulary
      ([#316](https://github.com/T0mSIlver/localvoxtral/issues/316), gated on
      the eval corpus in
      [#315](https://github.com/T0mSIlver/localvoxtral/issues/315))
- [ ] Claude Code session joins on more terminals — WezTerm is next;
      tmux support
- [ ] Repo context for remote sessions — collect git status, diffs and
      recently touched files on the enrolled host over the app's own ssh, so
      a joined remote session grounds polishing the way a local one does
- [ ] Documentation website — a visual, end-user guide beyond these docs
- [ ] More streaming ASR models beyond Voxtral Realtime — e.g.
      [NVIDIA Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)

## Specified and open

Smaller than the lines above, and already written up with scope, the
constraints this repo adds, and the proof a PR needs to carry.

- [Duck other audio while dictating, and fade it back](https://github.com/T0mSIlver/localvoxtral/issues/375)
- [A dropped WebSocket ends the dictation instead of reconnecting](https://github.com/T0mSIlver/localvoxtral/issues/380)
- [Dictation history you can actually look at](https://github.com/T0mSIlver/localvoxtral/issues/378)
- [Let the overlay be moved, and remember where](https://github.com/T0mSIlver/localvoxtral/issues/379)
- [The shortcut recorder refuses function keys that would work fine](https://github.com/T0mSIlver/localvoxtral/issues/377)

Several of these came from people who forked the repo and solved the problem
for themselves. The
[`from-fork`](https://github.com/T0mSIlver/localvoxtral/labels/from-fork)
label tracks them; a PR that takes one credits the author it came from.
