#!/usr/bin/env bash
# Prints the Homebrew cask for one STABLE release.
#
# Usage:
#   scripts/ci/render-cask.sh <tag> <sha256-of-the-app-zip>
#
# The cask lives in the tap, T0mSIlver/homebrew-localvoxtral, and nowhere in
# this repository: cask.yml renders it after a stable release publishes and
# pushes it there. main carries a required-status-checks ruleset, so a release
# could not commit a new pin here without a PR per release.
#
# Stable only. `brew upgrade` compares version strings, and a nightly
# (vX.Y.Z-nightly.DATE) or an rc in the same cask would move stable users onto
# a prerelease. The tag shape is checked here so every caller gets the refusal.
#
# Original cask by @achembarpu (achembarpu/localvoxtral, feat/homebrew-cask).
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <tag> <sha256>" >&2
  exit 2
fi

TAG="$1"
SHA256="$2"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "refusing to render a cask for a tag that is not a stable vX.Y.Z: $TAG" >&2
  exit 2
fi
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "refusing to render a cask with a sha256 that is not 64 lowercase hex digits: $SHA256" >&2
  exit 2
fi

VERSION="${TAG#v}"

cat <<EOF
cask "localvoxtral" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/T0mSIlver/localvoxtral/releases/download/v#{version}/localvoxtral-v#{version}.zip"
  name "localvoxtral"
  desc "Realtime dictation from the menu bar"
  homepage "https://github.com/T0mSIlver/localvoxtral"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "localvoxtral.app"

  # Releases are ad-hoc signed and not notarized. On macOS 26 Gatekeeper's
  # first-exec scan can hang forever on a downloaded foreign ad-hoc signature,
  # and clearing quarantine alone does not fix it; a local re-sign does.
  # scripts/install.sh does the same two things for the same reason.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/localvoxtral.app"]
    system_command "/usr/bin/codesign",
                   args: ["--force", "--deep", "--sign", "-", "#{appdir}/localvoxtral.app"]
  end

  uninstall quit: "com.localvoxtral.app"

  # Dictation history is not listed: it lives in SwiftData's default store,
  # ~/Library/Application Support/default.store, a name other apps can share.
  # Downloaded models in ~/.cache/huggingface are shared too.
  zap trash: [
    "~/Library/Application Support/localvoxtral",
    "~/Library/Caches/com.localvoxtral.app",
    "~/Library/HTTPStorages/com.localvoxtral.app",
    "~/Library/Preferences/com.localvoxtral.app.plist",
    "~/Library/Saved Application State/com.localvoxtral.app.savedState",
  ]

  caveats <<~EOS
    On first launch a setup wizard asks for the microphone and Accessibility
    permissions, then for an engine: local models (downloaded once) or
    Mistral's hosted API (paste a key, nothing to download).

    Releases are ad-hoc signed, so macOS may drop the Accessibility grant
    after an upgrade. If the dictation shortcut stops working, toggle
    localvoxtral off and on in System Settings > Privacy & Security >
    Accessibility.
  EOS
end
EOF
