#!/bin/bash
# Decides whether CI's LLM-inference lanes (the polishd live-model integration
# step) must run for a given change. Kept as a standalone script so the
# decision logic is testable locally — workflows only register on main, which
# makes pre-merge workflow testing awkward.
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
# the rule (and the matching human judgment call) lives in docs/agent/test-tiers.md under
# "When must the LLM lanes run?". Some patterns are forward-looking for
# in-flight branches (EvalCorpus, RepoVocabulary, clipboard context); an
# unmatched pattern costs nothing.
#
# The Claude Code context paths ARE here as of the branch that first fed them
# into a prompt: the joined session's repository contents, its prior user
# prompt, and the marker join that decides which session (if any) those come
# from all now alter what reaches the model. The registry/broker/transport are
# included with them — they are what the join resolves against, so a change to
# session liveness or workspace trust changes which repo gets attached.
PATTERNS=(
  'PolishHelper/*'                                   # helper engine, server, its own package
  'Sources/localvoxtral/Resources/Config/llm_*.toml' # bundled polish prompts
  '*PolishModelCatalog*'                             # model pins / catalog
  '*HFModelDownloader*'                              # which revision/files of the weights we fetch
  '*LLMPolishing*'                                   # polish client: request shape, sampling, kwargs
  '*PolishTokenGuard*'                               # token-protection repair semantics
  '*PolishPromptWarmup*'                             # prompt-prefix warmup path
  '*PolishContextClipboardReader*'                   # clipboard-as-context attachment
  '*PolishContextBudget*'                            # how many context chars reach the model (+ the message composer)
  '*PolishContextExcerptSelector*'                   # WHICH context lines reach the model
  '*PolishContextGrounding*'                         # cross-source grounding merge: what gets pre-applied
  '*PolishContextPreparation*'                       # matching + selection over the retained buffer
  '*ClipboardPayloadMacro*'                          # spoken paste-clipboard macro placeholders
  '*RepoVocabulary*'                                 # repo vocabulary hints fed to the polisher
  '*LearnedTerm*'                                    # what earlier dictations taught, fed back into the prompt
  # phonetic grounding tier: feeds what gets pre-applied/suggested
  '*DoubleMetaphone*'
  '*ClaudeRepoCollector*'                            # what repository content is harvested for the prompt
  '*ClaudeRepoContentFilter*'                        # which repo files/dirs are eligible at all
  '*ClaudeRepoContextSelection*'                     # WHICH repo sections/lines reach the model
  '*ClaudeRepoContextPreparation*'                   # repo matching + selection over the harvest
  '*ClaudeContextBlocks*'                            # the repo/session prompt blocks and their framing
  '*TerminalScreenClaudeJoin*'                       # which session (if any) the context comes from
  '*ClaudeSessionRegistry*'                          # session liveness: what the join resolves against
  '*ClaudeSessionState*'                             # the snapshot the session block renders from
  '*ClaudeTransportOrigin*'                          # workspace trust: whether a cwd can be read at all
  'Sources/localvoxtral/ClaudeContext/*'             # every gate/collector/renderer feeding the Claude blocks
  '*ClaudeContextBroker*'                            # the socket that feeds the registry
  '*ClaudeHookWire*'                                 # the record shape the snapshot is reduced from
  '*ClaudeHookInputParser*'                          # which hook fields become session state
  '*ClaudeHookPublisher*'                            # the identity metadata (tty/pid/herdr pane) joins key on
  'integrations/claude-code/*'                       # the plugin that publishes those hooks
  'integrations/opencode/*'                          # the opencode publisher: prompt extraction, cwd, file grounding
  '*TerminalScreenContext*'                          # screen context source/policy feeding the prompt
  '*TerminalScreenAXReader*'                         # screen text sanitization/compaction: the excerpt's exact bytes
  '*TerminalScreenAppleScriptReader*'                # iTerm2/Terminal.app focused-pane contents: the excerpt's exact bytes
  '*TerminalFocusedTTYReader*'                       # per-terminal tty readers: which session the context comes from
  '*BrowserTabURLReader*'                            # per-browser focused-tab url reads: which session the context comes from
  '*ClaudeDesktopSessionReader*'                     # Claude Desktop focused web view address: which session the context comes from
  '*DictationViewModel+Session.swift'                # polish-and-commit path
  'Sources/localvoxtral/DictationViewModel.swift'    # context capture/gate call sites feeding the commit path
  '*LLMPolishEvalSupport*'                           # shared eval corpus + scorer
  '*PolishHelperIntegrationTests*'                   # the lane's own suite
  '*AgentDictationE2EEval*'                          # agent-dictation E2E eval harness (suite + support + its unit tests)
  '*AgentDictationEvalCorpus*'                       # the E2E corpus loader/schema
  '*EvalCorpus/*'                                    # standalone eval corpora
)

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <changed-files-file> [marker-text-file]" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
MARKER_TEXT_FILE="${2:-}"

# Files under the ClaudeContext catch-all that install, configure or keep a
# tunnel open, and neither read context nor decide which session it comes
# from. The live lane replays the eval corpus through the packaged helper, so
# it cannot see a change to any of them, and between them they were most of why
# the lane ran in 60 % of mac-lanes runs (#418): live 4B inference on the
# owner's MacBook for an enrollment or settings diff.
#
# An EXEMPTION list under a catch-all, not an allowlist in its place, so a new
# file in that directory runs the lane until someone decides it should not.
# A file belongs here only if NO other pattern above matches it
# (test-llm-lane-filter.sh checks that), and only if the answer to "can this
# change what reaches the model, or which session's context does" is no:
# anything that resolves a join, reads a screen or a repository, or accepts or
# rejects a hook record stays out. Two that look like plumbing and are not:
# ClaudeRemoteListenerCoordinator evicts remote sessions from the registry the
# join resolves against, and CmuxSocketPasswordStore decides whether the cmux
# client authenticates, which decides whether that join arm resolves at all.
EXEMPT=(
  'Sources/localvoxtral/ClaudeContext/AGENTS.md'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel.swift'  # Settings pane model
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationLiveIO.swift'         # its process/file seams
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteEnrollmentService.swift'   # one-time host setup over ssh
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteEnrollmentLiveIO.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudePluginInstallService.swift'      # `claude plugin` install/update
  'Sources/localvoxtral/ClaudeContext/ClaudePluginListing.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudePluginStatus.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudePluginAssets.swift'              # locates the bundled marketplace
  'Sources/localvoxtral/ClaudeContext/ClaudeMarketplaceMirror.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudePublisherPointer.swift'
  'Sources/localvoxtral/ClaudeContext/OpencodePluginInstallService.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeStatuslineInstallService.swift'  # status line indicator
  'Sources/localvoxtral/ClaudeContext/ClaudeStatuslineCombine.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeShellRCSetup.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardCoordinator.swift'  # keeping the ssh forward alive
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardLiveProcess.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardOrphanReaper.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardOwnership.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardPidLedger.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardPort.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardSupervisor.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteTokenRedaction.swift'      # log redaction
  'Sources/localvoxtral/ClaudeContext/ClaudeSurfaceProbeCommand.swift'       # the --probe-surface CLI wrapper
)

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

is_exempt() {
  local exempt
  for exempt in "${EXEMPT[@]}"; do
    [[ "$1" == "$exempt" ]] && return 0
  done
  return 1
}

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  is_exempt "$file" && continue
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
