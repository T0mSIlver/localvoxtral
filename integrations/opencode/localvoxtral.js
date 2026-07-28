// localvoxtral opencode plugin — dictation context for opencode sessions.
//
// Install (see README.md beside this file): copy this ONE file into
// ~/.config/opencode/plugins/ (the server half auto-discovers from there),
// and list it in ~/.config/opencode/tui.json (the TUI half loads only
// explicitly listed plugins — verified on opencode 1.17.12). Uninstall:
// delete the file and the tui.json line. No dependencies.
//
// It publishes bounded NDJSON records (wire v2, `agent: "opencode"`) over the
// localvoxtral app's private AF_UNIX socket — the same wire the Claude Code
// hook publisher speaks (Sources/ClaudeContextWire/ClaudeHookWire.swift).
// When the app is not running, every write fails silently: this plugin runs
// INSIDE the user's agent process, and a hang or throw that stalls their turn
// is the worst possible failure. Hence the hard rules below:
//
//   * No network-shaped waiting inside hooks. One lazily (re)connected
//     socket, unref()ed, fire-and-forget writes. Broker reply lines settle
//     callbacks (one reply per record, in order); each is read only for the
//     broker's `accepted` verdict and never surfaced anywhere.
//   * Every handler body is wrapped in try/catch and swallows everything.
//   * Nothing is ever written to the terminal: no stdout, no stderr, no
//     logging. opencode's TUI owns those descriptors.
//   * Bounded everything: prompts, paths, per-record file lists, line bytes,
//     session caches.
//
// TWO HALVES, ONE FILE, chosen per JS realm. opencode's local TUI runs its
// server in a Bun Worker thread (opencode source: packages/opencode/src/cli/
// cmd/tui.ts, `new Worker(file)`), so the server plugin loader executes in
// the worker realm and the TUI plugin loader executes in the main realm — and
// a module may default-export either `server()` or `tui()`, never both
// (packages/opencode/src/plugin/shared.ts, readV1Plugin). The realm split is
// exactly the gate we need:
//
//   * Worker realm (never a TUI) -> the server half. It publishes session
//     content and NEVER a TTY: under `opencode serve` a naive isatty answer
//     would name a device whose pane does not display the session — the
//     mis-join the whole design exists to prevent. Positive evidence or
//     abstain, like the app's HerdrClientTTYProbe.
//   * Main realm -> the TUI half. Only a realm that renders a pane loads it,
//     and only it publishes the pane's TTY — inside FocusChanged records that
//     declare which session the pane currently displays. One opencode process
//     hosts many sessions on one TTY; the focus declaration is what lets the
//     app's registry resolve that TTY to exactly one of them, or abstain.
//
// Headless realms (`opencode serve` / `opencode run` main thread) find a
// `tui` module where the server loader wants `server()` and skip this plugin
// with a log entry. Deliberate: `run` has no pane to dictate into, and a
// serve process must not publish TTYs. See README.md ("What does not
// publish") before "fixing" this.

import net from "node:net";
import fs from "node:fs";
import { isatty } from "node:tty";
import { isMainThread } from "node:worker_threads";

// Wire constants — must mirror ClaudeHookWire.swift / ClaudeHookLimits. The
// repo's OpencodePluginManifestTests pin these against the Swift constants.
const WIRE_VERSION = 2;
const AGENT = "opencode";
const MAX_LINE_BYTES = 64 * 1024;
const MAX_PROMPT_BYTES = 8 * 1024;
const MAX_PATH_BYTES = 4 * 1024;
const MAX_FILES_PER_RECORD = 16;

// The registry treats a focus declaration as stale after 45 seconds
// (ClaudeRegistryLimits.defaultFocusDeclarationTTL); a 20-second heartbeat
// keeps a steadily displayed session fresh across one lost write, and the
// half-second sample keeps a session SWITCH visible almost immediately —
// opencode's TUI plugin API exposes the displayed session only as the
// `api.route.current` getter (no route-change event exists on any bus in
// 1.17.x), so sampling cadence is the switch latency. Bus events additionally
// trigger an immediate resample, so any switch that coincides with session
// activity is caught event-fast.
const FOCUS_POLL_MS = 500;
const FOCUS_HEARTBEAT_MS = 20000;

// Bounds on in-process caches, so a very long-lived opencode cannot grow.
const MAX_TRACKED_SESSIONS = 64;

// Hard cap on bytes queued in the socket before the runtime flushed them. A
// broker that stops reading must never grow this process's memory: past the
// cap the connection is reset and records are DROPPED — context is a
// nice-to-have, the user's agent process is not. (Soft by one record: the
// check runs before each write, so the queue can exceed the cap by at most
// one MAX_LINE_BYTES record before the reset triggers.)
const MAX_QUEUED_BYTES = 64 * 1024;

