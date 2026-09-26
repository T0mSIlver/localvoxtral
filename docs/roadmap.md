# Roadmap

- [ ] Developer ID signing and notarization, so installing needs no
      Gatekeeper workarounds
- [ ] Hotword boosting in the speech model itself, to bias transcription (not
      only polishing) toward your repo's vocabulary
      ([#316](https://github.com/T0mSIlver/localvoxtral/issues/316), waiting on
      the eval corpus in
      [#315](https://github.com/T0mSIlver/localvoxtral/issues/315))
- [ ] Claude Code session joins on more terminals: WezTerm is next, then
      tmux support
- [ ] Repo context for remote sessions: collect git status, diffs and
      recently touched files on the enrolled host over the app's own ssh, so
      polishing for a joined remote session gets the same context as a local one
- [ ] Documentation website: a visual end-user guide beyond these docs
- [ ] Revisable transcripts for the Overlay Buffer, so a streaming model can
      correct text it has already emitted
      ([#383](https://github.com/T0mSIlver/localvoxtral/issues/383); the second
      streaming ASR model it asked for,
      [NVIDIA Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b),
      shipped in [#463](https://github.com/T0mSIlver/localvoxtral/issues/463))

## Specified and open

These are smaller than the items above. Each issue already states its scope,
the constraints this repo adds, and the proof a PR must carry.

- [Duck other audio while dictating, and fade it back](https://github.com/T0mSIlver/localvoxtral/issues/375)
- [A dropped WebSocket ends the dictation instead of reconnecting](https://github.com/T0mSIlver/localvoxtral/issues/380)
- [Let the overlay be moved, and remember where](https://github.com/T0mSIlver/localvoxtral/issues/379)
- [The shortcut recorder refuses function keys that would work fine](https://github.com/T0mSIlver/localvoxtral/issues/377)

Several of these came from people who forked the repo and solved the problem
for themselves. The
[`from-fork`](https://github.com/T0mSIlver/localvoxtral/labels/from-fork)
label tracks them, and a PR that takes one up credits the original author.
