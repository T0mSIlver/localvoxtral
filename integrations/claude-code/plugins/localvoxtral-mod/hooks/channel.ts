// The mod's end of the channel from the app (#1408; the wire is
// Sources/ClaudeContextWire/ClaudeModChannelWire.swift). The publisher's
// `--attach` mode holds the connection and prints each message from the app
// as one JSON line; the mod answers each with a `--mod-reply` run. What
// touches `$` lives in register.ts: the engine follows `$` into no import.

export const WIRE_VERSION = 1

export type ChannelMessage = { mod_message: number; kind: string; id: string; text?: string; phase?: string }

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
}

/** The mod's word that its session ends (#1646), sent like a reply. */
export type ChannelBye = { mod_bye: number; session_id: string }

/** Whether the mod did what a message asked, why not, and any answer. */
export type Outcome = { ok: boolean; reason?: string; text?: string; cursor?: number; usage?: ChannelUsage }

/** The refusal of a request issued for a session the process has left. */
export const SESSION_CHANGED = 'session_changed'

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

/** The band a `state` message asks for; null clears it. */
export function bandOf(message: ChannelMessage): { phase: 'listening' | 'finishing'; text: string } | null {
  if (message.phase !== 'listening' && message.phase !== 'finishing') return null
  return { phase: message.phase, text: message.text ?? '' }
}

/** Parses one line, or null for anything that is not a message of this wire. */
export function parseMessage(line: string): ChannelMessage | null {
  try {
    const value: unknown = JSON.parse(line)
    if (typeof value !== 'object' || value === null) return null
    const { mod_message, kind, id, text, phase } = value as Record<string, unknown>
    if (mod_message !== WIRE_VERSION || typeof kind !== 'string' || typeof id !== 'string') return null
    return {
      mod_message,
      kind,
      id,
      ...(typeof text === 'string' ? { text } : {}),
      ...(typeof phase === 'string' ? { phase } : {}),
    }
  } catch {
    return null
  }
}
