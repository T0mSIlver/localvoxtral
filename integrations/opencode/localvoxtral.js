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
//     socket, unref()ed, fire-and-forget writes, broker replies discarded.
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

// The registry treats a focus declaration as stale after two minutes
// (ClaudeRegistryLimits.defaultFocusDeclarationTTL); a 20-second heartbeat
// keeps a steadily displayed session comfortably fresh across lost writes.
const FOCUS_POLL_MS = 2000;
const FOCUS_HEARTBEAT_MS = 20000;

// Bounds on in-process caches, so a very long-lived opencode cannot grow.
const MAX_TRACKED_SESSIONS = 64;

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
// Publisher — lazy connection, fire and forget, replies discarded.
//
// The broker serves short connections (whole-connection read deadline, a
// per-connection record cap), so the socket naturally closes between bursts;
// the next publish reconnects. Writes issued right after createConnection are
// buffered by the runtime until the connect completes — nothing here ever
// blocks a hook on the dial.

let socket;

function publish(record) {
  try {
    if (!record) return;
    const line = JSON.stringify(record) + "\n";
    if (Buffer.byteLength(line, "utf8") > MAX_LINE_BYTES) return;
    if (!socket || socket.destroyed) {
      const path = socketPath();
      if (!path) return;
      socket = net.createConnection(path);
      socket.unref();
      // Broker replies (marker lines for Claude publishers) are read and
      // dropped: this plugin has no title channel and must never surface a
      // byte anywhere a terminal could see it.
      socket.on("data", () => {});
      socket.on("error", () => {
        try {
          socket.destroy();
        } catch {}
      });
    }
    socket.write(line);
  } catch {}
}

function closeSocket() {
  try {
    if (socket && !socket.destroyed) socket.destroy();
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
  const scopedID = truncateBytes(sessionID, MAX_PATH_BYTES);
  if (!scopedID) return undefined;
  const result = {
    v: WIRE_VERSION,
    event,
    agent: AGENT,
    session_id: scopedID,
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

const ServerHalf = async (input) => {
  // session id -> directory, learned from session.created (the session's cwd
  // is not on chat.message). The plugin-load directory is the only fallback;
  // when neither is known the record goes out WITHOUT a cwd — fail closed on
  // the field, not the record.
  const directoryBySession = new Map();
  // Subagent (task tool) sessions carry parentID; their lifecycle must not
  // masquerade as user-facing sessions (same rule herdr's plugin applies).
  const childSessions = new Set();
  const fallbackDirectory =
    input && typeof input.directory === "string" && input.directory ? input.directory : undefined;

  function remember(map, key, value) {
    map.set(key, value);
    if (map.size > MAX_TRACKED_SESSIONS) {
      const oldest = map.keys().next().value;
      map.delete(oldest);
    }
  }

  function directoryFor(sessionID) {
    return directoryBySession.get(sessionID) || fallbackDirectory;
  }

  return {
    event: async ({ event }) => {
      try {
        const type = event && event.type;
        const properties = (event && event.properties) || {};
        if (type === "session.created") {
          const info = properties.info || {};
          if (!info.id) return;
          if (info.parentID) {
            childSessions.add(info.id);
            if (childSessions.size > MAX_TRACKED_SESSIONS) {
              childSessions.delete(childSessions.values().next().value);
            }
            return;
          }
          if (typeof info.directory === "string" && info.directory) {
            remember(directoryBySession, info.id, info.directory);
          }
          publish(record("SessionStart", info.id, { cwd: directoryFor(info.id) }));
          return;
        }
        if (type === "session.deleted") {
          const info = properties.info || {};
          if (!info.id) return;
          if (childSessions.delete(info.id)) return;
          publish(record("SessionEnd", info.id, { cwd: directoryFor(info.id) }));
          directoryBySession.delete(info.id);
          return;
        }
        if (type === "session.idle") {
          const sessionID = properties.sessionID;
          if (!sessionID || childSessions.has(sessionID)) return;
          publish(record("Stop", sessionID, { cwd: directoryFor(sessionID) }));
        }
      } catch {}
    },

    // Fires in createUserMessage AFTER @-mention resolution and BEFORE the
    // model call; the prompt text is the join of the text parts.
    "chat.message": async (input, output) => {
      try {
        const sessionID = input && input.sessionID;
        if (!sessionID || childSessions.has(sessionID)) return;
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
        if (!sessionID || childSessions.has(sessionID)) return;
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

  // opencode's TUI exposes the displayed session as api.route.current
  // (@opencode-ai/plugin/tui: TuiRouteCurrent) and publishes no route-change
  // event on any bus, so the getter is sampled on an unref()ed timer — a pure
  // in-memory read, no IO. A change publishes immediately; a heartbeat keeps
  // the declaration fresh; leaving the session view (home) simply stops the
  // heartbeat and the app's registry expires the declaration.
  let lastSession;
  let lastSentAt = 0;
  const timer = setInterval(() => {
    try {
      const route = api.route && api.route.current;
      const sessionID =
        route && route.name === "session" && route.params && typeof route.params.sessionID === "string"
          ? route.params.sessionID
          : undefined;
      if (!sessionID) {
        lastSession = undefined;
        return;
      }
      const nowMillis = Date.now();
      if (sessionID === lastSession && nowMillis - lastSentAt < FOCUS_HEARTBEAT_MS) return;
      lastSession = sessionID;
      lastSentAt = nowMillis;
      publish(record("FocusChanged", sessionID, undefined, tty));
    } catch {}
  }, FOCUS_POLL_MS);
  if (timer && typeof timer.unref === "function") timer.unref();

  if (api.lifecycle && typeof api.lifecycle.onDispose === "function") {
    api.lifecycle.onDispose(() => {
      try {
        clearInterval(timer);
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