// Cap on reply callbacks outstanding on one connection. The real broker
// answers every record it reads and closes a connection after 8 records or
// a 2s read deadline (ClaudeContextBroker limits), so a queue anywhere near
// this deep means the peer is not behaving like the broker: reset the
// connection (settling every pending callback as failed) rather than grow.
const MAX_PENDING_REPLIES = 16;

// ---------------------------------------------------------------------------
// Socket path — mirrors ClaudeHookSocketPath.swift exactly.

function socketPath() {
  const override = process.env.LOCALVOXTRAL_CLAUDE_SOCKET;
  if (override) return override;
  const home = process.env.HOME;
  if (!home) return undefined;
  if (process.platform === "darwin") {
    return home + "/Library/Application Support/localvoxtral/run/claude-context.sock";
  }
  const base = process.env.XDG_RUNTIME_DIR || home + "/.local/state";
  return base + "/localvoxtral/claude-context.sock";
}

// ---------------------------------------------------------------------------
// Publisher — lazy connection, fire and forget, replies settle callbacks.
//
// The broker serves short connections (whole-connection read deadline, a
// per-connection record cap), so the socket naturally closes between bursts;
// the next publish reconnects. Writes issued right after createConnection are
// buffered by the runtime until the connect completes — nothing here ever
// blocks a hook on the dial.
//
// The socket is request/response: the broker writes exactly one reply line
// per record it reads, in order (ClaudeBrokerResponse). A caller that passes
// an onReply callback gets it settled exactly once: false when the reply says
// `accepted:false` (the broker read the record but the registry refused it —
// e.g. a focus declaration racing ahead of its session record) or when the
// connection failed, was reset, or closed first; true otherwise. A reply
// with no `accepted` field, or one that does not parse, settles TRUE — that
// is a pre-`accepted`-era broker, and an old broker must look like the old
// contract, not like a rejection storm. Reply content is never surfaced
// anywhere a terminal could see it; this plugin has no title channel.

let socket;

function connectSocket(path) {
  const created = net.createConnection(path);
  created.unref();
  // Reply callbacks for records written on THIS connection, oldest first —
  // per-connection state, so a reset can never settle a successor's writes.
  const pending = [];
  created.pendingReplies = pending;
  const settleAllFailed = () => {
    while (pending.length > 0) {
      const settle = pending.shift();
      try {
        if (settle) settle(false);
      } catch {}
    }
  };
  // Partial reply line carried between data events. Real replies are tiny,
  // so the buffer is capped: past the cap the line stops accumulating and
  // will not parse, which settles true (the tolerant fallback below).
  let replyLine = "";
  created.on("data", (chunk) => {
    try {
      if (!chunk) return;
      for (let index = 0; index < chunk.length; index += 1) {
        const byte = typeof chunk === "string" ? chunk.charCodeAt(index) : chunk[index];
        if (byte !== 10) {
          if (replyLine.length < 512) replyLine += String.fromCharCode(byte);
          continue;
        }
        const line = replyLine;
        replyLine = "";
        // `accepted === false` is the ONLY rejecting shape. A missing field
        // or an unparseable line is a pre-`accepted`-era broker and settles
        // true — exactly the old contract.
        let verdict = true;
        try {
          verdict = JSON.parse(line).accepted !== false;
        } catch {}
        const settle = pending.shift();
        try {
          if (settle) settle(verdict);
        } catch {}
      }
    } catch {}
  });
  created.on("error", () => {
    try {
      created.destroy();
    } catch {}
    settleAllFailed();
  });
  // Fires after destroy() and after a broker-side FIN (the broker closes
  // every connection within seconds by design). Unreplied records on this
  // connection are lost for good at that point; settle them as failed so
  // their callers can retry. Idempotent with the error path above.
  created.on("close", settleAllFailed);
  return created;
}

