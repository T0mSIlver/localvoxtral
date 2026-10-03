/** What the band above the prompt shows (#1411); null draws nothing. */
export type Band = { phase: 'listening' | 'finishing'; text: string } | null

declare module 'claude-code' {
  interface PluginState {
    'localvoxtral-mod': { band: Band }
  }
}
