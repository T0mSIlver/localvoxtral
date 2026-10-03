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
[Releases](https://github.com/T0mSIlver/localvoxtral/releases/latest).
Releases are signed with Developer ID and notarized by Apple, so all three
open without a Gatekeeper prompt.

## Set up on first launch

On first launch, a setup wizard asks for the microphone and Accessibility
permissions. It then asks which engine to use.

The local engine downloads its models first. Mistral's hosted API needs only
an API key and downloads nothing.

You can dictate as soon as the wizard finishes. To run it again later, open
it from Settings.

## Update localvoxtral

Update the same way you installed:

- Run the installer script again.
- With Homebrew, run the upgrade:

  ```bash
  brew upgrade --cask localvoxtral
  ```

- Or download the newest DMG and replace the app in your Applications folder.

Updates keep your settings, your downloaded models and the config files you
edited ([how new defaults arrive](dictation.md#edit-the-polishing-prompts-and-dictionary)).

> [!NOTE]
> Releases before October 2026 were ad-hoc signed. After your first update
> from one of them, macOS asks for the Accessibility permission again, once.
> If the dictation hotkey does nothing, remove localvoxtral from **System
> Settings → Privacy & Security → Accessibility** (**Device Control and Data
> Access** on macOS 27) and add it back. Later updates keep the grant.

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

[@achembarpu](https://github.com/achembarpu) wrote the first version of the
cask.

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
you are testing now. Nightlies are notarized like stable releases. The rare
nightly built while signing was unavailable says so at the top of its
release notes; install it with the installer script, which re-signs it on
your Mac.
