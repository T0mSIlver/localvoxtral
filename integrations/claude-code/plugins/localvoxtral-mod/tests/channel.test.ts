import type { ProcessSpawnChunk, ProcessSpawnResult } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import { parseMessage } from '../hooks/channel'

const PUBLISHER = '/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
const STARTED = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const
const EXITED: ProcessSpawnResult = { code: 0, signal: null }

describe('channel', () => {
  test('answers each message the app sends with a reply for this session', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    const spawned: (readonly string[])[] = []
    const replies: unknown[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('settings.read', () => ({ value: {} }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('ui.status', () => ({ value: undefined }))
    on('process.spawn', async function* ($, e): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
      spawned.push(e.argv)
      // Split mid-line, as a pipe may deliver it; one line of another
      // version and one of an unknown kind among them.
      yield { stream: 'stdout', text: '{"mod_message":1,"kind":"ping","id":"a"}\n{"mod_mes' }
      yield { stream: 'stdout', text: 'sage":2,"kind":"ping","id":"b"}\n{"mod_message":1,"kind":"later","id":"c"}\n' }
      await clock.sleep(60000)
      return { value: EXITED }
    })
    on('process.run', ($, e) => {
      if (e.argv[1] === '--mod-reply') replies.push(JSON.parse(e.init?.stdin ?? ''))
      return {
        value: { exitCode: 0, stdout: 'lvx ●', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
      }
    })

    await $.session.start(STARTED)
    await clock.advance(1000)

    expect(spawned).toEqual([[PUBLISHER, '--attach', '--session', 'sess-1']])
    expect(replies).toEqual([
      { mod_reply: 1, session_id: 'sess-1', id: 'a', ok: true },
      { mod_reply: 1, session_id: 'sess-1', id: 'c', ok: false, reason: 'unknown_kind' },
    ])
  })

  for (const [label, box, expected] of [
    ['the box takes it', { isFilled: true }, { ok: true }],
    ['a hook keeps it out', { isFilled: false }, { ok: false, reason: 'refused' }],
  ] as const) {
    test(`a fill puts the text at the cursor and says whether it landed: ${label}`, async ($, on) => {
      const clock = mock.clock(on)
      mock.env(on, { HOME: '/Users/tom' })
      const fills: { text: string; mode: string }[] = []
      const replies: unknown[] = []
      on('session.start', ($, e) => ({ cwd: e.cwd }))
      on('session.id', () => ({ value: 'sess-1' }))
      on('settings.read', () => ({ value: {} }))
      on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
      on('ui.status', () => ({ value: undefined }))
      on('prompt.fill', ($, e) => {
        fills.push({ text: e.text, mode: e.mode })
        return box
      })
      on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
        yield { stream: 'stdout', text: '{"id":"f","kind":"fill","mod_message":1,"text":"run the tests"}\n' }
        await clock.sleep(60000)
        return { value: EXITED }
      })
      on('process.run', ($, e) => {
        if (e.argv[1] === '--mod-reply') replies.push(JSON.parse(e.init?.stdin ?? ''))
        return {
          value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
        }
      })

      await $.session.start(STARTED)
      await clock.advance(1000)

      expect(fills).toEqual([{ text: 'run the tests', mode: 'insert' }])
      expect(replies).toEqual([{ mod_reply: 1, session_id: 'sess-1', id: 'f', ...expected }])
    })
  }

  test('a publisher that exits at once is not started again', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    let spawns = 0
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('settings.read', () => ({ value: {} }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('ui.status', () => ({ value: undefined }))
    on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
      spawns += 1
      return { value: EXITED }
    })
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }))

    await $.session.start(STARTED)
    await clock.advance(120000)

    expect(spawns).toBe(1)
  })

  test('parseMessage takes only this version of the wire', () => {
    expect(parseMessage('{"mod_message":1,"kind":"ping","id":"a"}')).toEqual({
      mod_message: 1,
      kind: 'ping',
      id: 'a',
    })
    expect(parseMessage('{"mod_message":2,"kind":"ping","id":"a"}')).toBeNull()
    expect(parseMessage('{"kind":"ping","id":"a"}')).toBeNull()
    expect(parseMessage('not json')).toBeNull()
  })
})
