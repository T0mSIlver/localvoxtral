// The mod's end of the channel from the app (#1408; the wire is
// Sources/ClaudeContextWire/ClaudeModChannelWire.swift). The publisher's
// `--attach` mode holds the connection and prints each message from the app
// as one JSON line; the mod answers each with a `--mod-reply` run. What
// touches `$` lives in register.ts: the engine follows `$` into no import.

export const WIRE_VERSION = 1

export type ChannelMessage = { mod_message: number; kind: string; id: string; text?: string }

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
  usage?: ChannelUsage
}

/** Whether the mod did what a message asked, why not, and any answer. */
export type Outcome = { ok: boolean; reason?: string; text?: string; usage?: ChannelUsage }

// A child that ends sooner than this after it started is a publisher that
// does not know `--attach` (an app older than the mod): stop asking it.
export const SHORTEST_LIFE_MS = 5000
export const RESTART_DELAY_MS = 30000

/** Parses one line, or null for anything that is not a message of this wire. */
export function parseMessage(line: string): ChannelMessage | null {
  try {
    const value: unknown = JSON.parse(line)
    if (typeof value !== 'object' || value === null) return null
    const { mod_message, kind, id, text } = value as Record<string, unknown>
    if (mod_message !== WIRE_VERSION || typeof kind !== 'string' || typeof id !== 'string') return null
    return typeof text === 'string' ? { mod_message, kind, id, text } : { mod_message, kind, id }
  } catch {
    return null
  }
}