/// Fire-and-forget publish. Returns true only when the line was actually
/// handed to a healthy socket. `onReply`, when given, is settled exactly once
/// per the connection contract above — callers that track publish state (the
/// focus declarations) must advance ONLY in a `true` settlement: a write the
/// runtime buffered while connecting, or one the broker never read, would
/// otherwise mark a lost switch as delivered until the next heartbeat.
function publish(record, onReply) {
  try {
    if (!record) return false;
    const line = JSON.stringify(record) + "\n";
    if (Buffer.byteLength(line, "utf8") > MAX_LINE_BYTES) return false;
    if (!socket || socket.destroyed) {
      const path = socketPath();
      if (!path) return false;
      socket = connectSocket(path);
    }
    // Backpressure is a drop, never a wait: if the broker stopped draining
    // (queued bytes) or stopped answering (pending replies), reset the
    // connection (the next publish lazily reconnects) and lose this record
    // rather than queue unboundedly inside the agent process. The reset
    // settles every pending reply callback as failed via the close event.
    if (socket.writableLength > MAX_QUEUED_BYTES || socket.pendingReplies.length >= MAX_PENDING_REPLIES) {
      const stale = socket;
      socket = undefined;
      try {
        stale.destroy();
      } catch {}
      return false;
    }
    socket.write(line);
    socket.pendingReplies.push(typeof onReply === "function" ? onReply : undefined);
    return true;
  } catch {
    return false;
  }
}

function closeSocket() {
  try {
    // end(), not destroy(): a final retraction may still be in the buffer,
    // and end() flushes before FIN while an unref()ed socket cannot keep the
    // process alive anyway.
    if (socket && !socket.destroyed) socket.end();
  } catch {}
  socket = undefined;
}

// ---------------------------------------------------------------------------
// Record shaping. The broker re-applies every bound on decode; truncating
// here as well keeps oversized payloads from ever crossing the wire.

function truncateBytes(value, limit) {
  if (typeof value !== "string" || value.length === 0) return undefined;
  if (Buffer.byteLength(value, "utf8") <= limit) return value;
  const bytes = Buffer.from(value, "utf8").subarray(0, limit);
  let end = bytes.length;
  // Never cut inside a UTF-8 sequence: drop continuation bytes, then a
  // dangling lead byte.
  while (end > 0 && (bytes[end - 1] & 0b11000000) === 0b10000000) end -= 1;
  if (end > 0 && (bytes[end - 1] & 0b11000000) === 0b11000000) end -= 1;
  return bytes.subarray(0, end).toString("utf8");
}

/// Safe process metadata only — identity and (for the TUI half) location of
/// the pane, mirroring what the Claude hook publisher sends. The plugin runs
/// inside the agent process, so `process.pid` IS the liveness pid the app
/// probes; there is no shim ancestry to unwind here.
function processBlock(tty) {
  const block = {
    hook_pid: process.pid,
    claude_pid: process.pid,
  };
  if (typeof tty === "string" && tty) block.tty = tty;
  const term = process.env.TERM_PROGRAM;
  if (term) block.term_program = term;
  // Inherited herdr pane identity keeps the app's existing herdr join arm
  // working for opencode panes, unchanged.
  const herdrPane = process.env.HERDR_PANE_ID;
  const herdrSocket = process.env.HERDR_SOCKET_PATH;
  if (herdrPane) block.herdr_pane_id = truncateBytes(herdrPane, MAX_PATH_BYTES);
  if (herdrSocket) block.herdr_socket_path = truncateBytes(herdrSocket, MAX_PATH_BYTES);
  return block;
}

function record(event, sessionID, fields, tty) {
  // Bounded, not scoped: namespacing ("opencode:…") is applied by the
  // RECEIVER from the agent tag, by design. The plugin sends raw ids.
  const boundedID = truncateBytes(sessionID, MAX_PATH_BYTES);
  if (!boundedID) return undefined;
  const result = {
    v: WIRE_VERSION,
    event,
    agent: AGENT,
    session_id: boundedID,
    ts: Date.now() / 1000,
    process: processBlock(tty),
  };
  if (fields && typeof fields.cwd === "string" && fields.cwd) {
    result.cwd = truncateBytes(fields.cwd, MAX_PATH_BYTES);
  }
  if (fields && typeof fields.prompt === "string" && fields.prompt) {
    result.prompt = truncateBytes(fields.prompt, MAX_PROMPT_BYTES);
  }
  if (fields && typeof fields.toolName === "string" && fields.toolName) {
    result.tool_name = truncateBytes(fields.toolName, MAX_PATH_BYTES);
  }
  if (fields && Array.isArray(fields.files) && fields.files.length > 0) {
    result.files = fields.files.slice(0, MAX_FILES_PER_RECORD).map((file) => ({
      path: truncateBytes(file.path, MAX_PATH_BYTES),
      kind: file.kind,
    }));
  }
  return result;
}

// ---------------------------------------------------------------------------
// Server half (worker realm): session content, never a TTY.

