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
#                         the lanes run regardless of the diff. A
#                         [skip-llm-eval: <reason>] marker waives a path match
#                         instead; it needs a non-empty reason, and
#                         [run-llm-eval] beside it wins.
#
# stdout is $GITHUB_OUTPUT-shaped:
#   run=true|false
#   reason=<one line, safe for a step summary>
#   skip_marker=absent|waived|no-reason|overridden|unneeded
#     what the skip marker did: skipped a matching diff (waived), was ignored
#     for want of a reason (no-reason), lost to [run-llm-eval] (overridden),
#     or met a diff that skipped anyway (unneeded)
#
# Exits 0 for both decisions; non-zero only on usage errors. The caller owns
# fail-open behavior when it cannot produce a diff at all.
set -euo pipefail

MARKER='[run-llm-eval]'
SKIP_MARKER='skip-llm-eval'

# LLM-relevant paths. A path belongs here when changing it can alter what
# reaches the model, how the model is run, or how its output is scored —
# the rule (and the matching human judgment call) lives in docs/agent/test-tiers.md under
# "When must the LLM lanes run?". Some patterns are forward-looking for
# in-flight branches (EvalCorpus, RepoVocabulary, clipboard context); an
# unmatched pattern costs nothing.
#
# The Claude Code context paths here are the ones that shape the CONTENT of
# the Claude blocks: what repository text is harvested and selected, how the
# blocks are framed, what screen text becomes the excerpt. The join (which
# session, if any, the context comes from), the hook publishers and parsers,
# the broker and registry, and the agent integrations are NOT here (owner call,
# #643): the live lane replays a fixed corpus through LLMPolishingService and
# executes none of them, and PolishRequestGoldenTests pins what a join hands
# the request (docs/agent/test-tiers.md, "When must the LLM lanes run?").
PATTERNS=(
  'PolishHelper/*'                                   # helper engine, server, its own package
  'Sources/localvoxtral/Resources/Config/llm_*.toml' # bundled polish prompts
  'Sources/localvoxtralCore/AppConfigStore.swift'    # loads, validates and renders those prompts
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
  '*RepoGitRunner*'                                  # the git subprocess both repo vocabulary and repo context read through
  '*ClipboardVocabulary*'                            # clipboard identifiers matched like repo vocabulary
  'Sources/localvoxtralCore/StringExtensions.swift'  # the control-character sanitizer for context and prompt terms
  '*LearnedTerm*'                                    # what earlier dictations taught, fed back into the prompt
  # phonetic grounding tier: feeds what gets pre-applied/suggested
  '*DoubleMetaphone*'
  '*ClaudeRepoCollector*'                            # what repository content is harvested for the prompt
  '*ClaudeRepoContentFilter*'                        # which repo files/dirs are eligible at all
  '*ClaudeRepoContextSelection*'                     # WHICH repo sections/lines reach the model
  '*ClaudeRepoContextPreparation*'                   # repo matching + selection over the harvest
  '*ClaudeContextBlocks*'                            # the repo/session prompt blocks and their framing
  '*SocketPaneScreenContext*'                        # a herdr or cmux pane's text: the excerpt's bytes on those joins
  '*ClaudeSessionState*'                             # the snapshot the session block renders from
  'Sources/localvoxtral/ClaudeContext/*'             # every gate/collector/renderer feeding the Claude blocks
  'Sources/localvoxtralCore/ClaudeContext/*'         # the same, moved to the core so it builds on Linux (#591)
  '*TerminalScreenContext*'                          # screen context source/policy feeding the prompt
  '*TerminalScreenAXReader*'                         # the AX screen read: which pane's text becomes the excerpt
  '*TerminalScreenText*'                             # screen text sanitization/compaction: the excerpt's exact bytes
  '*TerminalScreenAppleScriptReader*'                # iTerm2/Terminal.app focused-pane contents: the excerpt's exact bytes
  '*SessionContextResolver*'                        # the context gates themselves (#432 step 4b)
  '*PolishRequestAssembler*'                        # sections, pre-application, prompts, blocks (#432 step 5)
  '*PolishOutcomeClassifier*'                       # placeholder integrity, failure copy (#432 step 5)
  '*PolishContextGatherer*'                         # the gather step: budgets, preparations, merge (#432 step 6)
  '*RepoVocabularyGrounding*'                       # the repository-vocabulary pipeline and its gates (#432 step 6)
  '*StopCommitCoordinator*'                         # the stop-commit's polish: prepare, templates, profile, send (#432 steps 7, 7b)
  '*DictationSessionController+StopCommit*'         # what the session hands it: transcript, latched dictionary, commit target (#432)
  '*EarlyPolish*'                                   # pieces polished while speaking and the tail the stop sends (#709)
  '*LLMPolishEvalSupport*'                           # shared eval corpus + scorer
  '*PolishHelperIntegrationTests*'                   # the lane's own suite
  '*AgentDictationE2EEval*'                          # agent-dictation E2E eval harness (suite + support + its unit tests)
  '*AgentDictationEvalCorpus*'                       # the E2E corpus loader/schema
  '*EvalSpeechStage*'                                # the E2E harness's TTS and ASR stage, shared with term recall
  '*RecordedAudioSet*'                               # the E2E harness's human-recording reader, shared with term recall
  '*EvalCorpus/*'                                    # standalone eval corpora
)

