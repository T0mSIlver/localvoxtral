# Install

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | bash
```

Or with Homebrew, from our own tap:

```bash
brew install --cask T0mSIlver/localvoxtral/localvoxtral
```

Or download the latest `.dmg` from [Releases](https://github.com/T0mSIlver/localvoxtral/releases/latest).

On first launch, a setup wizard walks you through the microphone and
Accessibility permissions, then asks which engine to use: run locally (it
downloads the models with live progress) or Mistral's hosted API (paste an
API key and there is nothing to download). Dictate the moment it finishes.
You can re-run the wizard any time from Settings.

> [!NOTE]
> **Requirements:** an Apple Silicon Mac running macOS 15 or later.

## Gatekeeper

Releases are ad-hoc signed, not notarized yet (see the
[roadmap](roadmap.md)). The installer script and the Homebrew cask handle
Gatekeeper for you. If
you install the DMG by hand and macOS blocks or stalls the first launch
("damaged", **Open Anyway**, or a hang on macOS 26), clear the quarantine
flag:

```bash
xattr -cr /Applications/localvoxtral.app
```

On macOS 26, a first launch that hangs forever is Gatekeeper's first-exec
scan stalling on the downloaded ad-hoc signature; `xattr -cr` alone does not
fix that variant, but a local re-sign does — the installer script already
does this for you:

```bash
codesign --force --deep --sign - /Applications/localvoxtral.app
```

## Updating

Run the installer script again, run `brew upgrade --cask localvoxtral` if you
installed with Homebrew, or download the newest `.dmg` and replace
`/Applications/localvoxtral.app` — settings and downloaded models are kept.
When an update ships improved config defaults, files you haven't edited are
refreshed automatically; files you have edited are never touched without
asking (see [Settings](dictation.md#settings)).

> [!NOTE]
> Because releases are ad-hoc signed, macOS may silently drop the
> Accessibility grant after an update. If the dictation hotkey stops
> working, toggle localvoxtral off and on in **System Settings → Privacy &
> Security → Accessibility**.

## Homebrew

The cask follows stable releases only, so `brew upgrade` never moves you onto
a nightly; nightlies come from the installer script (below). The tap is
[T0mSIlver/homebrew-localvoxtral](https://github.com/T0mSIlver/homebrew-localvoxtral),
and the release pipeline pins it to each stable release once that release is
public. The cask is not in Homebrew's own repository, which requires a
notarized app.

`brew uninstall --cask --zap localvoxtral` also removes settings, downloaded
engines and caches. It leaves two things that other apps can share: dictation
history (`~/Library/Application Support/default.store`) and models in
`~/.cache/huggingface`. Stored API keys stay in your login keychain.

The cask was first written by [@achembarpu](https://github.com/achembarpu).

## Nightly channel

Nightlies are built from `main` every night and published as prereleases.
They carry whatever landed that day and go through the same gates as a
stable release: unit tests, live speech-to-text integration, packaging, and a
launch smoke test. They are for people who want fixes and features as they
land and can live with a rough edge.

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | LOCALVOXTRAL_CHANNEL=nightly bash
```

Run that line again to update to the newest nightly. To go back to stable,
run the installer without `LOCALVOXTRAL_CHANNEL`; the stable build replaces
the nightly in `/Applications` and your settings and models are kept.

Nightlies are ad-hoc signed exactly like stable releases, so the Gatekeeper
note above applies to them too. To install one specific build, pass its tag:
`LOCALVOXTRAL_VERSION=v0.8.5-nightly.20260916`. The seven most recent
nightlies are kept and older ones are deleted, so pin a tag only for a build
you are testing right now.
