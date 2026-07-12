#!/bin/bash
# Decides whether CI's LLM-inference lanes (the polishd live-model integration
# step) must run for a given change. Kept as a standalone script so the
# decision logic is testable locally — workflows only register on main, which
# makes pre-merge workflow testing awkward (see AGENTS.md).
#
# Usage:
#   scripts/ci/llm-lane-filter.sh <changed-files-file> [marker-text-file]
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#   [marker-text-file]    optional free text (PR body + head commit message);
#                         if it contains the literal marker [run-llm-eval],
#                         the lanes run regardless of the diff
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary>
#
# Exits 0 for both decisions; non-zero only on usage errors. The caller owns
# fail-open behavior when it cannot produce a diff at all.
set -euo pipefail

MARKER='[run-llm-eval]'

# LLM-relevant paths. A path belongs here when changing it can alter what
# reaches the model, how the model is run, or how its output is scored —
# the rule (and the matching human judgment call) lives in AGENTS.md under
# "When must the LLM lanes run?". Some patterns are forward-looking for
# in-flight branches (EvalCorpus, RepoVocabulary, clipboard context); an
# unmatched pattern costs nothing.
PATTERNS=(
  'PolishHelper/*'                                   # helper engine, server, its own package
  'Sources/localvoxtral/Resources/Config/llm_*.toml' # bundled polish prompts
  '*PolishModelCatalog*'                             # model pins / catalog
  '*LLMPolishing*'                                   # polish client: request shape, sampling, kwargs
  '*PolishTokenGuard*'                               # token-protection repair semantics
  '*PolishPromptWarmup*'                             # prompt-prefix warmup path
  '*PolishContextClipboardReader*'                   # clipboard-as-context attachment
  '*ClipboardPayloadMacro*'                          # spoken paste-clipboard macro placeholders
  '*RepoVocabulary*'                                 # repo vocabulary hints fed to the polisher
  '*DictationViewModel+Session.swift'                # polish-and-commit path
  '*LLMPolishEvalSupport*'                           # shared eval corpus + scorer
  '*PolishHelperIntegrationTests*'                   # the lane's own suite
  '*EvalCorpus/*'                                    # standalone eval corpora
)

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <changed-files-file> [marker-text-file]" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
MARKER_TEXT_FILE="${2:-}"

if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "changed-files file not found: $CHANGED_FILES_FILE" >&2
  exit 2
fi

if [[ -n "$MARKER_TEXT_FILE" && -f "$MARKER_TEXT_FILE" ]] \
    && grep -qF "$MARKER" "$MARKER_TEXT_FILE"; then
  echo "run=true"
  echo "reason=explicit $MARKER marker"
  exit 0
fi

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  for pattern in "${PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$file" in
      $pattern)
        echo "run=true"
        echo "reason=matched $file ($pattern)"
        exit 0
        ;;
    esac
  done
done <"$CHANGED_FILES_FILE"

echo "run=false"
# "and push": the marker is only read from the event payload at run-creation
# time — editing the PR body after a skipped run creates no new run, and
# reruns reuse the original payload, so a late-added marker needs a push.
echo "reason=no LLM-relevant changes; add $MARKER to the PR body or commit message and push to opt in"
