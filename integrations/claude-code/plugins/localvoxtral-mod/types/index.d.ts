/** What the band above the prompt shows (#1411); null draws nothing. */
export type Band = { phase: 'listening' | 'finishing'; text: string } | null

/** One capture as the Inbox pane lists it (#1694). */
export type InboxCapture = { id: string; title: string; kind?: string; state: string; capturedAt: number }

/** What the Inbox pane draws. */
export type InboxView =
  | { status: 'loading' }
  | { status: 'ready'; captures: InboxCapture[]; at: number }
  | { status: 'failed'; reason: string }

declare module 'claude-code' {
  interface PluginState {
    'localvoxtral-mod': { band: Band; waiting: string[]; inbox: InboxView }
  }
}
