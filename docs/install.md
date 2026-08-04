# Install

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | bash
```

Or download the latest `.dmg` from [Releases](https://github.com/T0mSIlver/localvoxtral/releases/latest).

On first launch, a setup wizard walks you through the microphone and
Accessibility permissions and downloads the local engine with live progress.
Dictate the moment it finishes. You can re-run the wizard any time from
Settings.

> [!NOTE]
> **Requirements:** an Apple Silicon Mac running macOS 15 or later.

## Gatekeeper

Releases are ad-hoc signed, not notarized yet (see the
[roadmap](roadmap.md)). The installer script handles Gatekeeper for you. If
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

Run the installer script again, or download the newest `.dmg` and replace
`/Applications/localvoxtral.app` — settings and downloaded models are kept.
When an update ships improved config defaults, files you haven't edited are
refreshed automatically; files you have edited are never touched without
asking (see [Settings](dictation.md#settings)).

> [!NOTE]
> Because releases are ad-hoc signed, macOS may silently drop the
> Accessibility grant after an update. If the dictation hotkey stops
> working, toggle localvoxtral off and on in **System Settings → Privacy &
> Security → Accessibility**.
