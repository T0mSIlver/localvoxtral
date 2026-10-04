// The channel from a remote host (#1412): the same messages and replies as
// the publisher's `--attach`, carried by a long poll on the app's listener
// through the host's ssh forward (the wire is
// Sources/ClaudeContextWire/ClaudeRemoteModWire.swift). What touches `$`
// lives in register.tsx.
//
// The host token opens the listener's door, as it does for the command hooks.
// A process that squats the forward port gets that token, so it proves
// nothing about who answers: every request and every answer also carries an
// HMAC under the host's channel key, which setup stores in the plugin's
// config and which never crosses the tunnel.

import { hmacHex } from './hmac'

export const POLL_PATH = '/v1/mod/poll'
export const REPLY_PATH = '/v1/mod/reply'
export const PROOF_HEADER = 'X-Lvx-Mod-Proof'

/** The app holds a poll this long when it has nothing to send. */
export const POLL_HOLD_MS = 25000
// `$.http.fetch` has no timeout: a poll the app has not answered by then is
// abandoned as a dead forward.
export const POLL_ABANDON_MS = 30000
// After a failed dial: each dial at a forward with no app behind it prints a
// `connect_to` line on the Mac's terminal, so the mod waits as long as
// post.sh does, unless a hook reaches the app sooner.
export const BACKOFF_MS = 300000
export const STAMP_CHECK_MS = 5000
// Another process of this session holds the channel, or no hook has named
// the session yet: ask again later.
export const BUSY_RETRY_MS = 10000

/** The port the forward binds on this host, by post.sh's rule. */
export function remotePort(raw: unknown): number {
  const text = typeof raw === 'string' ? raw : ''
  if (!/^[1-9][0-9]{0,4}$/.test(text)) return 8473
  const port = Number(text)
  return port >= 1024 && port <= 65535 ? port : 8473
}

/** A host token as the app mints it (base64url, 16 to 128 characters). */
export function isToken(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{16,128}$/.test(value)
}

/** A channel key as setup stores it: 64 lowercase hex digits. */
export function isChannelKey(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value)
}

/** The proof a request body carries. */
export function requestProof(key: string, body: string): string {
  return hmacHex(key, `lvx-mod-request-v1\n${body}`)
}

/** The proof the app's answer to a poll carries, bound to the poll's nonce. */
export function answerProof(key: string, nonce: string, body: string): string {
  return hmacHex(key, `lvx-mod-answer-v1\n${nonce}\n${body}`)
}

export type PollRequest = {
  mod_poll: number
  session_id: string
  /** This load of the module: a second process of the session is refused. */
  instance: string
  nonce: string
  /** The last line this attach delivered; the app drops it and those before. */
  acked: number
}

/**
 * One poll's answer: the attach it belongs to, the number of its first line,
 * and the lines, each one message as the publisher would print it.
 */
export type PollAnswer = { attach: number; first: number; lines: string[] }

export function parsePollAnswer(text: string): PollAnswer | null {
  try {
    const value: unknown = JSON.parse(text)
    if (typeof value !== 'object' || value === null) return null
    const { attach, first, lines } = value as Record<string, unknown>
    if (!Number.isInteger(attach) || !Number.isInteger(first) || !Array.isArray(lines)) return null
    if (!lines.every(line => typeof line === 'string')) return null
    return { attach: attach as number, first: first as number, lines: lines as string[] }
  } catch {
    return null
  }
}

/**
 * When post.sh last reached the app, from its `hook-status` stamp
 * (`ok <epoch seconds>`), in milliseconds; undefined for any other state.
 */
export function hookOKAt(stamp: string): number | undefined {
  const match = /^ok ([0-9]{1,12})\s*$/.exec(stamp)
  return match === null ? undefined : Number(match[1]) * 1000
}

/** `bytes` random bytes as hex. */
export function randomHex(bytes: number): string {
  const values = crypto.getRandomValues(new Uint8Array(bytes))
  let out = ''
  for (const value of values) out += value.toString(16).padStart(2, '0')
  return out
}
