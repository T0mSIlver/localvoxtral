# Known tradeoffs & invariants — deliberate, not bugs

Read this in full before changing text insertion, LLM polishing, or anything
in the Claude Code context path (`Sources/ClaudeContext*`,
`Sources/localvoxtral*/ClaudeContext/`, `integrations/claude-code/`, the
remote listener/enrollment/forward code). The trust boundaries here are
load-bearing and non-obvious; several of them are the residue of measured
failures, with the evidence cited inline.

This file is loaded on demand (a router pointer in the root `AGENTS.md`), not
always-loaded agent context, so it carries no size cap — only the root
`AGENTS.md` does (`AgentsGuideSizeTests`). Growth here is by design; growth
there is not.

- **The TUI trailing-space policy judges this dictation's text only.** The
  terminal stop-flush verdict (`TUIAutocompleteTrailingSpace`, applied in
  `TextInsertionService`) cannot see text the field already held before
  dictation started, so dictating a lone command shape (`/compact `) into a
  prompt line pre-populated by hand withholds a trailing space no popup
  consumed. Accepted: the insertion path has no field-read capability and no
  popup-state signal exists, mid-line command-shaped dictation is rare, and
  the dismissed-popup case the policy exists for is the common one (pinned by
  `testPrePopulatedFieldTextCannotRescueTheTrailingSpace`). Single-component
  tokens naming an EXISTING absolute path (`/tmp `) abstain via a
  filesystem-existence seam; non-existing ones (`/compact`) stay commands.
