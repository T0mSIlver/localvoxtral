# Install

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | bash
```

Or with Homebrew, from our own tap:

```bash
brew install --cask T0mSIlver/localvoxtral/localvoxtral
```

Or download the latest `.dmg` from [Releases](https://github.com/T0mSIlver/localvoxtral/releases/latest).

On first launch, a setup wizard asks for the microphone and Accessibility
permissions, then asks which engine to use. The local engine downloads its
models first. Mistral's hosted API needs only an API key and downloads
nothing. You can dictate as soon as the wizard finishes, and re-run it from
Settings later.

> [!NOTE]
> **Requirements:** an Apple Silicon Mac running macOS 15 or later.

## Gatekeeper

Releases are ad-hoc signed, not notarized yet (see the
[roadmap](roadmap.md)). The installer script and the Homebrew cask handle
Gatekeeper for you. If you install the DMG by hand and macOS blocks or stalls
the first launch ("damaged", **Open Anyway**, or a hang on macOS 26), clear
the quarantine flag:

```bash
xattr -cr /Applications/localvoxtral.app
```

On macOS 26, a first launch that hangs forever means Gatekeeper's first-run
scan has stalled on the downloaded ad-hoc signature. `xattr -cr` alone does
not fix this. Re-signing the app locally does, and the installer script
already does it for you:

```bash
codesign --force --deep --preserve-metadata=entitlements --sign - /Applications/localvoxtral.app
```

## Updating

Run the installer script again, run `brew upgrade --cask localvoxtral` if you
installed with Homebrew, or download the newest `.dmg` and replace
`/Applications/localvoxtral.app`. Settings and downloaded models are kept.
When an update ships new config defaults, it refreshes the config files you
haven't edited and asks before touching the ones you have (see
[Settings](dictation.md#settings)).

> [!NOTE]
> Because releases are ad-hoc signed, macOS may silently drop the
> Accessibility grant after an update. If the dictation hotkey stops
> working, toggle localvoxtral off and on in **System Settings → Privacy &
> Security → Accessibility**.

## Homebrew

The cask follows stable releases only, so `brew upgrade` never moves you onto
a nightly. Nightlies come from the installer script (below). The tap is
[T0mSIlver/homebrew-localvoxtral](https://github.com/T0mSIlver/homebrew-localvoxtral),
and the release pipeline points it at each stable release once that release
is public. The cask is not in Homebrew's own repository, because that
repository requires a notarized app.

`brew uninstall --cask --zap localvoxtral` also removes settings, downloaded
engines and caches. It leaves two things that other apps can share: dictation
history (`~/Library/Application Support/default.store`) and models in
`~/.cache/huggingface`. Stored API keys stay in your login keychain.

The cask was first written by [@achembarpu](https://github.com/achembarpu).

## Nightly channel

Nightlies are built from `main` every night and published as prereleases.
They carry whatever landed that day and pass the same checks as a stable
release: unit tests, live speech-to-text integration, packaging, and a launch
smoke test. Use them if you want fixes and features as they land and can live
with rough edges.

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | LOCALVOXTRAL_CHANNEL=nightly bash
```

Run that line again to update to the newest nightly. To go back to stable,
run the installer without `LOCALVOXTRAL_CHANNEL`. The stable build replaces
the nightly in `/Applications`, and your settings and models are kept.

Nightlies are ad-hoc signed like stable releases, so the Gatekeeper section
above applies to them too. To install one specific build, pass its tag:
`LOCALVOXTRAL_VERSION=v0.8.5-nightly.20260916`. Only the seven most recent
nightlies are kept, so pin a tag only for a build you are testing now.