# A test file cannot change what reaches the model, so a path under a Tests/
# directory runs the lane only when it is the lane's own suite or the eval
# harness it shares (docs/agent/test-tiers.md: the lanes are "NOT required for
# ... test-only changes"). Without this, the name globs above bought live 4B
# inference for unit-test edits and test-target moves (#545), since bash `case`
# lets `*` cross `/` and a test named after its subject matches the subject's
# pattern. Sources stay matched by name, whatever target they move to.
LANE_TEST_PATTERNS=(
  '*LLMPolishEvalSupport*'
  '*PolishHelperIntegrationTests*'
  '*AgentDictationE2EEval*'
  '*AgentDictationEvalCorpus*'
  '*EvalSpeechStage*'
  '*RecordedAudioSet*'
)

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <changed-files-file> [marker-text-file]" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
MARKER_TEXT_FILE="${2:-}"

# Files under the ClaudeContext catch-alls that neither shape the content of
# the Claude blocks nor read a screen or a repository: installs, settings,
# tunnels, and (owner call, #643) the join and hook plumbing that decides
# WHICH session the context comes from. The live lane replays the eval corpus
# through the packaged helper, so it cannot see a change to any of them, and
# PolishRequestGoldenTests pins what a join hands the request.
#
# An EXEMPTION list under a catch-all, not an allowlist in its place, so a new
# file in those directories runs the lane until someone decides it should not.
# A file belongs here only if NO other pattern above matches it
# (test-llm-lane-filter.sh checks that), and only if it cannot change the
# bytes of a block: anything that harvests, selects, frames or sanitizes
# repository or screen text stays out.
EXEMPT=(
  'Sources/localvoxtral/ClaudeContext/AGENTS.md'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel.swift'  # Settings pane model, and its files by area
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+Cmux.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+EnrollmentActions.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+EnrollmentTypes.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+HerdrMachines.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+HerdrPanel.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+HostRow.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+IntegrationRows.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+Listener.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+ListenerStatus.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+Opencode.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+Plugin.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+Preview.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+RemoteHosts.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+SetupRun.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+ShellSetup.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+Statusline.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+Verification.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeIntegrationSettingsModel+Vibe.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeIntegrationActionAttempts.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudePluginInstalling.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeShellSetupStatus.swift'
  'Sources/localvoxtralCore/ClaudeContext/RemoteHostSetupRun.swift'
  'Sources/localvoxtralCore/ClaudeContext/HerdrMachineImport.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeIntegrationLiveIO.swift'         # its process/file seams
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService.swift'   # one-time host setup over ssh
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+Types.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+Plan.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+SSHConfig.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+RemoteSetup.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+RemotePlugin.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+RemoteEnvironment.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+RemoteHerdr.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+LocalHerdrPanel.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService+Verification.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteSSHConfigFileSystem.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeLocalHerdrConfigFileSystem.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentLiveIO.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudePluginInstallService.swift'      # `claude plugin` install/update
  'Sources/localvoxtralCore/ClaudeContext/ClaudePluginListing.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudePluginStatus.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudePluginAssets.swift'              # locates the bundled marketplace
  'Sources/localvoxtralCore/ClaudeContext/ClaudeMarketplaceMirror.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudePublisherPointer.swift'
  'Sources/localvoxtralCore/ClaudeContext/OpencodePluginInstallService.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeStatuslineInstallService.swift'  # status line indicator
  'Sources/localvoxtralCore/ClaudeStatuslineCombine.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeShellRCSetup.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardCoordinator.swift'  # keeping the ssh forward alive
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteForwardLiveProcess.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteForwardOrphanReaper.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteForwardOwnership.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteForwardPidLedger.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteForwardPort.swift'
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardSupervisor.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteForwardProcess.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteTokenRedaction.swift'      # log redaction
  'Sources/localvoxtral/ClaudeContext/ClaudeSurfaceProbeCommand.swift'       # the --probe-surface CLI wrapper
  # The join and hook plumbing (owner call, #643)
  'Sources/localvoxtral/ClaudeContext/ClaudeRemoteHerdrForward.swift'
  'Sources/localvoxtral/ClaudeContext/CmuxSocketClient+RunningApplication.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeContextBroker.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeJoinAbstentionTap.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteContextListener.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteHerdrForwarding.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteHostRegistry.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteListenerCoordinator.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteRejection.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinResolver+BrowserTab.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinResolver+Cmux.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinResolver+DesktopSession.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinResolver+FederatedHerdr.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinResolver+Herdr.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinResolver+PlainSSH.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinResolver+RemoteHerdr.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinResolver+RemoteLocalTTY.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinResolver.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionJoinSummary.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionRegistry.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSessionStore.swift'
  'Sources/localvoxtralCore/ClaudeContext/ClaudeSurfaceProbe.swift'
  'Sources/localvoxtralCore/ClaudeContext/CmuxSocketClient.swift'
  'Sources/localvoxtralCore/ClaudeContext/CmuxSocketPasswordStore.swift'
  'Sources/localvoxtralCore/ClaudeContext/CmuxSurfaceQuerying.swift'
  'Sources/localvoxtralCore/ClaudeContext/HerdrClientTTYProbe.swift'
  'Sources/localvoxtralCore/ClaudeContext/HerdrMachineFederation.swift'
  'Sources/localvoxtralCore/ClaudeContext/HerdrPanelBindingProbe.swift'
  'Sources/localvoxtralCore/ClaudeContext/HerdrSocketClient.swift'
  'Sources/localvoxtralCore/ClaudeContext/MarkedTextBlock.swift'
  'Sources/localvoxtralCore/ClaudeContext/SSHDestinationCanonicalizer.swift'
  'Sources/localvoxtralCore/ClaudeContext/SSHDestinationTTYProbe.swift'
  'Sources/localvoxtralCore/ClaudeContext/SSHProcessSocketReader.swift'
  'Sources/localvoxtralCore/ClaudeContext/TerminalScreenClaudeJoin.swift'
  'Sources/localvoxtralCore/ClaudeContext/TerminalScreenClaudeJoinAuthorizer.swift'
  'Sources/localvoxtralCore/ClaudeContext/VibeHooksBlockEditor.swift'
  'Sources/localvoxtralCore/ClaudeContext/VibeHooksInstallService.swift'
  'Sources/localvoxtralCore/ClaudeContext/VibeRemoteHooksSetup.swift'
)