- **A mid-dictation reconnect resumes the session; it never replays it.**
  When the realtime socket drops without the user asking
  (`DictationSessionController+Reconnect.swift`, #380), the mic keeps recording and the
  socket is retried on a bounded backoff. Four things hold that apart from a
  session restart, and each is load-bearing:
  (1) the run dials the endpoint/key/model snapshot latched at session start
  (`sessionRealtimeConfiguration`), never a fresh read of Settings — a backend
  mode flipped mid-dictation would otherwise carry this session's audio, and
  its bearer token, to a server it never agreed to;
  (2) it sends no commit, at any point — the reconnected backend holds no audio
  buffer to commit;
  (3) the partial in flight is promoted into the committed transcript at the
  drop, so the reconnected backend — which starts with an empty transcript of
  its own — can only produce text Live Auto-Paste has never typed. There are no
  backspaces in the insertion path, so anything typed twice stays typed twice;
  (4) every resume point re-checks `reconnectRunID`, which every stop, cancel
  and abort bumps. A socket that opens a moment after the user stopped finds a
  run that no longer owns the session and changes nothing.
  The audio spoken into the gap is kept, not dropped: the run cancels the
  send loop so the chunks pile up in `AudioChunkBuffer` and the restarted loop
  replays them. That buffer's retention cap is sized above
  `RealtimeReconnectPolicy.worstCaseDuration`, so a run that reconnects within
  its retry cap loses nothing — past the cap the OLDEST audio goes first.
  What IS lost either way is audio that was already sent when the socket died
  but whose transcript never came back, and the words at the cut, which the new
  session hears mid-utterance.
- **Every realtime event names the socket that raised it, and the session
  refuses every other one.** `RealtimeEvent` still says only what happened, so
  the identity rides beside it: `connect()` stamps a
  `RealtimeConnectionGeneration` on the socket it opens, `emit(_:from:)`
  carries it in the same call as the event (a parallel channel could be dropped
  or reordered; the main-queue FIFO only orders what it is handed together),
  and `DictationSessionController.handle(event:from:)` drops anything not stamped with
  the generation the session is on. That one comparison is the whole check —
  nothing downstream re-derives which socket it is hearing (#417). Three things
  make it hold:
  (1) the stamp is captured in `listenForMessages`, under the same lock as the
  `socketState == .connected && webSocketTask === task` admission check, and
  threaded down to every emit the frame produces. Re-reading it at emit time
  would defeat the point: the whole failure is a frame admitted by a socket that
  is closed and replaced before the emit runs, which would then come out wearing
  the LIVE socket's name;
  (2) generations come from one process-wide counter, so the idle client's
  retired socket cannot answer to the live client's name after a mode switch;
  (3) the session is on `.none` whenever it holds no socket — before a dial,
  from a `.disconnected` until the reconnect's next `connect()`, and after a
  cancel. That window is what refuses a straggler emitted before the
  generation has moved on;
  (4) stamping the events is only HALF the job, and the half a reviewer had to
  find (Codex review of #448). A frame handler also mutates handshake and
  finalization state, under a different lock acquisition from the one that
  admitted the frame — so every such mutation re-checks the frame's generation
  through `isCurrentConnectionLocked`, inside the lock that makes it. Applied
  to the socket that REPLACED it, a stale `session.created` marks the new
  socket handshaked and drains its pending queue onto the wire ahead of its own
  `session.update`, and a stale `transcription.done` clears a commit gate the
  new socket is still waiting on. Neither shows up as a wrong event, so the
  view model's check cannot see either. `RealtimeAPIWebSocketClient`'s
  session-ready timer carries the same re-check: cancelling a
  `DispatchSourceTimer` does not unqueue a handler already on its way.
  This replaced three guards that stood in for the missing identity (Codex
  review of #415): the `.disconnected` ignored when
  `activeRealtimeClient.isConnected`, and the wholesale refusal of transcript
  events while a reconnect run is in flight. What did NOT go is
  `cancelRealtimeReconnect()` closing the socket its attempt opened: the stamp
  refuses everything that socket SAYS, but a WebSocket left in `connecting`
  still transmits the audio the stop flushed into its pending queue, and only
  closing it stops that.
- **Live Auto-Paste holds back the tail of the transcript.** Replacements are
  applied before typing (nothing is ever un-typed — there are no backspaces in
  the insertion path, and terminals can't support them: field bug 2026-07-06),
  so `LiveHoldBackReplacementStream` withholds the trailing partial word plus
  any suffix that is still a live prefix of a dictionary rule. Nothing is lost
  (`flushRemainder()` releases it at stop) but it costs latency of appearance.
- **The spoken send trigger withholds whole segments in Live Auto-Paste.**
  "send it" / "send now" at the end of a segment must be cut before it is
  typed, and nothing typed can be taken back, so with the opt-in on in an
  app where Return submits NO partial is typed: each segment is typed at its final (or at the
  promotion a stop or dropped socket does), then Return is pressed. That is
  the owner's accepted cost (2026-09-24), shown next to the toggle. The
  Return is pressed only in the PID the session pinned, only while that PID
  is frontmost (it never activates an app for a Return), never under Secure
  Keyboard Entry, and only once the hold-back stream has released every
  word — a Return ahead of the last word would submit half a prompt. Every
  Live decision is taken when it is needed, from the app frontmost THEN
  (by bundle ID only, on `ReturnSubmitsAppList`: every terminal plus Claude
  Desktop, whose prompt box sends on Return but which is not a terminal,
  #660); nothing sampled at session start or connect
  time takes part, because focus can move in between (Codex round 2 on #494:
  a verdict from before the connect and a PID from audio start sent both
  text and Return to an editor). A segment is withheld only if an app on the
  list is frontmost at its first insertion. Live text goes to whatever has focus, so
  `TextInsertionService` records the frontmost PID at every live insertion;
  the Return goes to the frontmost app only when every one since the
  last Return SENT is that PID (an unreadable one, or one made under Secure
  Keyboard Entry, which swallows posted keys while reporting success, counts
  as elsewhere). The Return is decided before the segment is typed, and the
  trigger is cut only when it will be sent; otherwise the final is typed
  whole. The
  record is cleared only by a Return sent or a new session, never by a
  refusal: once text landed elsewhere, the trigger does nothing for the rest
  of that dictation. Only a non-empty backend final can trigger; an empty
  final or a promotion types the merged text as text. The accumulator's
  merge is never parsed: it keeps partial words the final dropped and glues
  a disagreeing partial onto it, and either can read as a trigger the final
  does not hold.
  `SendNowResubmitLatch` refuses a submission equal to the previous one until
  a non-submitting final comes between: no backend names its segments, and
  partials cannot tell a repeat from a straggler, so "send it" twice in a row
  presses Return once. In Overlay Buffer the trigger is cut from the raw
  transcript before the dictionary and the polisher; the target qualifies
  only by its own bundle ID on `ReturnSubmitsAppList` (the AX probe reads the
  element focused NOW, which need not be the commit target's), and the Return
  follows only a commit that reported `.succeeded`.
- **"Go to <name>" is a command only when the name resolves** (#723 step
  1). An Overlay Buffer dictation that is only "go to" plus at most four
  words is looked up against the live registry's default names (the git
  root's directory name first, then the main checkout's) before the spoken
  send cut, the dictionary and the polisher. No match: it is ordinary text
  and commits as dictated, because "go to the tests" is a prompt too. A
  match: nothing is inserted, no Return is pressed, and nothing is saved to
  History. Two panes on one name is ambiguous and does nothing; sessions on
  one local tty count as one pane. The pane is found by the tty the hooks
  reported, asked only of Ghostty, iTerm2 and Terminal.app while they run
  (`tell application id` would launch one that is not), and the tty is
  spliced into AppleScript only when it is `/dev/tty` plus letters and
  digits. The result is read back with the join's focused-pane reader:
  `.focused` only when that tty is the session's. A Return after a focus
  (#723 step 3) or #717's answer hotkey must require `.focused`, never
  `.unverified`. Live Auto-Paste has no go-to: its words are typed before the
  phrase ends.
- **The Mistral second pass holds the text back, never the world** (#317).
  An Overlay Buffer dictation in Mistral API mode is sent whole to the batch
  endpoint on stop (`DictationSessionController+StopCommit.swift`,
  `StopSecondPass`), and the commit waits up to the deadline for it. What
  the polish is grounded in is sampled at the stop itself, before that wait
  (`OverlayStopSample`): the screen re-read compares against the start
  capture, and seconds of agent output scrolling past would drop it as
  mutated. The target, the record's fields and the join go with it. Only
  what depends on the text runs after: the spoken send cut, the dictionary,
  the payload macro and the polish. The macro's clipboard read therefore
  comes up to the deadline after the grounding read, so a copy made in that
  window reaches one and not the other; accepted, since nobody copies while
  waiting on their own dictation. Three more rules hold it:
  (1) the pass dials the key and host the realtime socket latched at start,
  never a fresh read of Settings;
  (2) the audio lives in memory for the pass, and reaches the disk only
  through the audio-store latch taken at start (`sessionStoresAudio`);
  (3) the batch text replaces the realtime text whole when it answers in
  time, and is never merged with it: the two segment and punctuate
  differently, and a merge would repeat or drop words at every seam. A blank answer, a failure or a missed
  deadline keeps the realtime text and is only logged.
  The term list leaves the Mac. The user's own words go to any endpoint, as
  they do in the polish prompt. Everything else comes from screen, session
  and repository context, so it goes only with the trusted-endpoint opt-in,
  and each source also passes the gate it passes for the polish (#647):
  learned terms, the project's agent proposals (repo vocabulary on), the
  joined session's text (live join, session context on) and the start
  screen the stop sample reconciled. They are read from what the stop
  holds; the repository pipeline is not run for the pass, since it can take
  3 s and nominates only what the realtime text nearly spells. The project
  (its proposals, and its confirmed terms first) needs the git root for an
  unjoined terminal or a session in a worktree (#705): the pass resolves it
  the way the pipeline does, without the index, under its own single-flight
  gate so the polish never skips its vocabulary, and sends without the
  project after 250 ms. The screen
  goes last against the 100-term cap: a listed term nobody says is
  sometimes written anyway. A new dictation that cancels
  the pass saves the realtime text as not inserted, as it does for a polish.
- **Claude Desktop is a text field whose Return sends, and gets its
  newlines as Shift+Return** (#660). Three lists name it, each for one
  capability: `TerminalTargetDetector`'s text-field list fixes its verdict
  (the AX probe cannot: Electron builds its tree only once the join read has
  set `AXManualAccessibility`, after the verdict, so the first dictation after
  the app launched found nothing focused and read as a terminal);
  `ReturnSubmitsAppList` lets the spoken send trigger press Return there; and
  `TextInsertionService`'s Shift+Return list changes how a newline is typed.
  MEASURED on Claude Desktop 2.9939.2 (2026-09-26), posting exactly what
  `postUnicodeTextEvents` posts: a newline never submitted, but one opening
  an event or making up a whole event was dropped (`alpha` + `\n` + `beta`
  landed as `alphabeta`), and a fenced block sent as consecutive 20-unit
  events came out with pieces reordered. So in Desktop each line is typed on
  its own and each newline is pressed as Shift+Return, which the prompt
  handles as a key; the same probe then posted exactly that sequence back to
  back and the text arrived in order. A text holding a code fence line is
  the exception (#695): typed key by key, a line that opens with a fence
  triggers Desktop's markdown shortcut and opens a code block that also takes
  the text after the closing fence, so that text is pasted whole with Cmd+V
  (`MarkdownCodeFence`), and typed as above only if the paste fails. The
  list is judged from the app frontmost when the keys
  are posted, after the insertion made its target frontmost. Listing Desktop
  under Settings → Terminals overrides the verdict (the user list wins), and
  a terminal session collapses its newlines before any reach the keyboard.
- **The overlay panel's click-through is insertion machinery, not window
  chrome.** `NonActivatingPanel` refuses key and main and swallows every click
  on its body, because the panel is on screen exactly while the app it is
  about to insert into must keep focus. @joostliebregts's fork made the whole
  panel draggable and lost the Overlay Buffer's auto-paste — to AppKit's
  window-drag machinery, which moves a window by making the click belong to
  it. What is load-bearing is therefore HOW the panel moves, not where the
  user grabs it: `OverlayDragRegionView` sets the frame itself and swallows
  the event, with no `performDrag(with:)`, no `isMovableByWindowBackground`
  and no path that lets a mouse event reach the window. Reaching for either of
  those to simplify the drag is the fork's change. The region covers the whole
  panel (owner ruling, 2026-09-21, after hand-testing that a dragged overlay
  still auto-pastes) and hands the scroll wheel back to the transcript by
  re-running the hit test with itself hidden.
- **A remembered overlay position is re-validated against the live displays,
  never trusted.** `OverlayManualPlacement` stores the panel's top-left as an
  offset inside ONE display's own frame, identified by its ColorSync UUID —
  not a global point, and not the display number, which macOS reassigns per
  session. On every use `OverlayManualPlacementResolver` requires that display
  to still be attached (gone: the overlay falls back to the anchored position
  and the stored point is KEPT, so replugging restores it) and clamps the
  panel back inside its visible frame. Dragging runs through the same clamp as
  restoring, so a position can never be dropped where the next session would
  have to rescue it. The failure this exists for is silent and unrecoverable
  by the user: an overlay restored onto a monitor that is no longer there has
  no handle to drag it back with.

- **LLM polishing trusts the model's text in both profiles.** Human dictation
  evaluation found that `PolishTokenGuard` could reduce fidelity by undoing
  useful formatting and reconstructed identifiers, so it is not in the commit
  path. Repo/clipboard vocabulary is an INPUT-side exception: a transcript
  span that NORMALIZES TO A LOCAL TERM ITSELF ("use auth dot ts" ->
  `useAuth.ts`) is boundary-checked and pre-applied before the single polish
  call; a LONE word may change letter case and nothing else (French "Sans"
  equals the flag `--sans` once dashes are ignored). Nothing weaker rewrites
  the transcript. The sound-alike tiers (edit
  distance one, Double Metaphone key, bounded aligned fallback) only NOMINATE:
  their terms reach the model as a plain list (four, growing with the length
  of the dictation up to twelve), with no heard
  span beside them, and a file name whose extension the speaker never said is
  withheld altogether. Owner field history 2026-09-18: those tiers, applied
  silently or shown as `"heard" -> "term"` pairs, wrote `toolInput`,
  `SessionStart`, `--sans` and `localvoxtral.js` over ordinary French and
  English prose; on replay the pair rendering produced five wrong insertions
  on Mistral Medium where the list produced three and no section none, and
  every survivor on GLM 5.3 was an unspoken extension. Do not restore
  pre-application or the pair rendering without replaying that set
  (`SoundAlikeNominationTests` pins the field spans). This is grounding,
  not an output guard. No content-based leak detector scans or rejects model
  output. Only explicit clipboard-paste payload-placeholder count integrity
  remains active for both profiles. The token guard type remains as a recognizer
  used by clipboard vocabulary and by focused unit coverage; do not infer that
  it runs at commit.

- **Learned terms leave the Mac whatever the context toggles say now.**
  A spelling the cross-source merge pre-applied is recorded per project
  (`LearnedTerms`, `LearnedTermProjectResolver` — the project key is the
  main checkout of the git root the vocabulary pipeline already resolved off
  the main actor, widened to contain a joined session's directory; a linked
  worktree is not a project of its own (#652), and its main checkout is read
  from its `.git` file in that same pipeline (`RepoIndexing.mainCheckout`);
  the commit path never walks the filesystem for it, and it inherits that
  pipeline's title parsing, ssh titles included. A remote session's key is
  the basename of its repository's main checkout when its host's shim sends
  `X-Lvx-Env-Project`, else its cwd label, so two repositories with one
  basename on one host share a bucket: the price of never holding a remote
  path), and once three separate
  dictations have resolved it, it grounds later ones and rides in the prompt
  under its own header — with no endpoint check and no re-check of the
  setting that first produced it. Owner ruling, 2026-09-20: a name the
  speaker keeps saying is their vocabulary, exactly like a name typed into
  Names and terms, which has always been sent to whatever endpoint is
  configured. What the app owes in exchange is stated here rather than
  enforced by a gate: each term keeps the sources that proposed it, so a
  later setting can drop what one source taught; nothing below the
  three-dictation bar is ever sent unless the user pinned it or fixed it by
  hand, and an import (`LearnedTerms.merge`, #523) confirms nothing the
  file does not record as earned, taking the max of the counts, never the
  sum; a remembered term never outranks a live
  source (`.learned` is LAST in `PolishContextSource`, so a contested span
  abstains); unpinned terms decay at 90 days; and Text processing →
  Advanced → Terms learned from polishing → Forget drops the file (Show forgets one). Verification candidates are never
  recorded — they are questions put to the model, not answers. A dictation
  whose project cannot be established teaches nothing at all, which is not
  the same as one with no project: the latter teaches the shared bucket,
  and filing the former there would put one repo's spellings where every
  project-less dictation reads them. Known limit of the bar: it counts
  dictations, not independent evidence, so one stale clipboard read across
  three dictations is three confirmations.

- **A learned term does not rewrite ordinary words** (#522). The exact tier
  pre-applies any span that normalizes to a term, so a learned `useAuth`
  would turn "we should use auth tokens" into code. For the `.learned`
  source only, `RepoVocabularyMatcher.withholdingOrdinaryReadings` moves a
  two-word span of plain lowercase words with no code word next to it
  (`codeNounCues`, `codeVerbCues`) from the pre-applied entries to the
  verification pairs: the model sees the sentence and decides. Live sources
  are not guarded: a term on screen now is evidence this dictation is about
  it; memory is not. A withheld term is neither recorded nor counted as
  applied, which also stops a learned term confirming itself on prose.
  Single words (the exact tier only changes their case), spans of three
  words or more, acronyms and spans with a capital, digit or spoken
  separator are applied as before. `LearnedTermOverApplicationEvalTests`
  pins the numbers; its known misses are a three-word join said as prose
  ("push to talk") and identifiers said with no code word nearby.

- **An agent's proposals are vocabulary with a source, confirmed only by use
  or a pin** (#609). With the opt-in setting on, the first dictation that
  joins a LOCAL Claude Code, Vibe or opencode (#642) session in an unstamped
  project runs that
  agent headless in the project (`ProjectTermProposer`), after the commit
  inserted its text and off the commit path. The run is the app's own
  process, never the user's session, so it cannot interrupt a turn, and the
  hooks still print nothing. Its bounds are each a measured failure:
  `claude -p` gets Read/Glob/Grep only, `disableAllHooks` (a project's
  `SessionStart` hook fired inside `-p` without it; `--bare` would skip hooks
  but never reads a Claude.ai login), `--strict-mcp-config`, 12 turns, $0.50;
  `vibe -p` gets read-only file tools under `--auto-approve` (bash is refused
  even so), 12 turns, $0.30, `--experimental-harness` (legacy looped to the
  turn limit), and an app-owned `VIBE_HOME` holding only links to the user's
  `config.toml` and `.env` (Vibe has no flag to skip hooks, and under the
  user's home our `post_agent` hook would publish a phantom session);
  `opencode run` gets `--pure` (without it our plugin in the global plugin
  directory loads into the run), its own agent through
  `OPENCODE_CONFIG_CONTENT` that denies every tool but read/glob/grep/list
  (denied tools are not offered, even when the user's config allows them),
  12 steps, 4096 output tokens a step, `OPENCODE_DISABLE_PROJECT_CONFIG` (a
  repo's `opencode.json` could start MCP servers) and `OPENCODE_DB=:memory:`
  (the run stays out of the user's session list); opencode has no price cap,
  so the 120 s timeout is its budget. There is no remote opencode shim, so a
  remote opencode join is never asked. The
  working directory comes only from `localWorkspacePath` via the git root,
  so a remote label can never become one (a remote project is run on its
  host: "The Mac asks a host to spend", below). The
  answer is untrusted text repo contents can steer: only term-shaped strings
  are kept (`DictationTermsFile.accepted`, no control characters, 40 at most),
  terms already known or refused are dropped, and a proposal starts at zero
  dictations with source `agent:<name>`. Until three dictations or a pin
  confirm it, it matches only in the `.learned` exact tier, only where repo
  vocabulary may go (setting on, loopback or trusted endpoint), is never a
  sound-alike nomination or verification pair, is pre-applied but never
  listed under `[Learned vocabulary]` (which tells the model the speaker has
  used the spelling), and is not in `confirmedTerms`; it is evicted first
  and decays like any unpinned term.
  One stamp per project key (main checkout, #652), whichever agent answers
  first; a failure stamps only an attempt time and retries after 24 h.

- **A fix is learned only from the prompt the joined session submits** (#520).
  `CorrectionLearning` compares the text a commit inserted with the next
  `UserPromptSubmit` of the session the dictation JOINED, within 3 minutes,
  once. No screen, AX field or keystroke is read for it: the agent hands over
  the final prompt through the hook the join already trusts, so a fix is seen
  only when the user sends it, and only in a positively joined session.
  Screen reads were rejected as the source (comment on #520, 2026-09-24): a
  Ghostty or `pane.read` grid re-wraps the prompt inside TUI chrome, and the
  insertion path has no field read at all. Claude Code 2.1.280 hands a long
  paste to the hook wrapped in `<pasted_content id=…>` markers, which the
  classifier strips. The registry calls the observer outside its lock with
  the scoped session id; the inserted text and the prompt live in memory for
  one comparison, nothing but the spelling is written, and the log gets
  verdict categories only. `CorrectionDiffClassifier` favours precision: one
  substitution of at most 4 words, few other changed words, a spelling that
  sounds like what it replaced, and a capital that is not a sentence start, a
  digit or an inner joiner, unless the spelling is already a known term. A
  hand fix is confirmed at once (`confirmedByCorrection`), bypassing the
  three-dictation bar, because that bar guards against polish repeating
  itself and a hand fix is not polish. Undo, or a later fix that changes a
  learned spelling back, deletes the term outright rather than lowering its
  count. The feature inherits the join's gates: no polish endpoint, both
  context settings off, or an endpoint that is neither loopback nor trusted
  means no join and nothing learned. A prompt that arrives before its
  dictation's commit (Enter pressed as the last word appears) waits 10 s,
  no longer. A Live dictation is compared as the insertion service
  recorded it typing, and not at all when text is still pending or the
  spoken send trigger pressed Return: the user sent that unedited. Known
  limit (GLM review of #532): without polish the project key is the
  joined session's own directory, not the repository the vocabulary
  pipeline would widen it to, so a session in a subdirectory learns into
  a separate bucket; resolving the root would walk the filesystem on the
  commit path, which `LearnedTermProjectResolver` forbids. A hand fix in a
  worktree's root reaches the main checkout at the next launch: the store
  folds worktree keys into their main checkout each time it loads its file
  (`LearnedTerms.foldWorktreesIntoMainCheckouts`, max of counts, never the
  sum).

- **"About you" is the only place the model is told to infer a misheard name.**
  `LLMPromptTemplates.withSpeakerProfile` appends the user's own text to the
  SYSTEM prompt (stable, so it stays inside the prefix polishd checkpoints —
  the warmup applies the same call). The same "sounds like it AND fits better"
  rule was tried in the bundled prompts with no profile present and made both
  GLM 5.3 and Mistral Medium guess ("Coin 3.6" -> Claude, -> Code; "H200" ->
  H100); with the profile the same dictations came back as Qwen. Keep the rule
  attached to evidence the user supplied.

- **The terms list stores correct spellings only, and a plain capitalized word
  never becomes a rule.** `SpeakerTerms.replacementEntries` derives a
  case/spacing rule from a term only when it has a space, a non-letter or
  mixed case ("Claude Code", "useAuth.ts", "vLLM"). "Work", "Vibe" or the
  acronym "IT" would otherwise rewrite the ordinary word in every sentence, in Live Auto-Paste
  too, where no model can tell the product from the noun; those terms reach
  the About-you block of the prompt only. File-dictionary rules sort first, so
  a hand-written rule wins a tie. The polisher never sees
  `replacement_dictionary.toml` (owner ruling 2026-09-18) — only the terms;
  the `{{replacement_dictionary}}` slot survives because the vocabulary
  sections ride in it. The About-you text and terms are user-typed
  and go to ANY polishing endpoint, like the replacement dictionary.

- **Suggested terms: the model judges what a name is; the app guarantees the
  rest.** No capitalization or dictionary heuristic decides name-vs-word
  (owner ruling 2026-09-18: German capitalizes every noun). The app's own
  guarantees hold whatever the model returns: nothing is added without a
  click, and `SpeakerTermSuggestions.filtered` drops anything already a term
  or ever dismissed, compared by a key that ignores case, spacing and
  punctuation. `ranked` only REORDERS, by counting in how many dictations a
  candidate literally occurs — it must never drop, because a spelling the
  model recovered from misrecognitions ("Qwen" from Coin/Kuen) occurs in no
  text. Measured on the owner's history: GLM 5.3 returns a clean list; Mistral
  Medium lists everything it saw, which the ranking makes usable. The request
  is user-initiated and the row names the model the dictations go to; it may
  include dictations made while a different endpoint was configured.
  On a hosted model the request asks for `reasoning_effort: "high"` while a
  polish keeps the model's lowest level: at polish effort Mistral Medium
  returned ~70 items including "Coin 3.6" and "Kuen"; at high it returned 11
  clean terms with "Qwen" recovered (170 s; GLM 5.3: 69 s — hence the 420 s
  timeout). `high` needs no per-model table: `/v1/models` reports only whether
  a model reasons, and `high` is the one level every reasoning model accepted
  (GLM low/high/max, Mistral none/high). Self-hosted shapes are untouched.
  The button is unavailable on the BUNDLED helper ("Needs a hosted polishing
  model."): measured on the owner's Mac 2026-09-19, the 4B took 177 s on 133
  dictations, listed the polish mistakes it was told to leave out (OpenShift,
  Cohere, `toolInput`, Coin, Kuen) and ended in a repetition loop, all while
  holding the helper's single generation slot against every polish; batches
  of ten returned nothing. On a hosted or external endpoint a run continues in
  the background while the user dictates. The request is ONE user message
  with no system message: an external server may be another polishd, which
  checkpoints every message but the last, and its two prompt-cache slots
  belong to the dictation profiles.

- **The app writes into an agent only through its routes.** Everywhere
  else the app reads from agents and types into whatever has focus; a route
  writes into an agent's own prompt, so every route is held to three rules,
  and each adds its own below:
  (1) *One route, resolved at start.* `SessionContextResolver.resolveAgentPromptRoute()`
  picks at most one route per dictation, next to the join, for the session
  the join resolved and nothing else. It is dropped with the join.
  (2) *Append and submit only* (`AgentPromptCall`). Widening a route (clear,
  commands, another session or pane) is a new capability and needs the
  owner's decision.
  (3) *Keystrokes are the fallback, not a race.* `AgentPromptSink` sends one
  call at a time, in order, and counts a call delivered only when the target
  confirmed it; the first failure (refused, timed out, unconfirmed) hands
  that call's text and every append queued behind it to the keyboard path,
  in order, for the rest of the dictation, and drops any queued submit: that
  text may have landed elsewhere. A route failure records a nil landing,
  which blocks a keyboard Return for the rest of the dictation, like text
  typed under Secure Keyboard Entry. A route that cannot tell whether a call
  landed, or whose target is not where keys would go, answers
  `keepInHistory` instead: the text is typed nowhere for the rest of the
  dictation, and the popover says it is in History. Typing it would put it
  in the wrong app, or in twice.
  - *opencode's prompt relay* (#719, `OpencodePromptRoute`).
    *Loopback only:* the wire carries a port and a token
    (`OpencodePromptRelayAddress`), never a host; `OpencodePromptRelayClient`
    dials `127.0.0.1` with no proxy, and a malformed port or token is dropped
    at decode.
    *Published by a verified peer:* the address rides only on an opencode
    `FocusChanged`, which the broker accepts only when the record's pid is
    the socket peer's, and the registry only when that pid owns the session.
    `ClaudeSessionRegistry.opencodePromptRelay(sessionID:)` answers only from
    a fresh declaration by the session's own pid, and two declarations naming
    different relays abstain. Declarations stay in memory, so the token never
    reaches the persisted registry file.
    *The relay's own limits:* the plugin implements `/tui/append-prompt` and
    `/tui/submit-prompt` and refuses everything else, any caller without the
    token, a `Host` other than its own address, and any call for a session
    the pane no longer displays. It forwards through the TUI's in-process
    client, so the app never needs or sees opencode's server password.
    *Resolution:* it reuses the join's session when the join resolved, and
    otherwise asks only the focused TTY
    (`ClaudeSessionJoinResolver.opencodePromptRelay(target:)`), never the
    herdr, ssh or cmux arms: those open sockets and tunnels on a context
    consent that writing does not have. The TTY question is asked only while
    some fresh declaration carries a relay, so a Mac without the updated
    plugin sends no Apple event for it. A pane in herdr joins through the
    relay only when the context join resolved it.
  - *herdr panes* (#726, `HerdrPanePromptRoute`; owner ruling on #723,
    2026-09-26). herdr's socket is unauthenticated full control of every
    pane, so what the app sends is bounded here, not by herdr.
    *Two calls, nothing else:* an append is `pane.send_text {pane_id, text}`
    and a submit is `pane.send_keys {pane_id, keys: ["enter"]}`
    (`HerdrPaneWriting`; wire shapes from herdr 0.9.0, the version installed
    when this was written). Never `pane.run`, never another key, never
    `agent.prompt`, `agent.send_keys`, `pane.send_input` or a focus call.
    *Only the joined pane:* the route exists only for a herdr pane join
    (local, remote or federated) and is keyed by the binding the arm captured
    (`ClaudeSessionJoinResolver.herdrPromptRoute(for:)`), so it writes to
    that pane id over the socket or `ssh -L` forward the join already
    trusted, and only while that dictation runs. It never asks herdr which
    pane to write to.
    *No control characters:* herdr writes `send_text` to the pane's input
    byte for byte, with no bracketed paste, so a newline would press Enter
    and an escape would start a key sequence. Text holding any Unicode
    control character (or over 32 KiB) is never sent.
    *Typed only into the same pane:* a text herdr refused (its own error
    answer for that request, or a request that never reached the socket) is
    typed only while keys would land in the joined pane: its terminal is
    frontmost and herdr's `pane.current` is that pane. Otherwise, and
    whenever the request went out with no valid answer (it may have landed),
    the text stays in History (`keepInHistory`).
    *Enter only over the joined agent:* before each Enter the route asks the
    pane's foreground processes again, with the test its arm joined on (the
    registered pid for a local pane, the parent pid or agent name for a
    remote one). A pane back at its shell gets no Enter: it would run the
    prompt as a command.
    *Resolution:* only after the context join resolved a herdr pane, and
    only when opencode's relay did not resolve, so an opencode pane with a
    relay keeps it.
- **Claude Code context reaches the prompt only through a positive join.**
  The joined session's repository (status, uncommitted diffs, contents
  of files the agent just touched) and its prior user prompt are attached as
  untrusted reference blocks, behind `claudeRepoContextEnabled` (default off)
  and loopback endpoints only. Invariants to keep:
  - Trust is transport-derived. The wire has no origin field, and
    `LocalWorkspacePath` has no public initializer, so "remote cwd reaches the
    filesystem" is a compile error — do not add one. Its only derivations
    (`ancestor`, `descendant`) preserve that, and `ClaudeRepoCollecting` takes
    it rather than a `String` for exactly this reason.
  - **The session registry persists join metadata, never captured content.**
    Its versioned Application Support file contains the session id, origin,
    agent, workspace reference, activity, local process metadata, remote
    environment labels, first-seen time, and last-activity time. It never
    contains a prior prompt, prompt timestamp, recent file, tool snippet, or
    focus declaration. The file belongs to the same user but carries no hook
    token or transport proof, so restore treats every row as untrusted input.
    It re-checks agent and remote-host namespacing, TTL, local pid liveness,
    the current boot identity for local pids, active non-revoked host
    enrollment for SSH origins, and the session caps. These checks prevent a
    same-user file edit, pid reuse after reboot, or revoked host from restoring
    a join candidate. Atomic 0600 writes live in a 0700 directory. Mutations
    submit snapshots to one serial latest-value writer, and explicit clearing
    removes the file.
  - The join is resolved ONCE per dictation, at start
    (`ClaudeSessionJoinResolver`), and every consumer — raw screen attachment,
    the session block, repo collection — shares that one answer. Three
    resolutions could each answer honestly about a different moment; that is
    how one session's screen ends up next to another's repo. Joins support
    four terminals (`TerminalScreenAllowlist`, owner decision 2026-07-22):
    Ghostty, iTerm2, Terminal.app, and cmux (whose arm is its own — see the
    cmux bullet). Resolution is
    TTY-first: the focused pane's controlling TTY, read per terminal over
    AppleScript (`AppleScriptTerminalTTYReader` — Ghostty ≥ 1.4's focused
    terminal, iTerm2's current session, Terminal.app's selected tab; sdef- or
    docs-confirmed, any error abstains) matched exactly against the
    hook-reported session TTY, LOCAL sessions only. A TTY non-answer does not
    fall through to a weaker reading of the same surface; the arms after it
    (herdr pane, remote herdr, cmux surface, browser tab) each ask a DIFFERENT
    question, and when none answers, the dictation gets no join.
  - **NO JOIN EVER READS A WINDOW TITLE** (owner decision 2026-09-05). Until
    then the broker allocated an `lvx-…` marker per session, returned it in
    the hook reply, and Claude Code wrote it into the window title over OSC 2;
    a PID-pinned `AXTitle` read joined on it. All of it is gone — the marker,
    the reply field, the `terminalSequence` the local and remote hooks
    printed, the opt-in "Local Claude title fallback" setting, and the
    title-arm suppression rules that had accreted around it. The reason is one
    sentence: a window title is a channel every party in the stack rewrites at
    will — Claude Code its conversation titles (which clobbered the marker
    mid-turn, field finding 2026-07-17), herdr and cmux their pane titles, the
    user their own — so a marker sitting in one is evidence about the past,
    not about what the surface displays now, and every arm it fell through
    from had already refused for a reason.
    That was MEASURED on the owner's setup before this removal shipped
    (2026-09-05): polling a herdr pane's captured `terminal_title` at ~325 Hz
    for 69.4 s across a hook event, the broker marker was the title for 0.88 s
    in total — **1.26 % of the window**. The other 98.74 % it was Claude
    Code's own conversation title. The numbers and what they cost the remote
    arm are in the remote-herdr bullet below. `TerminalScreenAXReader` retains
    only `focusedWindowIdentity`, which reads no title: it exists so the
    authorizer can pair a screen capture with the join that authorized it.
    Precision matters in that sentence: no JOIN reads a title. One title read
    survives elsewhere in the app and is deliberately untouched —
    `TerminalWorkingDirectoryResolver.windowTitle(forApplicationPID:)` mines
    the commit target's title for a git root, behind `repoVocabularyEnabled`,
    to extract local vocabulary. It selects no session, authorizes no capture,
    and reaches no `ClaudeSessionJoin`; a wrong answer there costs a few
    unhelpful vocabulary terms rather than another session's repository.
    The one session shape the title marker uniquely served — a PLAIN ssh remote
    session, Claude Code in `ssh host` with no herdr, no cmux, no Remote
    Control — went armless for the length of one PR and is served again by the
    CONNECTION arm below. Nothing else ever lost an arm: a remote session also
    joins through `cmux ssh`'s round-tripped surface id, the remote-herdr pane
    arm, or the bridge-allocated Remote Control session id.
    A remote TTY names another machine's device, and `resolve(tty:)` refuses
    remote candidates so an SSH host can never claim a local pane by echoing
    its TTY.
  - herdr (the tmux-like agent multiplexer) is a first-class join target with
    its own arm. It was the first arm to be marker-free (owner decision
    2026-07-21, for the reason the whole mechanism was later removed for:
    herdr intercepts OSC 2 per pane, so a title marker could neither reach
    Ghostty's title nor describe an inner pane). The arm runs
    only after the surface TTY positively binds to herdr (a `herdr` client
    process on the focused terminal surface's TTY, `HerdrClientTTYProbe` —
    herdr's socket has no client introspection, so the process table is the
    only binding; the probe needs only the surface TTY string, so the herdr
    arm works on all three supported terminals), and from that point the join
    is herdr-or-nothing: a surface showing an inner pane is a surface no other
    arm can describe.
    The same property binds anything OUTSIDE the app that tries to identify a
    herdr-hosted window by its title: the UI gate's `term open` did exactly
    that and could never see the window it opened (field failure 2026-08-30),
    so it now identifies a window by a CGWindowID diff taken before the window
    exists (`scripts/mac/localvoxtral-ui-gate.sh`).
    The hook publishes `HERDR_PANE_ID`/`HERDR_SOCKET_PATH` from the pane env;
    `HerdrSocketClient` (hand-written and capability-bounded — reads are only
    `pane.current`, `pane.process_info`, and `pane.read`; its mutations are
    the remote panel probe's short-lived `lvmark` through
    `pane.report_metadata` and the herdr pane route's two writes, bounded in
    "The app writes into an agent only through its routes". herdr was AGPL when this
    was written and is Apache-2.0 since v0.8.0, repo `herdrdev/herdr`, so its
    docs and source are freely readable; the client stays hand-written anyway,
    because a vendored dependency would be a second implementation of the trust
    rules) asks that one socket for the focused pane and the join is exact
    pane-id equality (`resolve(herdrPaneID:)`, local sessions only), guarded
    by two fail-closed cross-checks: herdr's own `agent_session` claim must
    not disagree, and the registered Claude pid must be in the pane's
    foreground process list (catches a suspended Claude with the user at the
    shell). Two live herdr sessions (distinct sockets) abstain — there is no
    way to tell which one the surface displays. A herdr join never authorizes
    raw screen attachment of the AX capture: that is the composite herdr TUI,
    and neighboring panes must not ride into this session's prompt. Instead,
    a herdr join's screen context is a clean `pane.read` excerpt of EXACTLY
    the joined pane (`SocketPaneScreenContext`, shared with cmux), fetched at
    start and stop
    behind the same consent gate and sanitize/cap pipeline as an AX read;
    `pane.read` fires only after a herdr join (local or remote) resolved, and
    only ever for THAT join's pane — the request is keyed by the binding the
    arm captured at resolution, so no other pane and no other mechanism can
    reach a herdr socket through it. On any pane.read failure the session falls
    back to the pre-existing behavior — composite AX text, vocabulary-only,
    nothing attached.
    A herdr 0.9 client can federate several machines (`herdr machine add`), and
    while a remote machine is selected the local server keeps a focused pane it
    has merely stopped presenting. `pane.current` would then name a pane nobody
    is looking at, and every cross-check above would pass on it, so the failure
    would be a WRONG join rather than an abstention (issue #286). The arm
    therefore reads herdr's saved machine state FIRST
    (`HerdrMachineFederationReader` over `<state dir>/client/endpoints.json`
    and `client/endpoint-selection.json`, the two files `herdr machine list`
    itself reads). `.notFederated` and `.showingLocal` take the local arm
    exactly as before; `.unreadable` abstains because it is not knowing, not
    "no machines saved". With machines saved the local selection also requires
    a LONE herdr client surface
    (`HerdrClientTTYProbe.clientSurfaceCount`), because herdr keeps one
    selection per user rather than one per client, so a second client on screen
    makes the file unable to say which machine the FOCUSED surface shows. Users
    with no saved machines keep the pre-0.9 arm, second window included.
    `.showingMachine(profile)` no longer abstains: it dispatches to the
    federated `.federatedHerdrPane` arm (issue #288, Part B).
    That arm's confirmation set is: one herdr client surface; the profile
    target naming exactly one non-revoked enrolled host, by exact alias and
    then by `ssh -G` canonicalization (`ssh://user@host:port` machine targets
    included); live sessions on exactly one socket path with the shape of the
    profile's named herdr session (`HerdrSessionSocket`); over the app-managed
    forward, exactly one candidate claiming the focused pane, herdr's own
    `agent_session` claim not disagreeing, and the registered agent in the
    pane's foreground; and finally one panel stamp whose fresh token must
    appear in the focused grid. The token no longer names the machine: the
    selection state did. On a 0.9 client it proves the surface is a whole-view
    client federating that server—attach/observe surfaces render no sidebar.
    It does NOT prove the selection is fresh: a token stamped on machine B's
    pane renders while the user views machine A, so a selection file lagging
    the live client joins B, the #286 wrong-join shape. That lag is bounded by
    the lone-surface rule and herdr's own selection writes (herdr rewrites
    `endpoint-selection.json` on every switch, and `machine remove/disable`
    rewrite it too; a failed write is only a warning), and closing it needs an
    upstream herdr change (an active-endpoint report on the socket), not a
    stronger token. A match keeps the
    token as the mic indicator with the same forward/indicator lifecycle as
    the remote arm; a miss abstains under its own federated cause and points at
    the LOCAL panel-row config. Like every herdr join, it authorizes no raw AX
    capture and its screen context is a `pane.read` of exactly the joined pane.
    THREE RESIDUALS. First, herdr's state directory moves with
    `XDG_STATE_HOME`, which a GUI app cannot see in the user's shell, so such a
    user reads back "no machines saved" and keeps the unguarded behavior.
    Second, the files describe what a client STARTING NOW would show, so they
    lag a live client that has not caught up: a client polls the catalog once a
    second and returns to Local when the machine it displays is removed or
    disabled (herdr `src/client/catalog_reload.rs`), which bounds the window
    but does not close it. Third, multi-client ambiguity remains: one selection
    cannot name the focused surface when several herdr clients are visible, so
    that state abstains. None is closable with the file interface herdr
    offers. The real closure is herdr reporting its active endpoint on the
    socket, which is an upstream ask (issue #288).
  - cmux (github.com/manaflow-ai/cmux — a native Swift/AppKit terminal on
    libghostty) is a join target with its OWN arm, keyed on the surface id
    cmux injects into the session environment. It is opt-in
    (`cmuxSurfaceJoinEnabled`, default off) because the arm talks to ANOTHER
    app's automation socket, which the user must first switch to `password`
    mode with a password (cmux's default `cmuxOnly` mode does a peer-ancestry
    check we cannot pass — we are not a cmux child). The password lives in the
    Keychain (`CmuxSocketPasswordStore`); the socket is dialed by
    `CmuxSocketClient` (hand-written, read-only — cmux is GPL-3, never vendor
    its code), which asks `system.tree` for the focused surface (and its tty)
    and `surface.read_text` for that one surface's VIEWPORT (never
    `scrollback`, and never `lines` — in cmux that parameter implies
    scrollback). Auth is per CONNECTION, not per message: `auth.login` is the
    first line and the query follows on the same connection.
    **The password never leaves the process until the CONNECTED PEER is
    proved.** A same-UID path check cannot do that job — it is TOCTOU by
    construction, and any process running as the user can bind one of the
    candidate paths (the legacy `/tmp` ones especially), pass an owner check
    trivially, and harvest the credential. So the authoritative gate is
    `LOCAL_PEERPID` on the established connection: the peer must BE the
    frontmost cmux app's pid (the same target the join is about), and
    LaunchServices must still report that pid as the cmux bundle. A candidate
    that connects but fails this is dropped, not counted, so an impostor cannot
    manufacture ambiguity either. Deliberately not a code-signature check:
    `SecCode`'s signing identifier is not guaranteed to equal the bundle id, so
    requiring equality could kill the feature against a legitimately signed
    cmux, and the pid binding is the stronger claim anyway.
    Both origins join here: cmux's ssh relay puts the surface id into a
    `cmux ssh` shell's environment, so the id is ours travelling out and back
    (`resolveRemote(cmuxSurfaceID:)`). But a remembered label is NOT evidence
    that the session still holds the surface — a compromised enrolled host can
    replay an id from an earlier `cmux ssh` session after that surface returned
    to a local shell, and as sole remote candidate it would join, pairing
    attacker-chosen context with the user's current local screen. So a remote
    claim additionally requires FRESH evidence from cmux that the focused surface is currently
    remote-hosted. cmux exposes none of that on the surface (a `cmux ssh`
    surface is an ordinary `type: "terminal"`; remoteness lives on the
    WORKSPACE), so the client reads `workspace.remote.status` for the focused
    surface's workspace on the same connection and requires `enabled` AND
    `connected`; unknown fails closed. What remains unproved, and is stated in
    the code: with two enrolled hosts, a compromised one can still claim a
    surface hosted by the other.
    Local matches use `resolve(cmuxSurfaceID:)` (`process`-backed, local-only,
    like the herdr arm) plus a tty cross-check that is MANDATORY on both sides:
    absent tty evidence abstains rather than waiving the check, because a
    process that inherited a stale surface id and moved panes publishes no tty
    to contradict. The cost is stated where it is paid — an opencode session
    inside cmux never joins over this arm (its server half publishes no tty by
    design), so opencode inside cmux gets no join at all.
    Ambiguity on EITHER origin abstains: exactly one side may resolve, and the
    other must have no candidate at all. Rejecting only resolved/resolved made
    it asymmetric — two local claimants plus one remote used to join the
    remote, and the mirror case joined the local. `CMUX_WORKSPACE_ID` is never
    consulted (regenerated on restore), and `CMUX_SURFACE_ID` is itself
    session-scoped — cmux re-mints it on restore, which is safe here only
    because both sides of the match come from the same cmux run and stale
    UUIDs cannot collide. A cmux abstention used to fall through to the
    window-title marker arm — cmux forwards an inner OSC 2 to its window title
    — and since that arm was removed (2026-09-05) an abstention here is the
    dictation's answer. The title was never reliable anyway: a custom
    workspace name or cmux's AI auto-naming replaces it, which is why the
    surface arm exists.
    cmux exposes no AX text at all, so the join never authorizes raw AX
    attachment and its screen context is `surface.read_text` through the same
    `SocketPaneScreenContext` gate as herdr's `pane.read`.
  - A herdr running on an ENROLLED REMOTE host is its own arm
    (`.remoteHerdrPane`), tried only after every local arm declined, and it
    reaches that herdr over an app-managed, supervised `ssh -L`
    (`ClaudeRemoteHerdrForward`). An authenticated hook carrying a usable herdr
    socket label starts it off the dictation path; a successful cold join also
    retains it. Dictations lease the local socket, and the app keeps the process
    through a bounded injected-clock idle window so later dictations reuse the
    completed SSH/ProxyJump handshake. Its PRIMARY surface authorization is the
    herdr agents-panel binding, not ssh argv. For each plausible enrolled host
    (the readable ssh destination when available; when an ssh is PRESENT but
    unreadable, at most three enrolled hosts with live herdr-bearing
    sessions; a surface with NO ssh at all never probes — a local shell must
    not pay cold-forward latency or flash nonces in panels the user is not
    looking at), the resolver preserves the
    single-socket rule, opens the forward, reads `pane.current`, and identifies
    the unique live session claiming that pane. It then stamps that pane through
    `pane.report_metadata` with a fresh `lv-mic-…` nonce (more than 40 random
    bits, 8 s TTL) and requires that token in the focused terminal's
    existing visible-grid route within a bounded injected-clock settle window.
    Not the WHOLE token: herdr truncates an agents-panel row to the sidebar's
    column budget, which the user's own sidebar width decides, so the match is
    the longest rendered prefix with a FLOOR of 8 nonce digits
    (log2(36^8) ~= 41.4 bits — the "more than 40 bits" bound is what the floor
    exists to hold, and a shorter run is refused as `row-truncated`, never
    accepted as weaker evidence). Field measurement 2026-09-05 is why: at
    `sidebar_width = 20` the 17-column token rendered as `lv-mic-<8 digits>…`
    and an exact match could never succeed while the row was visibly there.
    A whole-view
    App client renders the agents sidebar; `terminal_attach` and
    `terminal_observe` render only the raw pane and cannot render this token.
    The nonce travels only over the owner/mode-checked forwarded socket and is
    unguessable inside its short lease, so remote-influenceable terminal text
    cannot manufacture the match without already observing that herdr server.
    Two hosts whose distinct nonces both appear abstain. A matched token stays
    alive as the dictation's visible mic indicator (refresh about every 4 s,
    TTL 8 s) and is explicitly cleared before its forward closes.
    EXTERNAL ASSUMPTION: herdr upgrades must re-verify BOTH that attach/observe
    clients still omit the sidebar (`src/server/headless.rs` render loop) and
    that all App clients still render one server-global panel/focus
    (`tests/multi_client.rs`). Per-client focus or a sidebar in attach mode
    invalidates this authorization argument. The first half is now MEASURED
    rather than assumed: the `integration-herdr` lane stamps a nonce through a
    real forward and asserts that a whole-view client renders it while a
    `terminal attach` client of the same pane does not
    (`HerdrIntegrationTests`, `docs/agent/test-tiers.md`). The server-global
    focus half remains unmeasured — see the panel-binding doc's "Pinned against
    a live server" section for exactly which assumptions are covered and which
    are still documented hopes.

    herdr 0.9.0 CHANGED WHAT A RENDERED TOKEN PROVES, so the whole-view
    sentence above is no longer the discriminator on a 0.9 client. That client
    composes the agents panel itself, from every federated machine at once
    (`src/client/shell/endpoint_agents.rs`), out of its OWN
    `[ui.sidebar.agents]` rows (`ClientShellConfig::from_config`), and marks the
    active machine by background color alone, which a text grid read cannot
    see. A token stamped on machine B's pane therefore renders while the user
    views machine A: the match proves that the surface federates that server,
    not that it displays it. This costs nothing for the argv-based arm,
    because that arm never probes a surface with no ssh and a federated client
    has none. The federated `.federatedHerdrPane` arm is the extension that
    names the machine from herdr's own selection state first (issue #286) and
    only then uses the token, which keeps its whole-view-prover and
    mic-indicator roles (it never proved freshness or display — see the
    federated arm paragraph above). The argv-based `.remoteHerdrPane` arm below
    is a behavior- and string-preserving refactor into `confirmRemoteHerdrPane`
    — no argv semantics changed — and still serves non-federated ssh surfaces.

    Any stamp refusal, unavailable grid, hidden/unconfigured/scrolled panel row,
    a row cut below the entropy floor, or a bounded settle timeout can only
    produce NO MATCH. It closes that attempt
    and falls through to the pre-existing argv authorization below; it never
    weakens the pane-level confirmations. The fallback first requires that the
    focused surface's own TTY host EXACTLY ONE FOREGROUND `ssh`
    session, whose destination identifies exactly one enrolled host. Exact
    alias matching wins without spawning anything; only when it finds no host,
    the app resolves the operand and each active enrolled alias through the
    user's effective `ssh -G` config and compares `(hostname, port)` — never
    `user`, which `ssh -G` always emits and which is always the local default
    on the operand side because the probe strips `user@` upstream; comparing
    it would reject an alias that sets `User`, the common build-host shape,
    while two same-box enrollments still land in the multiple-match
    abstention. Any refused operand, spawn/timeout
    failure, or unparseable output discards the whole fallback; two canonical
    matches remain ambiguous. Results are briefly TTL-cached because ssh config
    can change on disk. One,
    because several in a group cannot be told apart from here, and unioning
    them let a plain connection borrow a sibling's herdr signal. `SSHDestinationTTYProbe`
    is deliberately paranoid here, because every way an argv can name one host
    while the connection goes elsewhere is a mis-join — and since 2026-09-05
    it answers for the plain-ssh arm too, so a refusal here costs both: it
    verifies the EXECUTABLE against three EXACT absolute paths (`/usr/bin/ssh` and
    Homebrew's two `bin/ssh`, via `proc_pidpath` — not `p_comm`, not argv[0],
    and never by directory prefix, since `/opt/homebrew` and `/usr/local` are
    user-writable and a prefix rule trusted `/opt/homebrew/tmp/ssh`; a symlink
    target is accepted only when resolving a canonical path produces exactly
    it, its basename is `ssh`, and it stays inside that canonical path's own
    installation root — anyone who can repoint that symlink already controls
    what the user's own `ssh` runs, so this is defense-in-depth, not a
    privilege boundary), requires the
    process to be in its terminal's foreground process group (so a stopped ssh,
    a background one, or `scp`/`rsync`'s helper is not mistaken for the screen),
    and ABSTAINS on `-o`/`-F`/`-O`/`-S`/`-N`/`-f`/`-M`/`-D`/`-W`/`-w` rather
    than skipping them — `ssh -o HostName=other builder` must never answer
    `builder`. The exact, case-insensitive `SetEnv=` and `SendEnv=` `-o` keys
    are the only exception: they can neither move the destination nor change
    the session's interactivity, and accepting them keeps terminal wrappers
    such as Ghostty's from making every probe abstain. ssh MACHINERY is
    invisible to this count and to the uniqueness
    competing-view scan below: an ssh that is a direct CHILD of another scanned
    ssh — a ProxyJump's `ssh -W` hop, which OpenSSH spawns on the same tty in
    the same foreground process group (field abstention 2026-08-06) — is its
    root connection's transport, not a second connection. The partition rides
    kernel ppid, which no launcher gets to write, so it cannot hide a
    connection (the demoting parent is itself counted); sibling ssh processes
    in one group have no ssh parent and stay refused, and a shell-mediated
    ProxyCommand's grandchild stays a root and abstains — conservative on
    purpose. Probe abstentions carry a content-free cause category
    (`SSHProbeIndeterminacy` — never a host, path, or option letter) into the
    log and the dogfood record, because three field dictations were diagnosed
    blind without one;
    It then requires that ssh session to BE a plain whole-view herdr client — classified, not
    boolean (`HerdrInvocation`): the remote command's first argv token has
    basename `herdr` and the rest is empty or `--session <name>`. Every other
    herdr shape is REFUSED because it displays something other than the
    server-global focus the join reads: `herdr terminal attach <id>` renders
    ONE pane, and a `--session` we cannot normalize may be a DIFFERENT server
    (named sessions have separate sockets) — both were mis-joins reachable
    with a single connection while the signal was a boolean. AND no OTHER
    tty-holding ssh root on the machine may be a COMPETING herdr view of that
    destination (a `KERN_PROC_ALL` scan, including suspended ones on this same
    device): a client with a different session selector, a herdr subcommand
    shape, an argv that was refused and mentions `herdr` (substring,
    one-sided), or anything unreadable. What deliberately does NOT compete
    (2026-08-06, replacing blanket machine-wide uniqueness): ANOTHER USER's
    ssh (kernel `e_ucred.cr_uid`, never self-reported) — their herdr view
    lives in their own login session, not on a surface this user dictates
    into, and their metadata is never read; a cross-uid ssh ON the focused
    surface itself (`sudo ssh`) still abstains as an unreadable client rather
    than vanishing; a plain shell or
    non-herdr ssh to the same host — it is on another tty and the probe only
    reads the FOCUSED surface's tty — and a second whole-view client with a
    byte-identical selector, because herdr focus is SERVER-GLOBAL and
    multi-client attach is a mirror (verified in herdr source at v0.8.0 /
    protocol 19: `src/app/api/panes.rs::handle_pane_current` resolves the
    app's single active pane; `tests/multi_client.rs` proves frames broadcast
    to all clients), so both clients display the same focused pane and the
    join is correct for either. EXTERNAL ASSUMPTION: that focus model. If
    herdr ever grows per-client views, same-selector coexistence becomes a
    mis-join — re-verify `handle_pane_current` + the multi-client tests on
    herdr upgrades before trusting this paragraph. A SECOND external
    assumption rides with it: "byte-identical selector ⇒ same server" holds
    only while the remote side derives the socket from the selector alone —
    a shell with `HERDR_SOCKET_PATH` or a different `XDG_RUNTIME_DIR`
    exported can attach two bare `herdr` invocations to DIFFERENT servers,
    which this rule cannot see from the Mac (the argv is all it has). The
    residual is bounded downstream — candidates spanning two sockets abstain
    at the single-socket rule, and the pane-level confirmations still have to
    agree — but a candidate set living entirely on the OTHER
    server confirms against that server, so the honest statement is: env
    divergence on the remote defeats the selector comparison, and we accept
    that because the divergence is the user's own deliberate configuration.
    The argv signal is trustworthy here in a way the old comments undersold:
    it is the EXEC-TIME vector of a VERIFIED OpenSSH binary (kernel
    `KERN_PROCARGS2`), i.e. the command ssh actually ran, not a self-report —
    but it is still matched on the FIRST command token only (`ssh host sh -lc
    'printf herdr; exec claude'` mentions herdr and is not it), because what a
    shell wrapper goes on to run is not something any argv can promise. The
    invocation requirement exists because being the sole connection proves
    nothing about what the terminal DISPLAYS: a herdr whose client detached,
    or whose pane still runs an agent inside the registry TTL, keeps answering
    `pane.current`, so a plain `ssh builder` must never reach the join no
    matter how alone it is.
    The argv fallback remains necessary when the direct panel proof cannot
    render. Its historical limitation is:
    herdr exposes NO read-only attachment signal — re-verified at v0.8.0 /
    protocol 19 (2026-08-06), the only `client.*` methods are
    `window_title.set`/`clear`, both MUTATIONS (so `no_foreground_client` is not
    an acceptable probe), `session.snapshot` carries no client records, and
    the event stream has no client lifecycle events.
    The manual flow — `ssh host`, then typing `herdr` — now joins through the
    panel binding whenever the agents sidebar and configured token row are
    visible. Its residual is narrow/collapsed/covered sidebar or an unconfigured
    row: panel authorization fails closed, then argv still cannot identify the
    manually launched herdr, and there is nothing under it — the dictation gets
    no join. The plain-ssh arm does NOT rescue that flow and must not be made
    to: those sessions carry `HERDR_PANE_ID`, so they are refused there by the
    multiplexer rule (a herdr server keeps the FIRST connection's
    `$SSH_CONNECTION`, exactly as tmux does), and joining them on a connection
    would bind a pane's session to whichever window started the server. The whole "title-marker arm suppression" rule
    that used to live here (the exact `SSHProbeIndeterminacy` categories that
    did and did not suppress an outer title) is gone with the arm it protected;
    `SSHProbeIndeterminacy` remains as a content-free diagnostic category only.

    Both surface-authorization paths retain the remaining bounds: the host has
    live remote sessions reporting a herdr pane, all from ONE
    herdr socket (`liveRemoteHerdrSessions(hostID:)`, the mirror of the local
    single-socket rule). The count that matters is SOCKETS, not sessions:
    several live sessions on one herdr are expected and fine — panes are what a
    multiplexer is for, and serving that workflow is the point of this arm — so
    only two herdr SERVERS leave the surface ambiguous;
    over the forward, exactly ONE of those candidates claims that herdr's
    FOCUSED pane id (two candidates claiming the same pane id abstain);
    herdr's own `agent_session` claim for the pane does not disagree; and the
    pane is running that session's agent. Registry candidates existing on the
    host is NOT itself a binding for this connection — a detached herdr, or one
    whose sessions are merely still inside their TTL, keeps answering
    `pane.current` — which is why the surface authorization above (panel nonce,
    or argv classification) has to come first.

    **The pane confirmation used to have a fourth member. Losing it is the one
    place this removal costs security rather than only reach — but the field
    measurement below is why it had to go anyway. Read both halves before
    touching the arm.**

    MEASURED on the owner's setup, 2026-09-05, with the panel nonce matching
    and everything else healthy: the join ended at `remote-herdr: panel-bound
    pane marker confirmation failed`. Polling that pane's `terminal_title` at
    ~325 Hz for 69.4 s across a hook event, the broker marker was the title
    for **0.88 s total — 1.26 % of the window**; the rest of the time it was
    Claude Code's own conversation title (`✳ …`), which clobbers the OSC 2
    write. Restarting the same session with
    `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` left the marker standing and the
    join succeeded immediately. So the "fought-over channel" hazard this file
    documents for LOCAL titles applies to a herdr PANE title too — herdr
    captures whatever the inner program last wrote, and the inner program is
    the one rewriting it. The confirmation was not a second binding in
    practice; it was a ~1 % lottery that blocked the shipped feature for any
    user who had not exported that variable. Removing it is the fix, not a
    weakening of a working check. What follows is the honest accounting of
    what the check would have bought had it fired. herdr captures an inner pane's OSC 2 into
    `PaneInfo.terminal_title`, and the remote listener returned a
    broker-allocated marker to every remote session, so the marker was sitting
    in the joined pane's captured title where the arm could require it. Its
    value was that a pane id is a LABEL THE ENROLLED HOST CHOSE, while a marker
    is a value WE minted and handed to exactly one authenticated session: a
    compromised enrolled host could publish another session's `HERDR_PANE_ID`,
    but it could not make that pane's title carry its own marker.

    What a compromised enrolled host could do BEFORE: publish a pane id it does
    not own, and be refused at the marker check (unless it could also write
    that other session's marker into the pane title — which it could, since
    both sessions run on the host it controls and OSC 2 is just bytes on a pty.
    So the marker was never a boundary against a host that had ALREADY been
    compromised; it was a boundary against a host that was merely CONFUSED, and
    against a session lying about a pane it never occupied).
    AFTER: the same host publishes the same forged pane id and is refused by
    herdr's own `agent_session` claim when herdr has one, and by the pane's
    foreground process list when it does not.

    **Read the strength of those two carefully; they are not equal, and the
    second is weaker than it looks.** The `agent_session` claim is an answer
    from herdr — the party that actually watches the pane — and a forger cannot
    produce it. The foreground check is not: `remoteAgentIsForeground` is
    satisfied by EITHER the session's own published `hookParentPID` (the remote
    shim's `$PPID`, an `X-Lvx-Env-Hook-Parent-Pid` header the CLAIMANT wrote)
    appearing in herdr's list, OR any foreground process merely NAMED for the
    agent. So it asks "is an agent running in that pane", not "is THIS session
    running in that pane" — and both satisfiers are things a claimant on the
    host can arrange without occupying the pane: same-uid code can read the
    victim pane's foreground pid and publish it, and any pane running `claude`
    at all satisfies the name check.

    Which makes the residual wider than a forgery story, and it has an innocent
    form that matters more: an ordinary session carrying a STALE
    `HERDR_PANE_ID` — inherited by an exec, or left over after herdr moved
    panes — joins onto whichever session is actually in that pane, whenever
    herdr reports no `agent_session` for it and an agent is running there. And
    the lane measured that absence as the COMMON case
    (`remote-herdr-panel-binding.md`, "Pinned against a live server":
    `pane.current` did NOT carry `agent_session` for a pane whose agent session
    id had been reported through `herdr pane report-agent-session`). The marker
    was the check that told two sessions in one pane apart, and nothing
    replaces it; what bounds this now is that the candidate set is scoped to
    ONE enrolled host, that only ONE candidate may claim the focused pane id at
    all, and that enrollment is revocable. Do not build a new argument on the
    foreground check without re-reading this paragraph.
    The refusals that DO hold are pinned by
    `testASessionForgingAnotherPaneIDIsRefusedByHerdrsOwnClaim` and its
    foreground sibling; the residual above is deliberately not pinned by a test
    that would assert a mis-join is possible.

    What the panel nonce still proves, and it is the load-bearing half: that
    the FOCUSED LOCAL SURFACE — the window the user is looking at, read through
    our own AX capture — is displaying a whole-view client of the specific
    herdr server we just stamped, within an ~8 s TTL, with a token of more than
    40 random bits that travelled only over an owner- and mode-checked
    forwarded socket. That is a statement about THIS Mac's screen, which no
    remote host can forge and which the marker never made: the marker said
    "this pane belongs to this session", never "this window shows this
    server". Surface authorization and pane confirmation answer different
    questions, and removing the marker removed a second answer to the second
    question, not the first.
    The `agent_session` cross-check is fail-closed exactly like the
    local arm's and is what catches a REUSED pane (a session that died without
    a SessionEnd leaves a live entry and its pane id behind).
    The foreground check takes EITHER a `hookParentPID` (the shim's `$PPID`,
    compared as a STRING — a remote pid is another machine's number) or a
    process named for the agent; requiring both would fail closed forever on
    two ordinary installs (Claude Code spawns hooks through a shell, so `$PPID`
    is often that shell, and an npm install appears as `node`).
    The process is owned by the app-level `ClaudeRemoteHerdrForwardService`,
    never by the join value that travels: the commit path CONSUMES the join, so
    an owner reaching the child through `claudeSessionJoin` was nil at exactly
    the moments that mattered (quit during polish, an aborted connect) and the
    ssh outlived the app. `DictationViewModel` owns only leases, releasing every
    one on its existing session-exit paths; the service owns idle, revoke, quit,
    supervision, pid-ledger and next-launch orphan-reap lifecycles.
  - **The remote herdr forward is a trust inversion, and it is bounded by what
    we SEND, not by what the socket allows.** herdr's JSON socket is
    full-control: over that same forwarded stream one could create panes, write
    keystrokes into them, kill them. We dial OUT to it and send only
    `pane.current` / `pane.process_info` / `pane.read`, plus only the bounded
    `pane.report_metadata` `lvmark` lease described above, and that restraint —
    plus the one client in the codebase being hand-written — is the whole
    boundary. In exchange, `ClaudeRemoteSessionEnvironment.herdrSocketPath`
    stays what PR #216 made it: a label that is NEVER handed to `FileManager`,
    never `stat`ed, never dialed locally. Its one and only use is as an argv
    token for `ssh`, resolved on the host that named it, after re-validation
    (absolute, no `:` — that would re-split the `-L` spec — and PR #216's
    header charset). The argv deliberately omits two options an earlier design
    called for, both falsified against OpenSSH 10.0: `ClearAllForwardings=yes`
    clears command-line forwardings too and deletes the very `-L` (measured: no
    socket ever appears), and `ExitOnForwardFailure=yes` turns the enrolled
    host's own `RemoteForward` — normally already held by the user's live
    session — into a fatal error for this connection (measured: ssh exits).
    Readiness is a bounded connect-poll of the local socket instead, on an
    injected clock, with a ~2 s ceiling that is a dictation-start latency
    budget as much as a correctness one and is UNCHANGED for a cold dictation.
    Before reuse, BOTH the supervised process and a fresh connect to the local
    socket must be healthy; either failure tears the entry down and returns to
    that cold path. Activity-driven preparation does not block a dictation, so
    a slow ProxyJump may finish before the next one. The RESIDUAL of dropping
    the two options: this retained connection still requests whatever forwards the alias's own
    `Host` block declares, including the enrollment `RemoteForward` — since
    #217 that is this Mac's own port, so a collision with the user's live
    session is a warning on a stderr we send to `/dev/null`, not a failure.
    Three options ARE forced, because the alias's config would otherwise reach
    into this child: `ControlPath=none` (so the forward belongs to our own
    process and killing it IS the teardown; persistence amortizes the handshake
    without borrowing the user's master), `ForkAfterAuthentication=no` (a detached ssh is an orphan we
    can neither observe nor kill), and `PermitLocalCommand=no` (a dictation
    must not be able to trigger `LocalCommand` on this machine). Teardown
    signals the process GROUP — the child is spawned as its own group leader
    via `posix_spawn`'s `POSIX_SPAWN_SETPGROUP` — whose return value is
    CHECKED, since a silently failed one would leave the child in our own group
    and turn every teardown into an orphan — so `kill(-pgid)` can only ever
    reach our own ssh and its descendants — and it ends with an UNCONDITIONAL
    group SIGKILL. We observe only the leader, so its exit satisfies the
    bounded wait while a descendant that ignored SIGTERM is still holding the
    tunnel; gating that final kill on leader liveness (as the first version
    did) suppressed exactly the signal that clears it. The pairing rule that
    makes "unconditional" safe: the exit handler does NOT reap. A pid — and
    with it the pgid — is reserved only while the child is unreaped, so the
    zombie is what keeps `-pid` meaning OUR group; teardown signals first and
    reaps last, and once reaped NOTHING may signal that group again (a tunnel
    that exits by itself is finalized by the supervisor before restart, which
    is exactly when a reused pid could otherwise be someone else's). Cost: one
    zombie per supervised forward between leader exit and teardown — and that
    bound
    only holds because the reap COMMITS only on a definitive answer (the child
    collected, or `ECHILD`), retrying `EINTR` and leaving anything else
    unreaped for the next teardown. Claiming the reap before calling `waitpid`
    turned an interrupted collection into a permanent lie about a zombie that
    was still there, i.e. one leaked per restart without bound. The collect
    is also NON-BLOCKING first (`WNOHANG`, bounded poll, then handed to a
    background queue): every caller is a user-visible path — idle, health
    replacement, revoke, app quit, all on the main actor — and a child wedged in an
    uninterruptible wait must cost a background thread, never the UI.
    A remote herdr join authorizes no more than a local one: never the raw AX
    capture (that grid is the composite herdr TUI, on someone else's machine),
    and never local repo collection — the origin is remote, so
    `localWorkspacePath` is nil by type.
  - **The `--probe-surface` diagnostic verb runs the real resolver, so its
    read-only-ness is enforced by what it is HANDED, not by what it chooses to
    do.** A one-shot process is the worst possible owner for the two arms that
    write anything: an `ssh -L` it opens has no supervisor and no idle window,
    and a `pane.report_metadata` `lv-mic-…` stamp it leaves behind has nobody
    left to clear it if the process is killed between stamping and clearing. So
    `ClaudeSurfaceProbeCommand` passes `remoteHerdrForwards` and
    `herdrPanelMetadata` as `nil` — the resolver's own documented "this arm can
    never spawn anything" configuration — and the arm reaches `forward
    capability unavailable` and stops. There is no flag that re-enables them,
    which is the point: an opt-in would be a cleanup obligation, and this is the
    absence of the capability. The arm's read-only halves (the process-table
    ssh probe, enrolled-host matching including `ssh -G`, which resolves config
    and opens no connection) DO run, because they are what the field questions
    are about. Withheld for their own reasons and by the same construction:
    `cmuxSurfaces`/`cmuxJoinEnabled` (the arm reads a Keychain password — a
    diagnostic must not raise that prompt), `focusedBrowserTabURL` (a tab URL
    is a page the user is looking at), and `readFocusedGrid` (screen text; only
    the panel-nonce match ever needed it, and that match cannot happen here).
    One reader is wired only on request: `--desktop` probes the running Claude
    Desktop instead of the frontmost app and hands the resolver the Desktop
    arm's Accessibility read, which switches Electron's accessibility tree on
    and is therefore never a default.
    What the verb PRINTS is bounded by `ClaudeSessionJoinSummary`, the single
    mapper the dogfood record also uses: an arm name, the resolver's own
    content-free abstention categories, an origin CLASS, a terminal NAME, and
    two Bools — never a session id, pane id, socket path, host, nonce, or
    workspace path. The live registry is in the app, so the verb restores the
    copy the app saves (`ClaudeSessionFileStore`), through the app's own
    restore checks and a store that never writes: a restore that drops a row
    rewrites the file, and the file belongs to the app. It is only as fresh as
    the app's last save, and an empty one is the verb's first cause rather
    than letting the arms' resulting declines read as a surface failure.
  - Screen capture is split by ROUTE (`TerminalScreenAllowlist`): raw AX grid
    capture remains Ghostty-only (its single-`AXTextArea` grid is verified;
    iTerm2's AX tree is ambiguous across splits, Terminal.app's unverified).
    iTerm2/Terminal.app screen context comes ONLY from the AppleScript
    `contents` of the focused session/tab (`TerminalScreenAppleScriptReader`
    — visible screen, never `history`/scrollback; answered by the terminal
    process itself, same trust class as the TTY read, per-pane clean). cmux is
    the third route: its control socket, and nothing else — no AX (there is no
    text area), no Apple events (no scripting dictionary, so it is excluded
    from `appleEventBundleIDs` and from the Automation consent pre-warm). Every
    supported bundle has EXACTLY one route, asserted by test. All
    routes share one downstream pipeline (sanitization, caps, start/stop
    reconcile, vocab-always / raw-excerpt-only-after-authorized-join). A TTY
    join in iTerm2/Terminal.app authorizes attaching that focused pane's
    contents; herdr and cmux joins never attach AX surface text on any
    terminal.
  - **The local-tty echo arm (`.remoteLocalTTY`, 2026-09-06).** The tty arm,
    with the identifier taking one extra trip — and the arm that actually
    serves the configs people have. `resolve(tty:)` compares the focused
    pane's device against a device a LOCAL session's hooks read from `/dev`
    here; this compares it against a device name that came FROM here, carried
    into the remote session by ssh itself.

    The carrier is `$LC_LVX_TTY`: the user's own shell exports it, ssh's
    `SendEnv` sends it, sshd's stock `AcceptEnv LANG LC_*` accepts it, and
    libc ignores locale names it does not know — the mechanism iTerm2 ships
    `LC_TERMINAL` on. Tried BEFORE `.remoteSSHConnection`, because it is the
    one that works through the two things that defeat a TCP-level match, and
    both were MEASURED on a live OpenSSH pair (2026-09-06): the value arrives
    unchanged through a `ProxyCommand`/`-W` jump — where the connection
    binding has no chain it can follow at all, see the ProxyJump paragraph
    above — and two sessions multiplexed over ONE ControlMaster connection
    each receive their OWN value, because ssh carries environment per SESSION
    CHANNEL rather than per connection. The Mac-side setup is one rc line
    plus a `SendEnv` in the enrollment-written `Host` block (most ssh_configs
    already send `LC_*`; the line is what makes it true on the rest).

    Requirements: the focused surface's tty, read through the terminal's own
    scripting interface — never anything the remote host said; exactly one
    foreground ssh on that surface whose destination resolves to exactly one
    enrolled host (ProxyJump does not change the destination OPERAND, so a
    jumped connection resolves like any other); the candidate registered by a
    hook AUTHENTICATED FROM THAT HOST; the candidate a plain ssh shell
    (`$SSH_TTY`, and none of `multiplexerLabels` — a multiplexer server keeps
    the FIRST client's environment, so a pane's `$LC_LVX_TTY` names whichever
    window started the server, the same inheritance the connection arm
    refuses); its reported tty well-formed
    (`ClaudeRemoteLocalTTYPath.isAcceptable` — under `/dev`, no traversal,
    bounded) and EQUAL to the surface's; and exactly one live session claiming
    it. The surface ssh's SOCKET is deliberately not consulted — the socket is
    precisely what ProxyJump and ControlMaster take away.

    **Trust.** The value is chosen by the user's own shell on this Mac and
    carried by the SSH session itself; the remote host receives it rather than
    inventing it. A COMPROMISED enrolled host can of course claim any tty name
    — it can write whatever it likes into that header — but the origin-host
    check bounds it to windows whose ssh actually goes to IT, so it can only
    choose among its own windows. That is the same bound the window-title
    marker had, and the marker additionally depended on a channel Claude Code
    clobbered 98.7 % of the time; this one does not. What it does NOT prove is
    which PROGRAM is drawing in that window — same as every other arm — and it
    authorizes no screen read for that reason
    (`TerminalScreenClaudeJoinAuthorizer`).

    A stale local export is not a hazard worth guarding: a shell's controlling
    tty is fixed for its lifetime, so `LC_LVX_TTY` cannot go stale within the
    shell that set it. The one real footgun is the opposite direction — the
    same rc line running on the REMOTE host re-exports the REMOTE pts and
    hides the Mac's value — which is why the documented line only exports when
    `$SSH_TTY` is unset and the variable is not already set. Getting that
    wrong costs a non-join with a named cause (`no live session reports this
    terminal's tty`), never a mis-join.

    The setup step is IN THE APP. Its sheet names the rc file in one consent
    sentence and links to the exact text in the docs; no command or file
    contents render in Settings. It writes only on explicit consent, is
    idempotent by marker (`ClaudeShellRCSetup`), removable, and never silent. Three
    login shells get a block written for them — zsh, bash, fish — chosen by
    `dscl`'s `UserShell` with `$SHELL` as a FALLBACK only (a GUI launch
    inherits `$SHELL` from launchd, which is stale after a `chsh`); anything
    else is directed to the docs, because guessing at a shell's syntax is how a
    setup step corrupts a startup file. The writer REFUSES a symlinked rc file — the
    case a dotfiles user actually hits, since an atomic rename replaces the
    link with a regular file and silently detaches their repo. It preserves an
    existing file's mode and creates a new one at 0600. The `SendEnv` half
    rides the enrollment block, and reaches an ALREADY-enrolled host through
    the plugin-update path, which regenerates that block.

    The Settings row reports TWO facts because they fail for different reasons
    and only the user can fix the first: the block is in the rc file (read
    from disk), and a session has actually arrived carrying the value
    (`remoteLocalTTY` on a live remote session). A block written five seconds
    ago proves nothing until a NEW ssh session starts, and the second sentence
    is what says so.

    **What IS a hazard, and the reason rules 6 and 7 exist: the tty NAME is
    recycled and the registry entry is not.** macOS hands out pty minors
    first-free (XNU `bsd/kern/tty_ptmx.c`: `ptmx_clone` scans for the first
    free slot, `ptmx_free_ioctl` returns the minor on last close), so closing
    a window gives its `/dev/ttysNNN` to the next window opened — while a
    REMOTE session's registry entry survives for the full session TTL with no
    liveness check available (its pid is another machine's). Without a gate:
    close a Claude-over-ssh window, open a new one to the same host, dictate,
    and the dead session's repository and prior prompt attach to it. That is
    the cardinal failure, and it was found by review (2026-09-06) rather than
    in the field. The connection arm was immune by accident — a new window's
    ssh has a new ephemeral port.

    The gate is kernel truth on both sides: an ssh that STARTED after a
    session was first seen cannot be the ssh that session was created in, so
    the candidate must satisfy `firstSeen >= surfaceProcessStartTime`
    (`p_starttime`, from the same `KERN_PROC` scan). An unreadable start time
    refuses rather than skipping the check. Where the surface's ssh DOES hold
    sockets — the direct shape, where this arm and the connection arm overlap
    — the candidate's `$SSH_CONNECTION` must additionally match one of them; a
    pure negative check that makes this arm strictly stronger than the
    connection arm wherever both can run, and that has nothing to say in the
    ProxyJump/ControlMaster shapes this arm exists for. Which is exactly why
    the start-time gate is not optional.

    Residual, shared with the connection arm and unchanged by this: a session
    that DIED without a `SessionEnd` in a window whose ssh is still alive is
    still joinable until its TTL. And a terminal multiplexer that publishes no
    label the shim carries — `abduco` and `dtach` are the known ones — keeps
    the first client's environment exactly as tmux does, and neither arm can
    see it. `multiplexerLabels` covers what is on the wire; adding a
    multiplexer means adding its label.

  - **The plain-ssh arm (`.remoteSSHConnection`, 2026-09-05).** A Claude Code
    session in `ssh host` on an ENROLLED host, with no multiplexer and no
    browser, joins on the TCP CONNECTION its surface holds. sshd sets
    `$SSH_CONNECTION` in every session it spawns
    (`"<client-ip> <client-port> <server-ip> <server-port>"`); the remote shim
    publishes it as `X-Lvx-Env-Ssh-Connection`, with the four fields re-joined
    by COMMAS because space is outside the env-header charset and that charset
    is the whole header-injection defence — widening it for one field was
    refused. `ClaudeRemoteSSHConnectionReport.parse` validates the shape on
    arrival (exactly four fields, canonical decimal ports in 1…65535, addresses
    in `[0-9a-fA-F.:]` within 45 bytes) and trusts nothing beyond it.

    The confirmation set, ALL of it required: (1) the focused surface's tty
    hosts exactly one foreground ssh with a verified OpenSSH executable and an
    argv the parser accepts (`SSHDestinationTTYProbe`, unchanged); (2) that
    argv carries no `-J`; (3) its destination resolves to exactly one enrolled
    host (exact alias, then `ssh -G`); (4) no OTHER same-uid ssh to that
    destination is socketless (the ControlMaster mux-client shape — see the
    residuals); (5) the candidate was registered by a hook AUTHENTICATED FROM
    THAT HOST (`liveRemoteSessions(hostID:)` is scoped to its channel); (6) the
    candidate reports `$SSH_TTY` and NO multiplexer label
    (`ClaudeSessionJoinResolver.multiplexerLabels` — herdr, cmux, tmux, screen
    and zellij, walked over the wire allowlist so a label added there and
    forgotten here is a visible omission); (7) exactly one established TCP
    socket of that ssh PROCESS — read
    from this Mac's own kernel via `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`,
    same-uid, no privileges — has `localPort == client_port`,
    `peerPort == server_port` and a peer address equal to `server_ip`
    (compared as BYTES through `inet_pton`, since a dual-stack socket says
    `::ffff:a.b.c.d` where sshd says `a.b.c.d`); and (8) exactly one live
    session matches at all.

    **The trust argument, and what it does not cover.** The marker was a value
    we minted and handed back through a channel the remote host fully
    controlled and Claude Code clobbered — measured present 1.26 % of the time
    (above). This asks the remote host to name a 16-bit ephemeral port that
    only the two kernels on the ends of ONE connection know, for a connection
    whose local end this process reads out of its own kernel, and pins the
    answer to the host the hook authenticated from. A compromised enrolled host
    can still mis-describe its OWN connection — publish a second session under
    the ports of the connection the user is really looking at, and join that
    surface. It cannot claim a surface connected to a DIFFERENT host: it does
    not know that connection's client port, and the origin-host filter rejects
    it before the ports are ever compared. That is strictly more than the
    marker had, which was no boundary at all against a host that had already
    been compromised.

    UNPROVED, say it plainly: this proves which CONNECTION the focused surface
    holds, never what the remote program drew into it. A second Mac enrolled
    on the same host, dictating into its own ssh to that host, is a different
    connection with different ports and is not confused with this one — but two
    agents inside ONE ssh session share its `$SSH_CONNECTION` and are refused
    as ambiguous rather than told apart. Nothing here reads or authorizes a
    screen: `TerminalScreenClaudeJoinAuthorizer` refuses raw AX attachment for
    this mechanism (a plain ssh shell's grid is the user's whole remote
    session), `SocketPaneScreenContext` has no route for it, and a remote
    origin can never carry a `LocalWorkspacePath`. The join buys the session
    block and repo context — exactly what the marker join bought.

    RESIDUALS, none of them silent — every one has its own abstention cause:
    ProxyJump (see the next paragraph — it has three causes of its own); a host
    whose remote plugin predates 1.6.0 (it publishes no connection at all, and
    the cause names exactly that); and an unreadable fd table, which is
    UNREADABLE rather than "no sockets" —
    `SSHSurfaceConnection.sockets` is optional for that one reason.

    **ProxyJump cannot be supported by transport matching, and the reason is a
    property of unprivileged Unix rather than a gap in this code. Do not
    re-attempt the design below without reading this paragraph.**
    `ProxyJump` lives in `~/.ssh/config`, is invisible in argv, and OpenSSH
    carries it with an `ssh -W` CHILD: the surface's own ssh holds NO TCP
    socket, the child holds `mac:P1 -> J:22`, and the destination's sshd sees
    `J:P2`. Nothing on the Mac relates P1 to P2 — only the jump host J does,
    and the linkage lives in which of J's processes owns both sockets.
    MEASURED on a live Linux host, 2026-09-06: that linkage is unreachable to
    an unprivileged user. `sshd` drops to the user after auth, which makes the
    session process NON-DUMPABLE, so `/proc/<pid>/fd` is root-owned even for
    the user who owns the process (`ls /proc/<sshd-session pid>/fd` →
    `Permission denied` for 3 of 3 tried, with 6 such processes owned by that
    very user; independently replicated at 7 of 7 on OpenSSH 10.0p2 by an
    adversarial review), and `ss -tnpH state established` therefore attributes
    ZERO sshd sockets to a pid.

    The cgroup escape fails for a subtler reason than "cgroups do not work",
    and the distinction matters to anyone re-attempting this: `ss --cgroup`
    DOES attribute OUTBOUND sockets to a per-session scope
    (`/user.slice/user-N.slice/session-cNN.scope`), tty-less sshd sessions
    included. What cannot be tied to a session is the INBOUND half: an
    accepted socket carries the LISTENER's cgroup (`/init.scope`), and
    `loginctl show-session` exposes `RemoteHost` but no remote PORT — so
    `(mac, P1)`, the only handle the Mac has, reaches no session scope, and
    two windows from one Mac stay indistinguishable.

    One conditional escape exists and is deliberately not built on: on a host
    whose auth journal is user-readable, sshd logs the peer PORT together with
    the session pid (`sshd-session[NNN]: Disconnected from user dev
    192.168.1.101 port 43286`), and an auth-time `Accepted … port P1` line
    would tie `(mac, P1)` → pid → logind Leader → session scope → the
    outbound socket's local port. It is not a foundation for a trust
    boundary: journald readability and retention are per-host accidents, and
    on the very host where the review confirmed the disconnect-time lines the
    auth-time lines needed for a LIVE pairing were absent from a 496 MB,
    7-day journal.

    Without pid or cgroup linkage the only remaining rule is "J holds exactly
    one connection to the destination", which abstains for precisely the user
    who has several terminals open — the case this would exist to serve. It
    would also be sound only under conditions worth writing down before
    anyone reaches for it: scoped by UID (`/proc/net/tcp`'s uid column —
    inbound accepted sockets read uid 0, outbound read the session uid) and
    counted across EVERY address J may resolve the destination to, since a
    dual-stack or multi-A-record destination with one connection per address
    leaves each per-address count at one and lets the rule pick another
    terminal's socket. Single hop only, too: for a chain, the last hop's
    inventory is behind the same non-dumpable wall.
    So the arm NAMES the shape and declines: `ssh -G` (already cached for the
    enrolled-host fallback, and consulted ONLY on the branch that is about to
    abstain, so a joining dictation spawns nothing extra) yields
    `SSHProxyJumpShape`, and the causes are `this connection goes through a
    jump host (ProxyJump)` and `this connection goes through a chain of jump
    hosts`. The shape is a SHAPE and never the jump host's name — it reaches
    the log. `ssh -G` evaluates the user's `Match exec` blocks, so this can
    run a user-configured command, once per operand per TTL and bounded by the
    same 2 s timeout as the identity lookup — the price of asking ssh what ssh
    would do instead of reimplementing its config resolution. What would
    change the verdict: root (or a privileged helper) on the jump host, or a
    dependable auth journal there — both deployment decisions, and not
    something this app may assume.

    Two more, and both are MIS-joins rather than missed ones, which is why
    each has a positive check rather than a note:

    * **Multiplexers.** A multiplexer SERVER outlives the connection that
      started it and its panes keep that FIRST connection's `$SSH_CONNECTION`.
      MEASURED on the dev box 2026-09-05, tmux 3.x: connection A (client port
      36878) created the session, connection B (36886) attached, and a process
      inside the pane still read `SSH_CONNECTION=127.0.0.1 36878 …`, so a
      later attach would otherwise mis-join onto A's surface. The refusal is a
      property of the ARCHITECTURE, not of tmux: `screen` (`$STY`, screen(1)
      ENVIRONMENT) and `zellij` (`$ZELLIJ`) are servers in exactly the same
      shape. The first version of this arm checked herdr/cmux/tmux only and
      screen was not on the wire at all — a silent mis-join, found by review
      (2026-09-05) and closed by publishing both labels in plugin 1.6.0.
      Anything that multiplexes a terminal and does NOT publish a label the
      shim carries is still a hole; adding a multiplexer means adding its
      label, and `PlainSSHConnectionJoinTests` fails if the list and the wire
      disagree.
    * **OpenSSH ControlMaster.** `ControlMaster auto` in `~/.ssh/config` is
      invisible in argv (the probe refuses `-M`/`-S` but does not read
      config). Terminal A's ssh owns the TCP connection; terminal B's
      `ssh host` is a mux CLIENT over an AF_UNIX control path with no TCP
      socket. sshd derives `$SSH_CONNECTION` from the underlying CONNECTION,
      so B's Claude session truthfully reports A's ports — and a dictation
      into A, a plain shell with no agent in it, would join B's session. The
      check is `SSHSiblingSurvey`, carried on `SSHSurfaceConnection.siblings`:
      the other same-uid ssh CONNECTIONS to the same destination are counted
      by what the kernel could say about each, and any that is
      readable-and-socketless, or unreadable at all, abstains the arm. It
      costs the ordinary two-terminals-two-connections case nothing — those
      each hold a socket and are told apart by their ports. Found by review
      (2026-09-05).

      The survey is COUNTED rather than a boolean because the first field run
      of this arm (2026-09-06) abstained on it and the abstention could not
      say why: "a real ControlMaster client is open in another window" and
      "some ssh's fd table could not be read" are the same non-join and
      opposite fixes. They are now separate causes carrying `n of m`. ONE
      process is excluded from the survey and only one, so the abstention
      cannot be manufactured against the app itself: an ssh whose kernel
      PARENT is this app (its `RemoteForward` supervisor, its herdr `ssh -L`
      — ours, and never somebody's terminal).

      A second exclusion, for ssh processes with no controlling terminal, was
      added and REMOVED by review (2026-09-06) because it reopened the very
      mis-join the survey exists to block. `ssh -tt D claude -p …` launched by
      launchd, cron or an orchestrator has no LOCAL tty and a REMOTE pty, so
      the session it starts reports `$SSH_TTY`, carries no multiplexer label,
      and is a joinable candidate — under ControlMaster it is socketless and
      reports the master's `$SSH_CONNECTION`, so skipping it let a dictation
      into the master's window join it. The parent check already covered
      everything that exclusion was written for.

      The surface's OWN two refusals are named the same way and for the same
      reason: `this ssh holds no connection of its own (a ControlMaster client
      or a ProxyCommand)` is the readable-and-empty case — which the field
      also hit — and `this ssh's socket table is unreadable` means a syscall
      failed, which
      `SSHProcessSocketReaderCrossProcessTests` says should not happen for a
      same-user process. That test exists because the original reader tests
      only ever read `getpid()`: a reader that works on its own process alone
      passes all of them and then sees nothing for every real `ssh` on the
      machine. MEASURED on the build host 2026-09-06:
      `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`
      answer for a same-uid process this one did NOT spawn (`rc=792`,
      `kind=SOCKINFO_TCP`, `state=TSI_S_ESTABLISHED`), so the API is not the
      constraint and the app needs no entitlement for it.

  - A Claude Code "Remote Control" session (the agent runs on a machine of the
    user's, `claude.ai/code` in a browser is the UI) has no pane, no TTY, and no
    title, so it joins from the FOCUSED BROWSER TAB: the tab's
    `https://claude.ai/code/session_…` URL, read over AppleScript behind
    `FocusedBrowserTabURLReading` (Chrome, Brave, Safari —
    `BrowserTabAllowlist`, deliberately a SEPARATE list from
    `TerminalScreenAllowlist`; Firefox has no such AppleScript surface), parsed
    strictly (`ClaudeBridgeSessionURL`: https only, host exactly `claude.ai`,
    no userinfo/port, `session_[A-Za-z0-9_-]+` on the percent-ENCODED path) and
    matched by exact equality against the `CLAUDE_CODE_BRIDGE_SESSION_ID` the
    session's own hooks publish (Claude Code ≥ 2.1.199). This arm and the
    Claude Desktop arm below are the two that span local and remote sessions,
    because the id is bridge-allocated and
    globally unique — unlike a tty/pane id/pid, which another machine can mirror;
    `ClaudeSessionSnapshot.bridgeSessionID` still routes the read by origin.
    A `.browserTab` join authorizes NO screen capture of any kind (the
    authorizer's mechanism switch is exhaustive, so a new arm must decide), and
    carries no window identity because there is no capture to pair one with.
    Liveness RE-RESOLVES the bridge id at commit (not just "does my session
    still report it"): a second reporter arriving mid-dictation is the same
    ambiguity the start-time arm abstains on, and an enrolled remote host can
    publish any label it likes, so the joined session must still be the unique
    fresh reporter or the join is dead. Claude Code REMOVES the variable when
    the connection ends and the reducer replaces the reported metadata on the
    next non-focus record, so a disconnected session ages out on its own next
    hook rather than on a timer of ours — except for a record with no process
    block / no env header at all, which is not a retraction (#216) and holds the
    binding until TTL. The browser is asked ONLY under
    `claudeRepoContextEnabled` (the screen setting alone must not automate a
    browser), and each browser needs its own TCC Automation grant — pre-warmed
    by its own `TerminalAutomationConsentPrewarmSettingsObserver` under that
    same setting, since the consent sheet dies with the 1 s read that raised it.
  - A Claude Code session in **Claude Desktop's Code tab** (on this Mac, or on
    an ssh host the desktop app runs it on) joins from the FOCUSED WEB VIEW of
    the desktop app (`ClaudeDesktopAllowlist`, exactly
    `com.anthropic.claudefordesktop`, a third list disjoint from the terminal
    and browser ones). MEASURED on Claude Desktop 2.2553.1 (2026-09-18) and
    again on 2.9939.2 (2026-09-26): the session web view's `AXURL` is
    `https://claude.ai/epitaxy/local_<uuid>`, and the desktop app exports the
    same `local_<uuid>` as `CLAUDE_CODE_HOST_SESSION_ID` into the session's
    Claude Code process, so every hook carries it — local publisher field
    `desktop_session_id`, remote header `X-Lvx-Env-Desktop-Session-Id`
    (remote plugin ≥ 1.11.0). On 2.9939.2 the whole window is ONE such web
    area: the sidebar and every pane of a split view sit inside it, and its
    address always names the session in the pane classed
    `dframe-pane-primary`, whichever pane holds focus (after real clicks in
    either pane and after "Move split view left" alike); no attribute names
    the other pane's session. So `AXClaudeDesktopSessionURLReader` walks UP
    from the app's focused element to the NEAREST `AXWebArea` and reads its
    address ONLY when the walk passed an `epitaxy-chat-panel` element and
    then a first `dframe-pane` element that is also `dframe-pane-primary`
    (exact class tokens). A single-session window is one such primary pane;
    the rule assumes panes are siblings, never nested, which is what a
    desktop update must re-check. Focus in the secondary pane would
    otherwise join the primary pane's session; focus in a terminal, files or
    changes panel, or in the sidebar, is no join because the dictation is
    not going to a session. Each refusal logs its reason. `ClaudeDesktopSessionURL` parses
    the address through the same strict checks as the bridge URL
    (`ClaudeSessionPageURL`), path exactly `/epitaxy/local_[A-Za-z0-9_-]+`;
    the registry match is exact equality with one fresh reporter
    (`resolve(desktopSessionID:)`, shared rules with the bridge lookup).
    Everything else follows the browser arm: both origins join (the id is
    desktop-allocated and names the view the user is looking at), a
    `.desktopSession` join authorizes NO screen read and carries no window
    identity, commit-time liveness re-resolves the bound id (the id never disappears while the session runs, so it adds no
    disconnect signal of its own), and the read happens ONLY under
    `claudeRepoContextEnabled`. It is an Accessibility read, not an Apple
    event: no Automation consent, and nothing to pre-warm. It sets Electron's
    `AXManualAccessibility` on the desktop app before each read (Chromium
    builds its web accessibility tree only for a client that asks — the switch
    VoiceOver flips), and when the walk finds no web area at all it waits
    250 ms once and reads again, so the first dictation after the desktop app
    launches can still join. The address, the id and the three classes are
    UNDOCUMENTED: a desktop update that renames any of them stops the arm
    joining; only a new layout that keeps the classes but moves the address
    to another pane's session could make it join the wrong one, which is why
    a desktop update gets this measurement again. `--probe-surface` reads it
    only under `--desktop`.
    **A Desktop session must stay in the registry while its window is open,
    and exactly one process may report its id** (#657). Four things lost it,
    each measured on an ssh host with 18 Desktop sessions live at once, and
    each cost an abstention:
    (1) Freshness. Only hooks refresh activity, and the next hook of a
    session left idle is the UserPromptSubmit of the prompt being dictated,
    so past the 4 h TTL the first dictation back always missed. A record
    that reports a desktop id is fresh for `desktopSessionTTL` (7 days)
    instead. That cannot widen a join: the key names the view the user is
    looking at and matches only by exact equality. A local record still needs
    its pid alive, and a pidless local one keeps the 5-minute bound.
    (2) The cap. Once a second origin is present, each keeps
    `maxSessionsPerOrigin` (8) records without a desktop id and, counted
    apart, `maxDesktopSessionsPerOrigin` (24) records with one (#672), so a
    host's Desktop sessions never compete with its terminal ones. Over the
    global cap (`maxSessions`, 48) the origin holding the most records loses
    one: a desktop id is whatever an enrolled host sends, so it buys room only
    inside that host's own quota, and a flood of them evicts only the flooding
    host's records. Within an origin, eviction takes records without a desktop
    id first, least recently active within each group, and logs a count per
    quota. The record that triggered the eviction is never its victim, so a
    new terminal session still registers when the cap is full of Desktop
    records. A host running more than 24 Desktop sessions still loses the
    least recently active ones.
    (3) Children. Every process in a Desktop session inherits
    `CLAUDE_CODE_HOST_SESSION_ID`, so a `claude -p` started from it reported
    the id under its own session id: two reporters, ambiguous at start, dead
    at commit, and on a remote record, with no pid liveness, for the whole
    TTL if the child died without SessionEnd. The remote shim (1.14.0) sends
    the id only when the hook's Claude process is a direct child of Desktop's
    daemon. MEASURED on Linux (Claude Desktop's ssh daemon at
    `~/.claude/remote/srv/<hash>/server`, parent pid 1; each session a direct
    child running `~/.claude/remote/ccd-cli/<ver>`; Claude Code 2.1.283 runs
    a hook through `sh -c`, so `$PPID` is that shell): the shim skips at most
    three shells from `$PPID`, takes the first non-shell ancestor as Claude,
    and requires its parent's `/proc/<pid>/exe` under that directory. Unreadable
    drops the id. A host without `/proc` sends it as before: Desktop's layout
    there is unmeasured, and dropping it would cost the join. The LOCAL
    publisher has no equivalent check yet; a local child's record goes stale
    when its pid dies, which bounds it. The listener and the publisher still
    strip the id from every non-Claude agent.
    (4) The shared backoff. `post.sh` keeps one backoff stamp per user, so a
    transport failure in any session muted SessionStart and SessionEnd for
    every session on the host for 300 s. Both now always dial: they fire once
    per session and cannot storm the ssh client's terminal.
    An ambiguous desktop or bridge lookup logs how many live sessions report
    the id, local and remote counted apart, and never the id.
    RESIDUALS. Exact equality stays the only match; there is no newest-wins
    relaxation (owner's call). So a remote session that dies without
    SessionEnd next to a live reporter of the same id (a Desktop restart
    without SessionEnd that leaves two reporters, or a child on a host whose
    plugin predates 1.14.0) keeps the view ambiguous for up to 7 days rather
    than 4 h. Ambiguity abstains; it never joins the wrong
    session.
  - The overlay's join badge (`OverlayClaudeJoinBadge`) DESCRIBES the resolved
    join; it never resolves one. It reads `claudeSessionJoin` after the single
    start-time resolution and nothing else — a badge that asked again could name
    a different session than the context actually attached, which is the exact
    failure the once-per-dictation rule exists to prevent. Its one extra read is
    `registry.hasLiveSessions()`, which touches no title, TTY, socket, or process
    table and only chooses between "nothing attached" and showing nothing at all.
    Two exceptions to "nothing attached" (#658), both taken from the same
    start-time resolution. A gate that means nothing on this surface could
    use a join (no polishing endpoint, both context settings off, or a browser
    or Claude Desktop target without session context, which the screen
    setting alone never reads) hides the badge whatever the registry holds:
    "No Claude session" there blames a session for a setting. And focus
    inside a Claude Desktop session view whose id resolved to no single live
    session (`ClaudeJoinResolution.focusedSessionUnmatched`) shows it even
    with an EMPTY registry, because an empty registry is what a dead hook
    tunnel looks like.
    What it renders is a length-capped workspace `displayName` with control
    characters neutralized: a LOCAL name is the last component of a real
    directory, where a newline is legal and the panel is measured from the body
    text alone. Cc (newline, tab) becomes a space — deleting it would glue two
    runs into a directory name the user does not have — while Cf (bidi
    overrides, zero-width joiners) is dropped, being zero-width already.
    It names the joined workspace rather than showing a checkmark because a
    mis-join — the residuals documented on the cmux and remote-herdr arms — is
    invisible to a boolean and obvious next to the wrong repo's name.
    The badge travels as a PARAMETER of `startSession`, never a later setter:
    starting a session resets the panel, so a badge pushed before it was wiped
    and one pushed after depended on an order nothing enforced. It is always
    already known there — the join resolves before the realtime socket connects,
    and the panel opens after it.
  - Every dictation writes ONE persisted line saying how its join ended
    (`SessionContextResolver.noteJoinOutcome`, `Log.claudeContext` at
    `.notice`, `Claude join outcome: arm=… origin=… causes=…`): the arm that
    joined, or the gate that stopped it before the resolver ran, or the
    abstention chain the resolver noted. The arms keep logging at `.info`,
    which the unified log does not persist, so without this line a join
    could not be questioned after the fact (field, 2026-09-26: three hours of
    Claude Desktop dictations left only target verdicts). The line is
    `ClaudeSessionJoinSummary.noticeText`: categories, an origin class and
    counts only, never an id, path, host or address, because
    `mac-crashlog.yml` publishes what it reads.
  - Lookups abstain rather than guess: no match, unknown, stale, or ambiguous
    means no context. There is deliberately no sole-session or cwd heuristic —
    it is wrong precisely when it matters.
  - **One session log is read, for one field.** Mistral Vibe (2.25) has three
    hook types — `pre_tool`, `post_tool`, `post_agent` — and none carries the
    user's prompt, so the Vibe mode of the publisher reads the LAST user
    message from the `messages.jsonl` its hook payload names
    (`VibeTranscriptPrompt`, owner decision 2026-09-20). It is the same datum
    Claude Code hands over in `UserPromptSubmit`, and the read is bounded to
    it: a regular file named `messages.jsonl` owned by this user, opened
    `O_NOFOLLOW`; the last 512 KiB only, abandoned after 250 ms so a stalled
    volume cannot run into Vibe's hook timeout; a line is used only when its
    `role` is `user`, its `injected` field is PRESENT and `false`, and its
    `content` is a string, truncated to the wire's prompt limit. A line that
    does not contain Vibe's user-role marker is never parsed, nothing but the
    chosen `content` string is kept, and the path never crosses the socket
    (`testRecordsPutThePromptFirstAndNeverCarryTheTranscriptPath`). Schema
    drift in the log therefore costs the prompt and nothing else.
    Do not widen this read to another field or another agent: an agent whose
    hooks carry the prompt has no reason to be read this way.
    Vibe has TWO hook runners, chosen per account by a server-side rollout
    (`vibe_cli_unified_harness_rollout`, cached in
    `~/.vibe/experiment_eval_cache.json`), and the Unified Harness one sends
    `cwd` and `hook_event_name` only: no session id, no parent, no log path,
    and group-qualified tool names (`file_system.read_file`). Field failure
    2026-09-21: the parser required `session_id`, so every hook of an owner on
    the unified rollout was dropped with no log line and no Vibe session ever
    joined, while the dev box that verified the stack was on the legacy
    runner. Such a payload is published under an id made from the Vibe
    process (`vibeProcessSessionID`: pid and start time, none without a start
    time), because one interactive Vibe process shows one session in one pane
    and the pane is what a join names. It costs the prompt, since no log is
    named and the publisher does not search for one, and the subagent
    filter, since nothing marks one: a subagent's file touches count toward
    the session of the pane it runs in. A payload with a session id and WITHOUT
    `parent_session_id` is neither shape and is still dropped. The remote shim
    (`compact.py`) applies the same rules.
    What the missing events cost: a Vibe session exists for us only from its
    first file-tool call or the end of its first turn, so the first dictation
    into a fresh session has no join; and with no session-end event a session
    ends by liveness and TTL. Pid liveness alone is not enough for that: a
    Vibe that exited leaves its shell on the same tty, and once any process
    reused its pid the dead session would join that shell (Codex review,
    2026-09-20). Vibe records therefore carry the process START TIME
    (`agent_start_us`), and `ClaudeSessionRegistry.isFresh` requires the pid's
    current start time to equal it, unreadable counting as a mismatch
    (`testAReusedPidDoesNotKeepADeadVibeSessionJoinable`). Records without the
    field, Claude Code's and opencode's today, keep pid-only liveness. Vibe starts hooks in a new session with no
    controlling terminal, so the published pid and tty come from an ancestor
    walk (`ClaudeHookPublisher.vibeAncestorPID`), and the two Claude-allocated
    session handles are withheld from Vibe records — a Vibe started inside a
    Claude Code session inherits them and would otherwise join that Claude
    view.
  - **Codex CLI joins through a plugin, and trust is Codex's to give.**
    Codex runs a non-managed hook only after the user trusts it, silently
    skips it otherwise, and keys that trust by source and position with a
    hash of the handler AS DECLARED: event, matcher, command string before
    `$PLUGIN_ROOT` expands, timeout (0.156.0, measured on this repo's
    probe, #716). Two rules follow. The hooks ship as a Codex plugin
    (`integrations/codex`, installed by `codex plugin add`), never as an
    entry in `~/.codex/hooks.json`: a `hooks.json` entry's key includes its
    index in that file, which herdr also writes, so an edit above ours would
    untrust it without a word, while a plugin's key names the plugin. And
    `hooks/hooks.json` stays byte-stable: every hook runs the same fixed
    command, pinned by `testTheHookCommandIsTheOneUsersTrusted`, because a
    changed handler asks every user to trust it again. The shim it runs may
    change freely; Codex hashes the command, not the script (measured: a new
    plugin version with a changed shim stayed trusted). For the same reason
    the Integrations dot turns green only after a Codex record reached the
    registry (`ClaudeSessionRegistry.hasHeard(localAgent:)`, carried across
    launches by `CodexHookHeardMemory` and reset by every install or
    removal): an installed, untrusted plugin looks exactly like a working
    one from outside Codex. The app never writes Codex's trust records
    itself, though they are plain TOML: trusting a hook is the user's
    decision, made at Codex's own "Hooks need review" prompt.
    The payload is a near clone of Claude Code's and is parsed as an
    allowlist (`CodexHookInputParser`): `transcript_path`, `model`,
    `tool_response`, `last_assistant_message` and the patch body are
    dropped. Codex has no read tool (it reads through `Bash`), so files come
    only from `apply_patch`'s patch headers. A subagent's events carry the
    parent's `session_id` plus an `agent_id`; its edits count for the
    session, but a prompt it submits is dropped, because the prompt block and
    correction learning read that prompt as the user's. Codex spawns hooks
    like Vibe does (`$SHELL -lc`, a new session, no terminal), so the pid and
    tty come from the same ancestor walk, the start time rides along
    (`SessionEnd` has a 3 s ceiling and can be missed), and the Claude
    session handles are withheld. Ids are scoped under `codex:`.
  - Apart from that, transcripts are never scraped (the Claude Code parser
    drops `transcript_path`), and a
    LOCAL session never attaches hook-quoted tool excerpts: its files are
    readable directly and are the better source. A REMOTE session's bounded,
    sanitized excerpts DO attach (`ClaudeSessionContextText`, gated on the
    origin) — there is no remote collector, so they are the only thing we will
    ever know about that tree.
  - Everything harvested feeds GROUNDING even when the rendered excerpt is cut
    to nothing — matching is input-side and free; only rendering pays the
    budget.
  These paths are in `scripts/ci/llm-lane-filter.sh`: they change what reaches
  the model, so the LLM lanes run on them.
- **A rejection's remedy is earned by its wire shape, and only one shape earns
  the plugin remedy.** `ClaudeRemoteRejectionCategory` exists because one
  undifferentiated "rejected unauthenticated connection" line cost a dispatched
  log-collection workflow to diagnose (field report, 2026-07-26). Two of its
  cases turn on a distinction that looks cosmetic and is not: a header that
  ARRIVED carrying no credential (`Bearer `, from a `${…}` Claude Code never
  expanded into an http hook) is the pre-1.1.0 plugin's exact signature and
  keeps the full "update the plugin on the host" clause; NO `Authorization`
  header at all cannot come from any plugin generation — the pre-1.1.0 manifest
  declared the header statically, and the command shim that replaced it writes
  the header before it dials and fails open without dialing when the token is
  unset — so it is an unauthenticated caller, gets its own line with no host
  remedy, logs at `.notice` rather than `.error`, and is excluded from
  `Snapshot.isEmpty` so it raises no Settings hint. That last part is not
  tidiness: the enrollment verify probe posts here WITHOUT a credential on
  purpose and reads the 401 as its success signal, so collapsing the two shapes
  made every setup check write a line accusing a healthy host — a phantom for
  the next person reading this log, in the one subsystem whose documented
  diagnostic route is reading the log later. Do not re-collapse them, and do not
  soften the `.emptyCredential` clause into vagueness to cover both: losing the
  pre-1.1.0 diagnosis is the worse failure of the two, which is why the split is
  decided by the request's own bytes rather than by any state this app keeps —
  there is no window to be outside of and nothing a caller can assert to land in
  the quieter category that it could not already assert to land in another.
- **Remote Claude context is opaque by construction.** The remote listener tags
  every accepted session `.remote` regardless of its payload; a local process
  connecting to that listener can only downgrade itself. Remote cwd values are
  labels, not `LocalWorkspacePath` values, and can never authorize FileManager
  or git calls. Sessions are namespaced by the host id whose token authenticated
  them, so hosts cannot collide or forge each other's sessions. Bounded,
  sanitized remote prompt/file/tool excerpts may feed the same context budget,
  but there is no remote repository collector. The same rule governs the
  `X-Lvx-Env-*` enrichment: those values live in
  `ClaudeSessionSnapshot.remoteEnvironment`, never in `.process`, so they
  cannot reach `resolve(tty:)`, `resolve(herdrPaneID:)`, or
  `liveLocalHerdrSocketPaths()` — the local-only arms all read `process`. A
  remote `HERDR_SOCKET_PATH` is a label, not a socket `HerdrSocketClient` may
  dial (its guard still requires a local socket owned by `getuid()`) — the
  remote herdr arm reaches it only by handing it to `ssh -L` as a forward
  target, so the path is resolved on the host that named it and the socket the
  client actually dials is the LOCAL end our own child created. And
  `hookParentPID` is a String on purpose: a pid in another host's namespace is
  not a number this process may probe, only a label to compare against another
  label. `X-Lvx-Env-Project` (#652) is the host's basename for the session's
  repository; it replaces the cwd label only as the learned-terms key
  (`ClaudeSessionSnapshot.learnedTermWorkspace`), and only when it is already
  a label under `ClaudeWorkspaceReference.opaqueLabel`'s rule: a value that
  would need reshaping is refused, never reshaped.
- **A remote request names its agent in a header, and the header buys nothing
  but a namespace.** A remote host runs no publisher of ours, so the agent
  cannot ride inside the record the way it does locally: the Vibe shim
  (`integrations/vibe/remote/`) sends `X-Lvx-Agent: vibe` beside a body in
  Claude Code's hook shape. `ClaudeRemoteAgentCodec` reads absent as Claude
  Code (every plugin shipped before the header is one) and REFUSES a value it
  does not know, opencode included, rather than filing a newer shim's agent
  under Claude Code's join rules. The header is a claim by an authenticated
  host about its own sessions: the origin stays `.remote` and the id stays
  scoped under the host whose token authenticated the request, with the agent
  prefix in front (`vibe:remote:<host>:<id>`) only so two agents on one host
  cannot share a key. For any agent but Claude Code the listener drops the two
  Claude-allocated handles (`bridgeSessionID`, `desktopSessionID`) on arrival,
  whatever the shim sent, for the reason the local publisher withholds them.
  On the host, Vibe's payload never crosses the tunnel as Vibe wrote it: a
  `post_tool` payload embeds whole files, so `compact.py` (standard-library
  Python, run on the interpreter Vibe itself uses, owner decision 2026-09-20)
  reduces it to the fields the Mac keeps plus the same short excerpts a remote
  Claude Code session sends, and reads the prior prompt under the same rules as
  `VibeTranscriptPrompt`. The two implementations are a pair: change one,
  change the other. The token lives in a 0600 file under
  `~/.vibe/localvoxtral/remote/` (owner decision, same exposure as the Claude
  plugin's token in `~/.claude`: any process running as that user can read
  it), is read into a shell variable, reaches curl through a header file, and
  is never exported, so `compact.py` cannot see it: the shim runs `set +a` and
  `unset TOKEN` before the first assignment, because a shell exports a
  variable it imported from its environment (Codex review, 2026-09-20). The
  shim prints nothing on any path, because Vibe reports hook output as a
  failure; there is no stdout gate because there is no stdout. The interpreter
  is the one RUNNING Vibe (`/proc/<pid>/exe`, or `ps -o comm=` on macOS, of the
  hook's parent or grandparent), accepted only as an absolute path whose name
  is exactly a Python, and run with `-I`; the `vibe` launcher's shebang and
  `python3` are fallbacks under the same check.
  **A remote Vibe session ends because the host says so.** Vibe has no
  session-end hook and a remote pid cannot be probed, so without help a
  finished session would stay joinable for the four-hour TTL on the very
  terminal the next one starts in — the normal exit path, not the abnormal one
  the Claude Code residual describes (Codex review, 2026-09-20). The first hook
  of a session that reaches the Mac therefore leaves one background shell on
  the host (`post.sh`, "Exit watcher"): one per session by an atomic `mkdir`
  lock, holding none of the hook's descriptors (Vibe waits for them to close),
  comparing the Vibe process's start time as well as its pid, re-reading the
  token when it fires, posting `SessionEnd`, and giving up after five tries a
  minute apart. `LOCALVOXTRAL_VIBE_WATCHER=off` disables it. Three shapes it
  handles on purpose (GLM review, 2026-09-20): a Vibe that is ALREADY gone when
  the hook looks (Ctrl-C at the end of the turn) gets its `SessionEnd` at once
  instead of no watcher; a session id reused by a new process (a resume)
  replaces the old watcher, whose `SessionEnd` would otherwise evict the live
  session; and when the host's `ps` gives `compact.py` no process table, no pid
  is published and no watcher starts, because the only pid left is the `sh -c`
  wrapper and watching it would end a LIVE session two seconds later.
  There is deliberately NO Mac-side eviction of an older remote Vibe session by
  a newer one on the same surface. It was built and removed the same day:
  suspend Vibe A, start B in that pane, bring A back, and a dictation into A
  joins B until A's next hook. Two live candidates on one surface make the
  join abstain, and abstaining is the failure this file prefers everywhere.
  RESIDUAL, stated plainly: when the watcher's `SessionEnd` never arrives (the
  tunnel was down for all five tries, the host rebooted, the watcher is off),
  the dead session stays the surface's candidate until its TTL: alone, it still
  joins; beside a new session, the surface abstains. Nothing on the Mac can
  tell a finished remote process from an idle one.
- **A host may hold one extra credential per purpose, and it buys no extra
  trust.** The app keeps only a HASH of a host's token; the plaintext went into
  the Claude Code plugin's config at enrollment and is gone. The Vibe hooks on
  that host therefore get their own (`ClaudeRemoteCredentialPurpose.vibe`,
  owner decision 2026-09-20, chosen over rotating the one token because a
  rotation cuts off the host's running Claude Code sessions). It authenticates
  AS THE HOST: same id, same session namespace, same origin channel. The
  purpose is a label for the row and for replacing the right one, never a
  permission, because both tokens sit under one user on one machine and there
  is no boundary between them to enforce. Every stored hash is still compared
  on every request with no short-circuit, `rotateToken` and `revoke` clear the
  extras (both answer a suspected leak, and the extras sat next to the leaked
  one), and a revoked host is refused a new one. A credential is two-phase
  (`prepareCredential`, then `commitCredential`), and three rules ride on that
  (Codex review, 2026-09-20). A pending credential is BOUND to the host's own
  token as it was at prepare time, and the commit refuses when it changed: a
  Rotate token pressed while ssh runs must not be undone by a credential that
  was already on its way to the host. The commit trusts the new token IN
  ADDITION to the purpose's current one, at most two, until
  `retireOtherCredentials`: the token file is the LAST thing setup writes, and
  a connection that dies there leaves the app unable to know whether it
  landed, so both must authenticate until it does know.
  There is no per-harness control on a host row (owner ruling 2026-09-21: every
  harness gets its own line or none does, and none is the choice). Vibe is the
  `remoteVibe` step of the host's one setup run: it installs when the probe
  finds `vibe`, reports `vibeNotFound` as a skipped step otherwise, and a
  failure fails the run. Claude Code is optional the same way
  (`claudeNotFound`, decided on exit 127 AND our PATH resolver's own sentence,
  never a bare 127): the plugin step is skipped and the final check drops its
  plugin half. A host with neither agent fails the run. A finished update
  closes its panel, so a step the run left to the user is NAMED by the
  row's one sentence. The step is skipped as already current when the host is
  set up and has reported this build's hooks version: running it anyway would
  replace a working token under live Vibe sessions and let a refusal about
  `~/.vibe` fail an update started for the plugin (GLM review, 2026-09-21). A
  run that failed for want of any agent does not settle the row. The row offers the run while the plugin OR the Vibe
  hooks are outdated or unheard from. "This host has no Vibe" is remembered
  for the app session only, like the plugin version report, which is also how
  a Vibe installed later gets its hooks: the run is offered again after a
  relaunch. Removing a host contacts nothing, so the hook files stay there
  with a token that no longer authenticates, as the plugin does.
  Host setup (`setUpRemoteVibeHooks`) follows the enrollment rules — BatchMode
  ssh, script on stdin, token in no argv on this Mac, fixed error strings — with
  one difference worth knowing: it EDITS A USER FILE on the host,
  `~/.vibe/hooks.toml`. The edit is computed on the Mac by
  `VibeHooksBlockEditor`, the same rules as the local install, not
  reimplemented in awk. So the probe reads the file back (base64, 256 KiB cap)
  and its `cksum`, and the write happens only if the `cksum` still matches.
  Those bytes are text to splice and nothing else: they never reach a log, an
  alert, or a verdict string (the read-back failure names the version this
  build EXPECTED, never the one the host claimed), and the checksum is held to
  `[0-9:]` before it is spliced into a script. These runs move files, so they
  ask the ssh runner for a larger `Invocation.Budget` by name; past the pipe
  buffer the runner feeds stdin from a writer thread after launch (raw
  `write(2)`, `F_SETNOSIGPIPE`), because a preload that size would block with
  no child to drain it. Every other enrollment script keeps the standard
  budget and the preload. Each file is written through a quoted
  here-document whose delimiter is checked against every line of the content.
- **A refused `RemoteForward` bind is not a diagnosis, and only a nonce
  round-trip may upgrade it to one.** OpenSSH's `remote port forwarding failed`
  says a port is held, never by whom, and the two holders want opposite things
  from the user: a stranger is a failure they must clear, while their own ssh
  session carrying the enrollment block's `RemoteForward` IS the working
  channel — the normal state for anyone who ssh's to the host they enrolled.
  Reporting the second as contention told them to close the session providing
  the tunnel (field report, 2026-08-29). `ClaudeRemoteForwardOwnershipCheck`
  separates them, and the rule about HOW is load-bearing:
  - **The remote host's answer is never the evidence.** Our 401 (and the 411 an
    empty POST gets) is public in this repository, so any process that binds
    that port can reproduce it byte for byte; and a SECOND Mac enrolled against
    the same host returns a genuine 401 of its own, which is exactly the
    contention `ClaudeRemoteForwardPort` exists to surface. A status-code probe
    would adopt both.
  - **The evidence is arrival.** The probe posts a fresh 128-bit nonce into the
    disputed port FROM the remote host (`ssh -o BatchMode=yes -o
    ClearAllForwardings=yes`, bounded timeout, the script on stdin so the nonce
    is never in the ssh argv on THIS Mac — which is also the CI runner — and no
    token, since the request is expected to be refused), and the verdict is
    whether THIS process's own listener saw that nonce
    (`ClaudeRemoteForwardProbeWitness`). A stranger receives the nonce and can
    do nothing with it: the listener binds `127.0.0.1` on the Mac and the only
    route to it from that host is a `RemoteForward` terminating here — and the
    disputed one is the forward the stranger is the reason we do not have.
    Another Mac's listener has never heard of it. The probe's exit status is
    deliberately not consulted in either direction.
  - **Two residuals, stated because the next reader will otherwise assume they
    are not there.** (1) Arrival identifies the LISTENER, not the port that
    carried the nonce: every supervised `-R` ends at the same local listener, so
    where a host has a SECOND live forward to this Mac (a legacy
    `RemoteForward 8473` left in the user's own config block and carried by an
    interactive session), a hostile holder of the disputed port can replay our
    request down that other forward and forge a match. (2) The nonce is out of
    the ssh argv but is in `curl`'s argv on the REMOTE host for the `--max-time`
    window; `--header @file` would fix that and is not used because it needs
    curl >= 7.55 on an arbitrary host and would fail silently below it. Both
    residuals require code execution on the enrolled host, which already implies
    possession of the plugin's bearer token — so `.ourListener` is a DIAGNOSIS
    and never an authorization. Do not restate either claim absolutely.
  - **Every other outcome is `portUnavailable`.** No probe wired in, no `curl`
    on the host, ssh refused, a timeout, an unparseable anything — all
    `.unproved`, which is also the default when the seam is nil. Fail closed is
    not a branch here, it is the absence of one, because the alternative is
    telling the user everything is fine while a stranger collects the remote
    plugin's bearer token from every hook.
  - **The listener's one pre-auth look is not an oracle.** The nonce check runs
    before the token because a self-probe must not land in the rejection tally
    the user reads for "which of three fixes do I need". It compares only a
    value this process minted and is still waiting for, it returns the same 401
    with the same headers and the same empty body either way, and a match
    short-circuits — so a matching nonce cannot carry a payload past
    authentication even when a valid token rides with it.
  - **A proved channel is a claim with an expiry.** `externallyForwarded` is
    held by a session the app does not own and cannot be notified about, so the
    supervisor re-attempts its own `-R` on a long injected-clock park
    (5 minutes): the session ending means the bind now succeeds and the app
    takes the tunnel over, and a holder that stops proving ownership drops back
    to `portUnavailable`. A state that claims a channel must be able to stop
    claiming it.
  - **An unproved refusal is a state, not an end (#659).** `portUnavailable`
    parks on the same 5-minute interval and dials again. It used to be
    terminal, and after a network change the holder it blamed was usually this
    Mac's own dead connection, still bound on the host until its sshd dropped
    it. The fail-closed part is unchanged: the pane says the port is held, and
    nothing is treated as ours without the nonce. The park is what keeps this
    from being a retry storm; a refusal never enters the restart backoff. Wake
    and network-path changes (`recover()`) restart failed and parked
    supervisors at once, and leave live ones to ssh's keepalive.
  - **Only a refusal of OUR port counts.** The supervised ssh inherits every
    `RemoteForward` the alias declares, so it runs `ExitOnForwardFailure=no`
    and ends itself (SIGTERM to its own child, then the usual escalation) only
    when the refusal names this Mac's port. A refusal of another port is
    logged and ignored. The residual: when such a foreign forward is free, this
    connection binds it too, as any ssh with that config would.

- **Remote enrollment execution is opt-in, consent-first, and keeps the token
  out of process arguments.** `ClaudeRemoteEnrollmentService` generates the
  idempotent ssh config block and remote scripts, but Settings never renders or
  copies their text. Enrollment and host update expose only the seven-step
  `RemoteHostSetupRun`, one consent sentence naming the local files and SSH
  alias, and a Details link to `docs/remote-claude-context.md`, where every
  command is listed. Local insertion replaces only the
  matching host's marked block, preserves an existing config's permissions, and
  atomically renames a same-directory temporary file; a missing `~/.ssh` and
  config are created as 0700/0600. It refuses and directs the user to the docs
  when `~/.ssh/config` or `~/.ssh` is a symlink — a rename
  would replace the link and desync a dotfiles setup — or when `~/.ssh` is not
  owned by the user or is group/world-writable. Remote execution spawns only `ssh -o
  BatchMode=yes <alias> /bin/sh -s` and sends the generated token-bearing script
  through stdin — the token must never enter an argv ON THIS MAC (on the remote
  host `claude plugin install` takes its config as a flag and has no stdin path,
  so the token is in that one command's argv there, and in `~/.claude` after —
  documented in `docs/remote-claude-context.md`, not defended). The read-only
  verification probes (`executeVerification`) are the OTHER ssh-bearing path and
  obey the same rules: `BatchMode=yes` plus `--` before the alias on all,
  `ClearAllForwardings=yes` on the plugin probe and on the FIRST tunnel probe.
  That first tunnel probe must not be able to open the tunnel it checks: the
  earlier single probe carried the alias's `RemoteForward`, curled through the
  forward it had just bound, and passed on hosts where nothing else ever holds
  the tunnel, which is every host reached only by Claude Desktop, whose ssh
  clears forwardings (#656). Only when nothing answered does a SECOND tunnel
  probe run without the option, and its 401 is reported as "the config opens
  the tunnel, but nothing keeps it open", never as a pass; a squatter verdict
  from it is `decidedBy: .remote`, so `reconciled` cannot upgrade a tunnel
  that closed with the probe. The Claude Desktop probe (`~/.claude/remote/srv`)
  runs only while Keep the tunnel open is off and only turns it ON, inside the
  host setup run the user clicked. They carry no token at all, and no byte of their
  output reaches a verdict, an alert, or the log. The whole action has a
  finite timeout, and every captured result, thrown error, alert, and log string
  is token-redacted before it leaves the service. Keep the filesystem and
  process runners injected; the no-runner service must continue to throw
  `.executionNotConfigured`.
  `ClaudeIntegrationSettingsModel` (`@MainActor @Observable`, all seams
  injected) owns the pane's logic, and `ClaudeRemoteListenerCoordinator` owns
  the bind/unbind decision — enrolling the first host binds immediately and
  revoking the last one closes the port, with no relaunch. Adding a host to an
  already-bound listener rebinds NOTHING (it authenticates against the registry
  live), so a second enrollment cannot drop the first host's tunnel.
  A bind conflict is reported, never routed around onto another port: a
  squatter on 8473 receives the remote's bearer token before anything rejects
  it, so the user must learn it is there. What the squatter does NOT get is a
  path into the prompt: the remote shim's stdout gate (post.sh) rejects any
  200 body that is not exactly the listener's one control JSON body — which
  since 2026-09-05 is a CONSTANT (`{"suppressOutput":true}`) carrying no field
  that could put a byte on a terminal, so there is no variable part left for a
  squatter to aim at. The fixed `X-Lvx-Session: joined|unknown` response header
  only selects a private per-session status stamp and never reaches stdout.
  The shim's request-side `X-Lvx-Plugin-Version` header (its own version, a
  constant in `post.sh`) is the same shape of rule: validated to a strict
  numeric shape on arrival (`ClaudeRemotePluginVersionCodec`), recorded on the
  host only where the request is finally ACCEPTED — the same points
  `lastSeenAt` is noted, never on first authentication alone, so a request
  the revocation re-check refuses cannot mutate a report that rotation would
  then preserve — never logged, and used only to
  select the fixed "Update available" string in Settings. The
  recorded value is the HIGHEST any of that host's hooks reported this app
  session and is never lowered, because Claude Code applies a plugin update
  only on session restart — after "Update Plugin…" the host's already-running
  sessions keep sending header-less hooks from the old shim, and a
  last-writer-wins record would flip a verified host back to "update
  available" over an install the read-back had just proven current.
  Note also what is NOT defensible: a
  malicious process running as the user on the REMOTE host can still read
  `~/.claude/` and therefore the plugin's token no matter what we do. Say so
  rather than implying the token bounds it.
- **The Mac asks a host to spend, and the host's answer is a label source**
  (#641). A remote project's terms come from a run on the host, because the
  Mac holds only a label for the repository and a label never becomes a path,
  a cwd or an ssh argument. The ask is one fixed reply header,
  `X-Lvx-Terms: wanted`, of the same kind as `X-Lvx-Session`: it never
  reaches the shim's stdout, and the body stays the constant. It goes only to
  a session a dictation joined, once per mark (`RemoteProjectTermRequests`,
  10 minutes), only when THIS request's shim version reads it, and a mark is
  made only for a host that reported such a version and a project with no
  stamp. A squatter on the port can send it too; the host's per-project stamp
  (atomic `mkdir`, attempt time, `done` after a 200) bounds that to one run per
  project per 24 hours, under the #609 caps. The shim starts `terms.sh`
  detached under `env -i HOME PATH LANG USER LOGNAME` (macOS finds a Claude
  Code keychain login only with `USER`) with every descriptor on `/dev/null`:
  a run started from a hook inherits the session's `CLAUDE_CODE_*` ids and the
  plugin's `CLAUDE_PLUGIN_OPTION_TOKEN`, and the token reaches the runner only
  on stdin, then a header file for curl, never an argv or an environment.
  `POST /v1/terms` authenticates like a hook, scopes the session id under
  the host that authenticated it, and accepts one answer per ask, for a live
  session of the asked agent; the project key is the one the Mac recorded at
  the ask, never anything the host sends. The body is untrusted text that repo
  contents can steer: 8 KiB at most, `{"terms": [...]}` only, through the #609
  term filter, stored only as unconfirmed proposals. A refusal logs its reason,
  never a byte of the body. What stays as it was: the stdout gate, the hook's
  fail-open exit, the forward, and what is sent to herdr.
- **The SendEnv probe uses a random value that is never logged and never
  interpreted beyond equality.** `probeRemoteEnvironment` mints a fresh nonce
  per call (a UUID by default, injected in tests), exports it into that one
  ssh child's environment as `LC_LVX_TTY`, and compares the remote echo by
  exact equality only. The echo travels framed (`LVX_TTY:`) and only the
  first framed line is read, so banner or stderr noise sharing the capture
  pipe cannot flip the verdict; the frame itself is never interpreted. The
  value never appears in argv or stdin — where it would land in `ps`, the
  log, or a build transcript — and never in a `Log` line, a
  `VerificationCheck`, an alert, or an error. A mismatch reports only which
  side refused, with its fixed remedy: no `sendenv` covering the host in
  `ssh -G` means this Mac is not sending it; otherwise the remote sshd
  refused it. Do not "improve" the diagnosis by quoting what came back: the
  echo is remote output, and remote output never travels.
- **The dogfood control socket is an accepted tradeoff, and the acceptance was
  bounded.** An instrumented build can expose a local AF_UNIX socket that
  starts dictations and reports what the context pipeline resolved
  (`DogfoodControlSocket`), because two things are unobservable from outside
  the process: a dictation has no deterministic trigger, and
  `ClaudeSessionRegistry` is per-process, so `--probe-surface` sees only the
  sessions the app last saved to disk. What makes that acceptable is a set of
  bounds, each of which is the whole argument for the one above it:
  - **`#if LOCALVOXTRAL_DOGFOOD` and nothing else.** A shipped build compiles
    none of it — no listener, no path, no code that could create one, and no
    setting or argument that turns it on.
    `DogfoodControlBuildBoundaryTests` runs in BOTH configurations (it is
    deliberately not itself gated) and fails when any reference escapes the
    flag; that is the only kind of test that can notice this leaking into a
    release. Within an instrumented build there is a SECOND runtime gate,
    `debug.dogfood_control_socket_enabled`, kept separate from the capture's:
    writing records and accepting commands are different consents.
  - **0700 directory, 0600 socket, and `getpeereid` before the first read.**
    The permissions should already make another uid unable to reach the path.
    The credential check is there because "should" is a claim about the
    filesystem, not about this process.
  - **Every value that crosses is a bool, a count, or a closed enum name.**
    `ClaudeSessionJoinSummary` is reused rather than re-mapped (its third
    consumer, after the dogfood record and `--probe-surface`), abstention
    causes are the resolver's own content-free categories, and `registry list`
    reports session SHAPES — never a session id, marker, workspace, tty, pane
    id, socket path or host. Replies pass through `DogfoodCaptureRedaction` as
    a backstop, not as the strategy.
  - **`session start` reaches `handleModifierOnlyTap`, the gesture's own
    handler.** It is subject to the Secure Keyboard Entry refusal, the
    Accessibility state, the microphone gate and backend readiness exactly as a
    real trigger is; a refusal is REPORTED, never overridden. The only thing
    added on top is another refusal (a start while dictating would toggle the
    session off). It is also CAPPED — auto-stopped after a bounded window on an
    injected clock — so a client that disconnects mid-dictation cannot leave
    the app recording, and every exit path releases the cap.
  - **Nothing can be injected.** No command carries a surface, a session, a tty
    or a join. Every verb observes real resolution; a socket that could
    fabricate one would answer questions about itself.
  - Unlike `--probe-surface`, `surface probe` wires the app's FULL-capability
    resolver. That is deliberate and is the reason the socket exists: the
    withholding in the one-shot verb is about a process that is a bad owner for
    a supervised `ssh -L` and a nonce lease, and the app is the good one. A
    probe that withheld them would answer a different question from the one a
    dictation asks.
- **The `localvoxtral` command shares the hook socket, and its replies are the
  one place that socket returns data** (#721). A line with a `cli` key is a
  command request (`AgentCLIWire`); it is answered and the connection closes,
  and it never reaches the registry. The trust is the hook path's, unchanged:
  the 0700 directory, the 0600 socket and `getpeereid` before the first byte,
  so only processes running as the user can ask, and each of them could read
  `default.store` and `learned-terms.json` from disk already. That equivalence
  is the whole argument, so it bounds what the command may do: no TCP
  listener, ever (a loopback port is reachable by every local user and every
  page a browser loads); no command that writes history or starts a
  dictation; and replies carry what the stores hold and nothing more. History
  keeps the clipboard placeholder, never the clipboard, and so does the
  command. Under History's **Don't keep**, `history` answers an empty list
  with `historyKept: false`, not an error: nothing is kept, so nothing is
  found, and the flag says why. `terms propose` writes only unconfirmed proposals
  (`LearnedTerms.recordCommandProposal`), under the same rules as #609's:
  term-shaped only, never a term the user listed or refused, confirmed only
  by three dictations or a pin. The caller's name (`agent:<name>`) is read
  from the agent's own environment and is a label, not a credential: every
  caller shares the uid. Unlike the headless run's answer, a command proposal
  does not stamp the project, because it is a few names, not the project's
  list. The hook receipt (`ClaudeBrokerResponse`) is untouched and still
  carries nothing a hook could print.
