// The mod's end of the channel from the app (#1408; the wire is
// Sources/ClaudeContextWire/ClaudeModChannelWire.swift). The publisher's
// `--attach` mode holds the connection and prints each message from the app
// as one JSON line; the mod answers each with a `--mod-reply` run. What
// touches `$` lives in register.ts: the engine follows `$` into no import.

export const WIRE_VERSION = 1

export type ChannelMessage = {
  mod_message: number
  kind: string
  id: string
  text?: string
  phase?: string
  /** For `state`: the other sessions waiting for the person (#1695). */
  waiting?: string[]
  seq?: number
}

/** What a fork cost, in the API's spelling. */
export type ChannelUsage = {
  input_tokens: number
  cache_creation_input_tokens: number
  cache_read_input_tokens: number
  output_tokens: number
}

export type ChannelReply = {
  mod_reply: number
  session_id: string
  id: string
  ok: boolean
  reason?: string
  text?: string
  cursor?: number
  usage?: ChannelUsage
  submitted?: boolean
  queued?: boolean
  seq?: number
}

/** The mod's word that its session ends (#1646), sent like a reply. */
export type ChannelBye = { mod_bye: number; session_id: string }

/** Whether the mod did what a message asked, why not, and any answer. */
export type Outcome = {
  ok: boolean
  reason?: string
  text?: string
  cursor?: number
  usage?: ChannelUsage
  submitted?: boolean
  queued?: boolean
  seq?: number
}

/** The refusal of a request issued for a session the process has left. */
export const SESSION_CHANGED = 'session_changed'

/** The refusal of an `abort` while no main-loop turn runs. */
export const NO_TURN = 'no_turn'

// A child that ends sooner than this after it started is a publisher that
// does not know `--attach` (an app older than the mod): stop asking it.
export const SHORTEST_LIFE_MS = 5000
export const RESTART_DELAY_MS = 30000
// After a `/clear` the process goes on under a new session id, which
// `$.session.id()` answers only once `session.end` is over: how often and how
// long the channel looks for it before it attaches again.
export const NEW_SESSION_POLL_MS = 500
export const NEW_SESSION_WAIT_MS = 10000
// A band nobody updated for this long belongs to a dictation whose end never
// arrived (the app quit mid-dictation): it clears itself. The app sends an
// unchanged band again every 10 s, so a pause or a long polish keeps it.
export const BAND_STALE_MS = 30000

// How much of the draft a `draft` reply carries around the cursor, in UTF-16
// code units: what polish reads, and far under the wire's 64 KiB line even
// with every character escaped.
export const DRAFT_BEFORE_CURSOR = 3000
export const DRAFT_AFTER_CURSOR = 1000

/**
 * The prompt box as a `draft` reply carries it: the text around the cursor,
 * cut without splitting a surrogate pair, and the cursor's offset into it.
 */
export function draftOf(box: { text: string; cursor: number }): { text: string; cursor: number } {
  const cursor = Math.min(Math.max(0, box.cursor), box.text.length)
  let start = Math.max(0, cursor - DRAFT_BEFORE_CURSOR)
  let end = Math.min(box.text.length, cursor + DRAFT_AFTER_CURSOR)
  if (start > 0 && isLowSurrogate(box.text.charCodeAt(start))) start += 1
  if (end < box.text.length && isLowSurrogate(box.text.charCodeAt(end))) end -= 1
  return { text: box.text.slice(start, end), cursor: cursor - start }
}

function isLowSurrogate(code: number): boolean {
  return code >= 0xdc00 && code <= 0xdfff
}

// How long a `send` waits for its submit before it answers `queued`: a
// plugin's submit resolves only once the running turn ends (measured on
// Claude Code 2.1.287), and the app gives the reply 5 s.
export const SUBMIT_ANSWER_MS = 1500

/**
 * Why a box cannot be submitted as typed, or undefined when it can: a
 * plugin's submit is text alone, so a paste or image placeholder would go
 * as its label and a `@file` mention unexpanded, and a slash command or a
 * `!` shell line is the keyboard's to run. The app types those instead.
 */
export function needsKeys(box: string): string | undefined {
  if (/\[(Pasted text|Image) #\d+/.test(box)) return 'placeholder'
  if (/^\s*[/!]/.test(box)) return 'command'
  if (/(^|\s)@\S/.test(box)) return 'mention'
  return undefined
}

/** The box after `text` goes in at the cursor, as an `insert` fill puts it. */
export function insertedAt(box: { text: string; cursor: number }, text: string): string {
  const cursor = Math.min(Math.max(0, box.cursor), box.text.length)
  return box.text.slice(0, cursor) + text + box.text.slice(cursor)
}

/** The band a `state` message asks for; null clears it. */
export function bandOf(message: ChannelMessage): { phase: 'listening' | 'finishing'; text: string } | null {
  if (message.phase !== 'listening' && message.phase !== 'finishing') return null
  return { phase: message.phase, text: message.text ?? '' }
}

/**
 * The band's line about the other sessions waiting for the person, at most
 * `columns` wide; null when none does. Names only (#717).
 */
export function waitingLine(names: string[], columns: number): string | null {
  if (names.length === 0) return null
  const [first, second] = names
  const line =
    names.length === 1
      ? `${first} waits for you`
      : names.length === 2
        ? `${first} and ${second} wait for you`
        : `${first} and ${names.length - 1} others wait for you`
  return line.length > columns ? `${line.slice(0, Math.max(1, columns - 1))}…` : line
}

/** Parses one line, or null for anything that is not a message of this wire. */
export function parseMessage(line: string): ChannelMessage | null {
  try {
    const value: unknown = JSON.parse(line)
    if (typeof value !== 'object' || value === null) return null
    const { mod_message, kind, id, text, phase, waiting, seq } = value as Record<string, unknown>
    if (mod_message !== WIRE_VERSION || typeof kind !== 'string' || typeof id !== 'string') return null
    return {
      mod_message,
      kind,
      id,
      ...(typeof text === 'string' ? { text } : {}),
      ...(typeof phase === 'string' ? { phase } : {}),
      ...(Array.isArray(waiting) ? { waiting: waiting.filter(name => typeof name === 'string') } : {}),
      ...(typeof seq === 'number' && Number.isInteger(seq) ? { seq } : {}),
    }
  } catch {
    return null
  }
}

/**
 * One Live Auto-Paste stream's appends (#1645), in the order the app wrote
 * them: each fills only when it is the next one, so a lost or late delta
 * ends the stream instead of landing out of order, and so does a fill the
 * box refused. An `ack` reads how many filled and starts the next stream.
 */
export class AppendStream {
  private filled = 0
  private ended = false

  /** Whether the append numbered `seq` may fill now. */
  admits(seq: number | undefined): boolean {
    if (this.ended) return false
    if (seq !== this.filled + 1) {
      this.ended = true
      return false
    }
    return true
  }

  /** What became of the append `admits` let through. */
  settle(isFilled: boolean): void {
    if (isFilled) this.filled += 1
    else this.ended = true
  }

  /** How many filled, in order from the first; the next append starts at 1. */
  ack(): number {
    const filled = this.filled
    this.filled = 0
    this.ended = false
    return filled
  }
}