const ServerHalf = async () => {
  // session id -> directory, learned from session.created (the session's cwd
  // is not on chat.message). There is deliberately NO fallback — not even the
  // plugin-load directory: an instance-less server hosts sessions from many
  // directories, and a wrong cwd would ground dictation on the wrong repo.
  // When the directory is unknown the record goes out WITHOUT a cwd — fail
  // closed on the field, not the record.
  const directoryBySession = new Map();
  // The bounded ALLOWLIST of known top-level sessions. Parentage is only
  // observable on session.created (info.parentID marks a subagent / task-tool
  // child; nothing after that event carries it), so a session publishes only
  // while its id is in here: children are never added, and an id this half
  // never saw created — or one evicted by the bound — fails CLOSED, dropped.
  // The previous shape (a bounded blocklist of child ids) failed OPEN after
  // eviction: an evicted child's later activity looked top-level and was
  // published as the session the user is typing into. The deliberate cost of
  // the inversion: a top-level session predating this plugin's load (or past
  // the bound) stops publishing entirely — dictation abstains for it instead
  // of risking a child session's content grounding someone's prompt.
  const topLevelSessions = new Set();

  function rememberTopLevel(sessionID) {
    topLevelSessions.add(sessionID);
    if (topLevelSessions.size > MAX_TRACKED_SESSIONS) {
      const oldest = topLevelSessions.values().next().value;
      topLevelSessions.delete(oldest);
      directoryBySession.delete(oldest);
    }
  }

  function directoryFor(sessionID) {
    return directoryBySession.get(sessionID);
  }

  return {
    event: async ({ event }) => {
      try {
        const type = event && event.type;
        const properties = (event && event.properties) || {};
        if (type === "session.created") {
          const info = properties.info || {};
          if (!info.id) return;
          if (info.parentID) return; // child: never enters the allowlist
          rememberTopLevel(info.id);
          if (typeof info.directory === "string" && info.directory) {
            directoryBySession.set(info.id, info.directory);
          }
          publish(record("SessionStart", info.id, { cwd: directoryFor(info.id) }));
          return;
        }
        if (type === "session.deleted") {
          const info = properties.info || {};
          if (!info.id) return;
          if (!topLevelSessions.delete(info.id)) return;
          publish(record("SessionEnd", info.id, { cwd: directoryFor(info.id) }));
          directoryBySession.delete(info.id);
          return;
        }
        if (type === "session.idle") {
          const sessionID = properties.sessionID;
          if (!sessionID || !topLevelSessions.has(sessionID)) return;
          publish(record("Stop", sessionID, { cwd: directoryFor(sessionID) }));
        }
      } catch {}
    },

    // Fires in createUserMessage AFTER @-mention resolution and BEFORE the
    // model call; the prompt text is the join of the text parts.
    "chat.message": async (input, output) => {
      try {
        const sessionID = input && input.sessionID;
        if (!sessionID || !topLevelSessions.has(sessionID)) return;
        const parts = (output && output.parts) || [];
        const prompt = parts
          .filter((part) => part && part.type === "text" && typeof part.text === "string")
          .map((part) => part.text)
          .join("\n");
        publish(
          record("UserPromptSubmit", sessionID, {
            prompt,
            cwd: directoryFor(sessionID),
          })
        );
      } catch {}
    },

    "tool.execute.after": async (input) => {
      try {
        const sessionID = input && input.sessionID;
        const tool = input && input.tool;
        if (!sessionID || !topLevelSessions.has(sessionID)) return;
        // File-bearing tools only, mirroring the Claude plugin's
        // Read|Edit|Write matcher. Everything else (bash, grep, glob) carries
        // command strings, not file touches.
        const kinds = { read: "read", edit: "edited", write: "edited" };
        const kind = kinds[tool];
        if (!kind) return;
        const filePath = input.args && typeof input.args.filePath === "string" ? input.args.filePath : undefined;
        if (!filePath) return;
        publish(
          record("PostToolUse", sessionID, {
            toolName: tool,
            files: [{ path: filePath, kind }],
            cwd: directoryFor(sessionID),
          })
        );
      } catch {}
    },

    dispose: async () => {
      try {
        closeSocket();
      } catch {}
    },
  };
};

// ---------------------------------------------------------------------------
// TUI half (main realm): the pane's TTY plus which session it displays.

/// This process's controlling terminal, read child-free from fd 0 — the TUI
/// realm owns the pane by construction (it renders into it). Positive
/// verification or abstain: on macOS the candidate device's rdev must match
/// fd 0's before it is ever published.
function ownTTY() {
  try {
    if (!isatty(0)) return undefined;
    if (process.platform === "linux") {
      const link = fs.readlinkSync("/proc/self/fd/0");
      return link.startsWith("/dev/") ? link : undefined;
    }
    if (process.platform === "darwin") {
      const stat = fs.fstatSync(0);
      if (!stat.isCharacterDevice()) return undefined;
      // macOS device numbers: minor is the low 24 bits; pseudo-terminals are
      // named /dev/ttysNNN, zero-padded to three digits.
      const minor = stat.rdev & 0xffffff;
      const candidate = "/dev/ttys" + String(minor).padStart(3, "0");
      return fs.statSync(candidate).rdev === stat.rdev ? candidate : undefined;
    }
  } catch {}
  return undefined;
}

