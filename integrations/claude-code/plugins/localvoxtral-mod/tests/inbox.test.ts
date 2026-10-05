import type { RenderPropsOf } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import { age, inboxOf } from '../hooks/inbox'

const CLI = '/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-cli'
const STARTED = { surface: 'terminal', isInteractive: true, cwd: '/work/reach' } as const
const PANE: RenderPropsOf['Pane'] = {
  title: 'Inbox',
  isFocused: false,
  bodyColumns: 40,
  placement: 'inline',
  scroll: { top: 0, height: 0 },
  view: {},
} as unknown as RenderPropsOf['Pane']
const NOW = Date.parse('2026-10-04T12:00:00Z')

const listed = (captures: object[], inboxAvailable = true) =>
  `${JSON.stringify({ cli: 1, ok: true, captures: { inboxAvailable, captures } })}\n`

const HERDR = {
  id: '3f9c2a1b-0000-4000-8000-000000000001',
  capturedAt: '2026-10-04T10:00:00Z',
  kind: 'issue',
  state: 'ready',
  title: 'Queue dictation into a busy herdr pane',
  project: { key: '/work/reach', name: 'reach' },
}
const NOTE = { id: '81d04e77-0000-4000-8000-000000000002', capturedAt: '2026-10-02T12:00:00Z', state: 'drafting', title: 'check the vLLM numbers' }

type Run = { argv: readonly string[]; stdin?: string }

/** A session whose app answers `capture list` with `stdout`. */
function session(on: Parameters<Parameters<typeof test>[1]>[1], stdout: string, exitCode = 0) {
  mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/Users/tom' })
  const runs: Run[] = []
  const opened: string[] = []
  const toasts: string[] = []
  const commands: string[] = []
  on('command.register', ($, e) => {
    commands.push(e.name)
    return { value: { command: e.name } }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('session.cwd', () => ({ value: '/work/reach' }))
  on('settings.read', () => ({ value: {} }))
  on('fs.exists', ($, e) => ({ value: e.path === CLI }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.open', ($, e) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.render', ($, e) => $.ui.resolve(e).Box({}))
  on('process.run', ($, e) => {
    runs.push({ argv: e.argv, stdin: e.init?.stdin })
    const isList = e.argv[1] === 'capture' && e.argv[2] === 'list'
    return {
      value: {
        exitCode: isList ? exitCode : 0,
        stdout: isList ? stdout : '{"cli":1,"ok":true}\n',
        stderr: '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }
  })
  return { runs, opened, toasts, commands }
}

describe('inbox', () => {
  for (const surface of ['terminal', 'desktop'] as const) {
    test(`/inbox lists this project's captures in a pane, each opening in the app: ${surface}`, async ($, on) => {
      const seen = session(on, listed([HERDR, NOTE]))
      await $.session.start(STARTED)
      expect(seen.commands).toEqual(['inbox'])

      const ran = await $.command.run({ command: 'inbox' })
      expect(ran.text).toBe('Opened the Inbox pane.')
      expect(ran.context).toBeUndefined()
      expect(seen.opened).toEqual(['localvoxtral-inbox'])
      expect(seen.runs.map(run => run.argv)).toEqual([[CLI, 'capture', 'list', '--project', '/work/reach', '--json']])

      const ui = await $.ui.mount({
        plugin: 'localvoxtral-mod',
        surface,
        component: 'Pane',
        props: PANE,
        requestId: 'localvoxtral-inbox',
      })
      expect(await ui.find({ type: 'Text', text: 'Queue dictation into a busy herdr pane' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'issue · ready · 2h ' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'drafting · 2d ' })).toBeDefined()

      await ui.press({ key: `open-${HERDR.id}` })
      expect(seen.runs.at(-1)?.argv).toEqual([CLI, 'capture', 'open', HERDR.id, '--json'])
      expect(seen.toasts).toEqual([])
      await ui.unmount()
    })
  }

  test('an empty list says so', async ($, on) => {
    session(on, listed([]))
    await $.session.start(STARTED)
    await $.command.run({ command: 'inbox' })
    const ui = await $.ui.mount({
      plugin: 'localvoxtral-mod',
      surface: 'terminal',
      component: 'Pane',
      props: PANE,
      requestId: 'localvoxtral-inbox',
    })
    expect(await ui.find({ type: 'Text', text: 'No captures for this project.' })).toBeDefined()
    await ui.unmount()
  })

  test('an app that does not run is named, not shown as an empty Inbox', async ($, on) => {
    session(on, '', 3)
    await $.session.start(STARTED)
    await $.command.run({ command: 'inbox' })
    const ui = await $.ui.mount({
      plugin: 'localvoxtral-mod',
      surface: 'terminal',
      component: 'Pane',
      props: PANE,
      requestId: 'localvoxtral-inbox',
    })
    expect(await ui.find({ type: 'Text', text: 'localvoxtral is not running.' })).toBeDefined()
    await ui.unmount()
  })

  test('inboxOf reads the CLI line and skips what it cannot read', () => {
    expect(inboxOf({ exitCode: 0, stdout: listed([HERDR, { id: 4 }]) }, NOW)).toEqual({
      status: 'ready',
      at: NOW,
      captures: [
        { id: HERDR.id, title: HERDR.title, kind: 'issue', state: 'ready', capturedAt: Date.parse(HERDR.capturedAt) },
      ],
    })
    expect(inboxOf({ exitCode: 0, stdout: listed([], false) }, NOW)).toEqual({
      status: 'failed',
      reason: 'The Inbox is not available.',
    })
    expect(inboxOf({ exitCode: 1, stdout: '{"cli":1,"ok":false}' }, NOW).status).toBe('failed')
    expect(age(NOW - 30 * 60000, NOW)).toBe('30m')
  })
})
