# Install

Install localvoxtral, update it, remove it, or switch to nightly builds.
You need an Apple Silicon Mac running macOS 15 or later.

## Install localvoxtral

Pick one of three ways. The installer script is the simplest:

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | bash
```

Homebrew users can install from our own tap:

```bash
brew install --cask T0mSIlver/localvoxtral/localvoxtral
```

You can also download the latest DMG from
[Releases](https://github.com/T0mSIlver/localvoxtral/releases/latest). The
script and the cask get past Gatekeeper for you; a DMG you install by hand
may need the steps in [Fix a blocked first launch](#fix-a-blocked-first-launch).

## Set up on first launch

On first launch, a setup wizard asks for the microphone and Accessibility
permissions. It then asks which engine to use.

The local engine downloads its models first. Mistral's hosted API needs only
an API key and downloads nothing.

You can dictate as soon as the wizard finishes. To run it again later, open
it from Settings.

## Fix a blocked first launch

Releases are ad-hoc signed and not notarized yet (see the
[roadmap](roadmap.md)). The installer script and the Homebrew cask handle
Gatekeeper for you.

If you installed the DMG by hand, macOS may block or stall the first launch.
It may call the app "damaged", ask you to click **Open Anyway**, or hang on
macOS 26. Clear the quarantine flag:

```bash
xattr -cr /Applications/localvoxtral.app
```

On macOS 26, a first launch that hangs forever means Gatekeeper's first-run
scan has stalled on the downloaded ad-hoc signature. Clearing the quarantine
flag alone does not fix this. Re-signing the app on your Mac does, and the
installer script already does it for you:

```bash
codesign --force --deep --preserve-metadata=entitlements --sign - /Applications/localvoxtral.app
```

## Update localvoxtral

Update the same way you installed:

- Run the installer script again.
- With Homebrew, run the upgrade:

  ```bash
  brew upgrade --cask localvoxtral
  ```

- Or download the newest DMG and replace the app in your Applications folder.

Updates keep your settings and downloaded models. When an update ships new
config defaults, it refreshes the config files you haven't edited. It asks
before it touches the ones you have edited (see [Settings](dictation.md#settings)).

> [!NOTE]
> Because releases are ad-hoc signed, macOS may silently drop the
> Accessibility grant after an update. If the dictation hotkey stops
> working, toggle localvoxtral off and on in **System Settings → Privacy &
> Security → Accessibility**.

## Uninstall with Homebrew

This command also removes settings, downloaded engines and caches:

```bash
brew uninstall --cask --zap localvoxtral
```

It leaves two things that other apps can share. Models stay in
`~/.cache/huggingface`, and so does `~/Library/Application Support/default.store`,
where older versions kept the dictation history. Stored API keys stay in
your login keychain.

## The Homebrew cask

The cask follows stable releases. A stable release ships every day that the
main branch has something new and checked, so a Homebrew upgrade never moves
you onto a nightly.

The tap is
[T0mSIlver/homebrew-localvoxtral](https://github.com/T0mSIlver/homebrew-localvoxtral).
The release pipeline points it at each stable release once that release is
public.

The cask is not in Homebrew's own repository, because that repository
requires a notarized app. [@achembarpu](https://github.com/achembarpu) wrote
the first version of the cask.

## Try a nightly build

Stable releases ship daily, so most people need nothing else. Nightlies are
prereleases of the main branch, cut on demand, for testing a fix before the
next daily release.

Nightlies pass the same checks as a stable release except the end-to-end
dictation check. They pass unit tests, live speech-to-text integration,
packaging, and a launch smoke test.

To install the newest nightly or stable release, whichever is newer, run:

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | LOCALVOXTRAL_CHANNEL=nightly bash
```

Re-running that command never leaves you behind stable. To follow stable
only, run the [plain installer command](#install-localvoxtral) instead. Your
settings and models are kept either way.

To install one specific build, pass its tag:

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | LOCALVOXTRAL_VERSION=v0.8.5-nightly.20260916 bash
```

Only the seven most recent nightlies are kept, so pin a tag only for a build
you are testing now. Nightlies are ad-hoc signed like stable releases, so
[Fix a blocked first launch](#fix-a-blocked-first-launch) applies to them too.
