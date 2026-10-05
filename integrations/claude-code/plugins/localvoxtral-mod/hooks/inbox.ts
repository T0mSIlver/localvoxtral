// The Inbox pane's reading of `localvoxtral capture list --json` (#1694).
// The CLI's JSON is the contract (Sources/ClaudeContextWire/AgentCLIWire.swift,
// `AgentCLICaptures`); the pane shows it and never files anything: filing
// stays in the app (#725). What touches `$` lives in register.tsx.

import type { InboxCapture, InboxView } from '../types'

export const INBOX_PANE = 'localvoxtral-inbox'

/** The CLI's exit status when the app does not run. */
const NOT_RUNNING = 3

/** The pane's view of one `capture list` run. */
export function inboxOf(run: { exitCode: number; stdout: string }, at: number): InboxView {
  if (run.exitCode === NOT_RUNNING) return { status: 'failed', reason: 'localvoxtral is not running.' }
  try {
    const answer = JSON.parse(run.stdout) as {
      ok?: unknown
      captures?: { inboxAvailable?: unknown; captures?: unknown }
    }
    if (answer.ok !== true || typeof answer.captures !== 'object' || answer.captures === null) {
      return { status: 'failed', reason: 'localvoxtral could not list the Inbox.' }
    }
    if (answer.captures.inboxAvailable !== true) return { status: 'failed', reason: 'The Inbox is not available.' }
    const list = Array.isArray(answer.captures.captures) ? answer.captures.captures : []
    const captures: InboxCapture[] = []
    for (const value of list) {
      if (typeof value !== 'object' || value === null) continue
      const { id, title, kind, state, capturedAt } = value as Record<string, unknown>
      const time = typeof capturedAt === 'string' ? Date.parse(capturedAt) : NaN
      if (typeof id !== 'string' || typeof title !== 'string' || typeof state !== 'string' || Number.isNaN(time)) continue
      captures.push({ id, title, state, capturedAt: time, ...(typeof kind === 'string' ? { kind } : {}) })
    }
    return { status: 'ready', captures, at }
  } catch {
    return { status: 'failed', reason: 'localvoxtral could not list the Inbox.' }
  }
}

/** How long ago, as `capture list` prints it: 30m, 2h, 1d. */
export function age(capturedAt: number, now: number): string {
  const minutes = Math.max(0, Math.floor((now - capturedAt) / 60000))
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h`
  return `${Math.floor(hours / 24)}d`
}

/** The dim line under a capture's title: kind, state, age. */
export function detailOf(capture: InboxCapture, now: number): string {
  return [capture.kind, capture.state, age(capture.capturedAt, now)].filter(part => part !== undefined).join(' · ')
}