if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "changed-files file not found: $CHANGED_FILES_FILE" >&2
  exit 2
fi

# The skip marker: [skip-llm-eval: <reason>]. A waiver is only as good as its
# written reason, so a bare [skip-llm-eval] or a blank reason is found but
# waives nothing. Several markers: the first one with a reason counts.
# SKIP_STATE is absent, no-reason or present; SKIP_REASON holds the reason.
SKIP_STATE=absent
SKIP_REASON=""
if [[ -n "$MARKER_TEXT_FILE" && -f "$MARKER_TEXT_FILE" ]]; then
  while IFS= read -r found; do
    [[ -z "$found" ]] && continue
    candidate="$(sed -E 's/^\[skip-llm-eval:?//; s/\]$//; s/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$found")"
    if [[ -n "$candidate" ]]; then
      SKIP_STATE=present
      SKIP_REASON="$candidate"
      break
    fi
    SKIP_STATE=no-reason
  done < <(tr -d '\r' <"$MARKER_TEXT_FILE" | grep -oE '\[skip-llm-eval(:[^]]*)?\]' || true)
fi

if [[ -n "$MARKER_TEXT_FILE" && -f "$MARKER_TEXT_FILE" ]] \
    && grep -qF "$MARKER" "$MARKER_TEXT_FILE"; then
  echo "run=true"
  if [[ "$SKIP_STATE" == "absent" ]]; then
    echo "reason=explicit $MARKER marker"
    echo "skip_marker=absent"
  else
    echo "reason=explicit $MARKER marker, which overrides the $SKIP_MARKER marker beside it"
    echo "skip_marker=overridden"
  fi
  exit 0
fi

is_exempt() {
  local exempt
  for exempt in "${EXEMPT[@]}"; do
    [[ "$1" == "$exempt" ]] && return 0
  done
  return 1
}

is_test_path() {
  case "$1" in
    Tests/* | */Tests/*) return 0 ;;
  esac
  return 1
}

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  is_exempt "$file" && continue
  if is_test_path "$file"; then
    candidates=("${LANE_TEST_PATTERNS[@]}")
  else
    candidates=("${PATTERNS[@]}")
  fi
  for pattern in "${candidates[@]}"; do
    # shellcheck disable=SC2254
    case "$file" in
      $pattern)
        case "$SKIP_STATE" in
          present)
            echo "run=false"
            echo "reason=waived by the $SKIP_MARKER marker: $SKIP_REASON (the diff matched $file ($pattern))"
            echo "skip_marker=waived"
            ;;
          no-reason)
            echo "run=true"
            echo "reason=matched $file ($pattern); the $SKIP_MARKER marker was ignored because it gives no reason"
            echo "skip_marker=no-reason"
            ;;
          *)
            echo "run=true"
            echo "reason=matched $file ($pattern)"
            echo "skip_marker=absent"
            ;;
        esac
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
case "$SKIP_STATE" in
  present) echo "skip_marker=unneeded" ;;
  no-reason) echo "skip_marker=no-reason" ;;
  *) echo "skip_marker=absent" ;;
esac