const TuiHalf = async (api) => {
  const tty = ownTTY();
  if (!tty) return; // No pane evidence, nothing to declare. Ever.

  // opencode's TUI exposes the displayed session only as the
  // `api.route.current` getter (@opencode-ai/plugin/tui: TuiRouteCurrent) —
  // no route-change event exists on any bus in 1.17.x, so event-driven focus
  // is approximated from both ends: a half-second sample of the getter (pure
  // in-memory read, no IO) bounds switch latency, and every bus event
  // triggers an immediate resample so switches that coincide with session
  // activity are caught event-fast. Leaving the session view publishes an
  // explicit retraction (FocusCleared) instead of waiting for the registry's
  // TTL.
  //
  // Publish state advances ONLY when the broker's reply line for that exact
  // record arrives (publish's onReply contract — one reply per record, in
  // order). A bare successful write proves nothing: the runtime buffers
  // writes while the dial is still in flight, and the broker resets
  // connections routinely (8 records / 2s deadline), so advancing on the
  // write would mark a lost declaration as delivered — and a lost RETRACTION
  // as retracted — and heartbeat-suppress the repair for 20 seconds. On any
  // failed settlement the local state is left alone, so the next sample
  // simply retries. One focus record is in flight at a time; its settlement
  // (reply, connection error, or close — the broker's own deadline bounds
  // the quiet case) re-enables sampling.
  //
  // The reply also carries the REGISTRY's verdict (`accepted`, broker-side
  // ClaudeContextBroker.handle): a FocusChanged racing ahead of its session
  // record — the registry refuses declarations for sessions it does not
  // know — settles false like any lost write, so the next sample retries
  // instead of the 20s heartbeat suppressing the repair while dictation
  // grounds on the previous session. Old brokers omit the field: settle true.
  let lastSession;
  let lastSentAt = 0;
  let inflight = false;

  function sample() {
    try {
      const route = api.route && api.route.current;
      const sessionID =
        route && route.name === "session" && route.params && typeof route.params.sessionID === "string"
          ? route.params.sessionID
          : undefined;
      if (inflight) return;
      const nowMillis = Date.now();
      if (!sessionID) {
        if (!lastSession) return;
        const cleared = lastSession;
        inflight = publish(record("FocusCleared", cleared, undefined, tty), (replied) => {
          inflight = false;
          if (replied && lastSession === cleared) {
            lastSession = undefined;
            lastSentAt = 0;
          }
        });
        return;
      }
      if (sessionID === lastSession && nowMillis - lastSentAt < FOCUS_HEARTBEAT_MS) return;
      inflight = publish(record("FocusChanged", sessionID, undefined, tty), (replied) => {
        inflight = false;
        if (replied) {
          lastSession = sessionID;
          lastSentAt = nowMillis;
        }
      });
    } catch {}
  }

  const timer = setInterval(sample, FOCUS_POLL_MS);
  if (timer && typeof timer.unref === "function") timer.unref();

  const unsubscribes = [];
  if (api.event && typeof api.event.on === "function") {
    // Resample-on-event: TuiEventBus.on requires a concrete type per
    // subscription, so cover the events a session switch tends to ride on.
    for (const type of [
      "session.created",
      "session.deleted",
      "session.status",
      "session.idle",
      "message.updated",
    ]) {
      try {
        unsubscribes.push(api.event.on(type, sample));
      } catch {}
    }
  }

  if (api.lifecycle && typeof api.lifecycle.onDispose === "function") {
    api.lifecycle.onDispose(() => {
      try {
        clearInterval(timer);
        for (const unsubscribe of unsubscribes) {
          try {
            unsubscribe();
          } catch {}
        }
        if (lastSession) {
          publish(record("FocusCleared", lastSession, undefined, tty));
          lastSession = undefined;
        }
        closeSocket();
      } catch {}
    });
  }
};

// ---------------------------------------------------------------------------
// One default export per realm — see the header for why this split is the
// TUI-ownership gate, not a convenience.

export default isMainThread
  ? { id: "localvoxtral", tui: TuiHalf }
  : { id: "localvoxtral", server: ServerHalf };
