import type { ProcessSpawnChunk, ProcessSpawnResult } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import { DRAFT_AFTER_CURSOR, DRAFT_BEFORE_CURSOR, draftOf, parseMessage } from '../hooks/channel'

const PUBLISHER = '/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
const STARTED = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const
const EXITED: ProcessSpawnResult = { code: 0, signal: null }
const COMPLETED_T1 = { answer: 'done', durationMs: 10, isAborted: false, turnId: 't1', reason: 'answer' } as const

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

  type SendCase = {
    label: string
    box: string
    fill?: { isFilled: boolean }
    submit?: 'enters' | 'drops' | 'waits'
    turnRunning?: boolean
    expected: Record<string, unknown>
    fills: { text: string; mode: string }[]
    submits: string[]
  }
  const sendCases: SendCase[] = [
    {
      label: 'fills at the cursor, submits the whole box as the person, and empties it',
      box: 'fix the flaky',
      submit: 'enters',
      expected: { ok: true, submitted: true },
      fills: [{ text: ' reconnect test', mode: 'insert' }, { text: '', mode: 'replace' }],
      submits: ['fix the flaky reconnect test'],
    },
    {
      label: 'behind a running turn it answers queued at once',
      box: '',
      submit: 'waits',
      turnRunning: true,
      expected: { ok: true, submitted: true, queued: true },
      fills: [{ text: ' reconnect test', mode: 'insert' }, { text: '', mode: 'replace' }],
      submits: ['fix the flaky reconnect test'],
    },
    {
      label: 'a submit that has not entered in time answers queued',
      box: '',
      submit: 'waits',
      expected: { ok: true, submitted: true, queued: true },
      fills: [{ text: ' reconnect test', mode: 'insert' }, { text: '', mode: 'replace' }],
      submits: ['fix the flaky reconnect test'],
    },
    {
      label: 'a dropped submit puts the text back and says it was not sent',
      box: '',
      submit: 'drops',
      expected: { ok: true, submitted: false, reason: 'dropped' },
      fills: [
        { text: ' reconnect test', mode: 'insert' },
        { text: '', mode: 'replace' },
        { text: 'fix the flaky reconnect test', mode: 'append' },
      ],
      submits: ['fix the flaky reconnect test'],
    },
    {
      label: 'a refused fill changes nothing and submits nothing',
      box: 'fix the flaky',
      fill: { isFilled: false },
      expected: { ok: false, reason: 'refused' },
      fills: [{ text: ' reconnect test', mode: 'insert' }],
      submits: [],
    },
    {
      label: 'a box holding a paste is left to the keyboard',
      box: 'see [Pasted text #1 +30 lines]',
      expected: { ok: false, reason: 'placeholder' },
      fills: [],
      submits: [],
    },
    {
      label: 'a slash command is left to the keyboard',
      box: '/compact',
      expected: { ok: false, reason: 'command' },
      fills: [],
      submits: [],
    },
  ]
  for (const c of sendCases) {
    test(`send: ${c.label}`, async ($, on) => {
      const clock = mock.clock(on)
      mock.env(on, { HOME: '/Users/tom' })
      let box = c.box === '' ? 'fix the flaky' : c.box
      const fills: { text: string; mode: string }[] = []
      const submits: string[] = []
      const replies: unknown[] = []
      on('session.start', ($, e) => ({ cwd: e.cwd }))
      on('session.id', () => ({ value: 'sess-1' }))
      on('settings.read', () => ({ value: {} }))
      on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
      on('ui.status', () => ({ value: undefined }))
      on('turn.start', ($, e) => ({ turnId: e.turnId }))
      on('prompt.read', () => ({ value: { text: box, cursor: box.length } }))
      on('prompt.fill', ($, e) => {
        fills.push({ text: e.text, mode: e.mode })
        if (c.fill !== undefined && !c.fill.isFilled) return c.fill
        box = e.mode === 'replace' ? e.text : box + e.text
        return { isFilled: true }
      })
      on('prompt.submit', async ($, e) => {
        submits.push(e.text)
        if (c.submit === 'drops') return { drop: 'a hook said no' }
        if (c.submit === 'waits') await clock.sleep(600000)
        return { text: e.text }
      })
      on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
        yield { stream: 'stdout', text: '{"id":"s","kind":"send","mod_message":1,"text":" reconnect test"}\n' }
        await clock.sleep(900000)
        return { value: EXITED }
      })
      on('process.run', ($, e) => {
        if (e.argv[1] === '--mod-reply') replies.push(JSON.parse(e.init?.stdin ?? ''))
        return {
          value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
        }
      })

      if (c.turnRunning) await $.turn.start({ text: 'earlier', turnId: 't1' })
      await $.session.start(STARTED)
      await clock.advance(c.turnRunning ? 100 : 2000)

      expect(replies).toEqual([{ mod_reply: 1, session_id: 'sess-1', id: 's', ...c.expected }])
      expect(fills).toEqual(c.fills)
      expect(submits).toEqual(c.submits)
    })
  }

  for (const [label, turnRunning, expected, aborted] of [
    ['a running turn is ended by its id', true, { ok: true }, ['t1']],
    ['with no turn running it answers no_turn and ends nothing', false, { ok: false, reason: 'no_turn' }, []],
  ] as const) {
    test(`abort: ${label}`, async ($, on) => {
      const clock = mock.clock(on)
      mock.env(on, { HOME: '/Users/tom' })
      const ended: string[] = []
      const replies: unknown[] = []
      on('session.start', ($, e) => ({ cwd: e.cwd }))
      on('session.id', () => ({ value: 'sess-1' }))
      on('settings.read', () => ({ value: {} }))
      on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
      on('ui.status', () => ({ value: undefined }))
      on('turn.start', ($, e) => ({ turnId: e.turnId }))
      on('turn.abort', ($, e) => {
        ended.push(e.turnId)
        return { value: undefined }
      })
      on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
        yield { stream: 'stdout', text: '{"id":"x","kind":"abort","mod_message":1}\n' }
        await clock.sleep(60000)
        return { value: EXITED }
      })
      on('process.run', ($, e) => {
        if (e.argv[1] === '--mod-reply') replies.push(JSON.parse(e.init?.stdin ?? ''))
        return {
          value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
        }
      })

      if (turnRunning) await $.turn.start({ text: 'earlier', turnId: 't1' })
      await $.session.start(STARTED)
      await clock.advance(1000)

      expect(replies).toEqual([{ mod_reply: 1, session_id: 'sess-1', id: 'x', ...expected }])
      expect(ended).toEqual(aborted)
    })
  }

  test('a turn that completed is not ended by a later abort', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    const ended: string[] = []
    const replies: unknown[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('settings.read', () => ({ value: {} }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('ui.status', () => ({ value: undefined }))
    on('turn.start', ($, e) => ({ turnId: e.turnId }))
    on('turn.abort', ($, e) => {
      ended.push(e.turnId)
      return { value: undefined }
    })
    on('turn.complete', ($, e) => ({ text: e.answer }))
    on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
      yield { stream: 'stdout', text: '{"id":"x","kind":"abort","mod_message":1}\n' }
      await clock.sleep(60000)
      return { value: EXITED }
    })
    on('process.run', ($, e) => {
      if (e.argv[1] === '--mod-reply') replies.push(JSON.parse(e.init?.stdin ?? ''))
      return {
        value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
      }
    })

    await $.turn.start({ text: 'earlier', turnId: 't1' })
    await $.turn.complete(COMPLETED_T1)
    await $.session.start(STARTED)
    await clock.advance(1000)

    expect(replies).toEqual([{ mod_reply: 1, session_id: 'sess-1', id: 'x', ok: false, reason: 'no_turn' }])
    expect(ended).toEqual([])
  })

  test('terms asks the session itself and returns its answer and usage', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    const prompts: string[] = []
    const replies: unknown[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('settings.read', () => ({ value: {} }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('ui.status', () => ({ value: undefined }))
    on('model.fork', ($, e) => {
      prompts.push(e.prompt)
      return {
        value: {
          isAnswered: true,
          text: '{"terms":["Voxtral"],"description":"A dictation app."}',
          usage: {
            input_tokens: 12,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 48000,
            output_tokens: 30,
          },
        },
      }
    })
    on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
      yield { stream: 'stdout', text: '{"id":"t","kind":"terms","mod_message":1,"text":"List the names."}\n' }
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

    expect(prompts).toEqual(['List the names.'])
    expect(replies).toEqual([
      {
        mod_reply: 1,
        session_id: 'sess-1',
        id: 't',
        ok: true,
        text: '{"terms":["Voxtral"],"description":"A dictation app."}',
        usage: { input_tokens: 12, cache_creation_input_tokens: 0, cache_read_input_tokens: 48000, output_tokens: 30 },
      },
    ])
  })

  test('draft answers with the prompt box as typed and the cursor in it', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    const replies: unknown[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('settings.read', () => ({ value: {} }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('ui.status', () => ({ value: undefined }))
    on('prompt.read', () => ({ value: { text: 'fix the flaky test and', cursor: 18 } }))
    on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
      yield { stream: 'stdout', text: '{"id":"d","kind":"draft","mod_message":1}\n' }
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

    expect(replies).toEqual([
      { mod_reply: 1, session_id: 'sess-1', id: 'd', ok: true, text: 'fix the flaky test and', cursor: 18 },
    ])
  })

  // A /clear or a resume moved the process to sess-2 while sess-1's attach
  // still carried requests: none of them may touch sess-2's prompt box.
  test('a request issued for a session the process has left is refused, ping aside', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    let sessionID = 'sess-1'
    const touched: string[] = []
    const replies: unknown[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: sessionID }))
    on('settings.read', () => ({ value: {} }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('ui.status', () => ({ value: undefined }))
    on('prompt.fill', () => {
      touched.push('fill')
      return { isFilled: true }
    })
    on('prompt.read', () => {
      touched.push('read')
      return { value: { text: 'what sess-2 typed', cursor: 17 } }
    })
    on('prompt.submit', () => {
      touched.push('submit')
      return {}
    })
    on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
      await clock.sleep(100)
      sessionID = 'sess-2'
      yield {
        stream: 'stdout',
        text:
          '{"id":"f","kind":"fill","mod_message":1,"text":"run the tests"}\n' +
          '{"id":"d","kind":"draft","mod_message":1}\n' +
          '{"id":"s","kind":"send","mod_message":1,"text":"run the tests"}\n' +
          '{"id":"p","kind":"ping","mod_message":1}\n',
      }
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

    expect(touched).toEqual([])
    // Answered concurrently: in id order.
    expect([...replies].sort((a, b) => ((a as { id: string }).id < (b as { id: string }).id ? -1 : 1))).toEqual([
      { mod_reply: 1, session_id: 'sess-1', id: 'd', ok: false, reason: 'session_changed' },
      { mod_reply: 1, session_id: 'sess-1', id: 'f', ok: false, reason: 'session_changed' },
      { mod_reply: 1, session_id: 'sess-1', id: 'p', ok: true },
      { mod_reply: 1, session_id: 'sess-1', id: 's', ok: false, reason: 'session_changed' },
    ])
  })

  test('draftOf keeps the text around the cursor and never splits a surrogate pair', () => {
    const before = 'a'.repeat(DRAFT_BEFORE_CURSOR + 10)
    const after = 'b'.repeat(DRAFT_AFTER_CURSOR + 10)
    expect(draftOf({ text: before + after, cursor: before.length })).toEqual({
      text: 'a'.repeat(DRAFT_BEFORE_CURSOR) + 'b'.repeat(DRAFT_AFTER_CURSOR),
      cursor: DRAFT_BEFORE_CURSOR,
    })
    // The cut falls between the halves of an emoji on both sides.
    const pair = '\u{1F600}'
    const cutStart = 'x' + pair + 'a'.repeat(DRAFT_BEFORE_CURSOR - 1)
    const cutEnd = 'b'.repeat(DRAFT_AFTER_CURSOR - 1) + pair + 'y'
    const clipped = draftOf({ text: cutStart + cutEnd, cursor: cutStart.length })
    expect(clipped).toEqual({
      text: 'a'.repeat(DRAFT_BEFORE_CURSOR - 1) + 'b'.repeat(DRAFT_AFTER_CURSOR - 1),
      cursor: DRAFT_BEFORE_CURSOR - 1,
    })
    expect(draftOf({ text: '', cursor: 0 })).toEqual({ text: '', cursor: 0 })
  })

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

  const moved = [[PUBLISHER, '--attach', '--session', 'sess-1'], [PUBLISHER, '--attach', '--session', 'sess-2']]
  for (const [reason, appAnswers, respawned] of [
    ['clear', true, moved],
    // An app that is down never answers the bye: the mod ends the child
    // itself, or it would attach as the cleared session later.
    ['clear', false, moved],
    ['prompt_input_exit', true, [[PUBLISHER, '--attach', '--session', 'sess-1']]],
  ] as const) {
    const label = `${reason}${appAnswers ? '' : ', the app does not answer'}`
    test(`session.end says bye, and the channel follows only a /clear: ${label}`, async ($, on) => {
      const clock = mock.clock(on)
      mock.env(on, { HOME: '/Users/tom' })
      let sessionID = 'sess-1'
      const spawned: (readonly string[])[] = []
      const sent: unknown[] = []
      let appSawBye = () => {}
      const byeTaken = new Promise<void>((resolve) => {
        appSawBye = resolve
      })
      on('session.start', ($, e) => ({ cwd: e.cwd }))
      on('session.end', ($, e) => ({ sessionId: e.sessionId }))
      on('session.id', () => ({ value: sessionID }))
      on('settings.read', () => ({ value: {} }))
      on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
      on('ui.status', () => ({ value: undefined }))
      on('process.spawn', async function* ($, e): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
        spawned.push(e.argv)
        if (spawned.length === 1 && appAnswers) {
          // The app answers the bye down the channel, then closes it.
          await byeTaken
          yield { stream: 'stdout', text: '{"id":"z","kind":"bye","mod_message":1}\n' }
        }
        await clock.sleep(600000)
        return { value: EXITED }
      })
      on('process.run', ($, e) => {
        if (e.argv[1] === '--mod-reply') {
          sent.push(JSON.parse(e.init?.stdin ?? ''))
          appSawBye()
        }
        return {
          value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
        }
      })

      await $.session.start(STARTED)
      await clock.advance(1000)
      await $.session.end({ reason, sessionId: 'sess-1', resume: { id: 'sess-1' } })
      if (reason === 'clear') sessionID = 'sess-2'
      await clock.advance(2000)

      expect(sent).toEqual([{ mod_bye: 1, session_id: 'sess-1' }])
      expect(spawned).toEqual(respawned)
    })
  }

  type AppendCase = {
    label: string
    lines: object[]
    refuse?: string[]
    fills: string[]
    acks: number[]
  }
  const appendCases: AppendCase[] = [
    {
      label: 'fills in order though the first fill is slow, and the ack counts them',
      lines: [
        { kind: 'ack', id: 'k0', seq: 0 },
        { kind: 'append', id: 'a1', seq: 1, text: 'slow ' },
        { kind: 'append', id: 'a2', seq: 2, text: 'and steady' },
        { kind: 'ack', id: 'k1', seq: 2 },
      ],
      fills: ['slow ', 'and steady'],
      acks: [0, 2],
    },
    {
      label: 'a gap ends the stream: nothing after it fills, out of order or not',
      lines: [
        { kind: 'ack', id: 'k0', seq: 0 },
        { kind: 'append', id: 'a1', seq: 1, text: 'one ' },
        { kind: 'append', id: 'a3', seq: 3, text: 'three ' },
        { kind: 'append', id: 'a2', seq: 2, text: 'two ' },
        { kind: 'ack', id: 'k1', seq: 3 },
        { kind: 'append', id: 'b1', seq: 1, text: 'next' },
        { kind: 'ack', id: 'k2', seq: 1 },
      ],
      fills: ['one ', 'next'],
      acks: [0, 1, 1],
    },
    {
      label: 'a refused fill ends the stream there',
      lines: [
        { kind: 'ack', id: 'k0', seq: 0 },
        { kind: 'append', id: 'a1', seq: 1, text: 'one ' },
        { kind: 'append', id: 'a2', seq: 2, text: 'two ' },
        { kind: 'append', id: 'a3', seq: 3, text: 'three' },
        { kind: 'ack', id: 'k1', seq: 3 },
      ],
      refuse: ['two '],
      fills: ['one ', 'two '],
      acks: [0, 1],
    },
  ]
  for (const c of appendCases) {
    test(`append: ${c.label}`, async ($, on) => {
      const clock = mock.clock(on)
      mock.env(on, { HOME: '/Users/tom' })
      const fills: string[] = []
      const replies: { id: string; ok: boolean; seq?: number }[] = []
      on('session.start', ($, e) => ({ cwd: e.cwd }))
      on('session.id', () => ({ value: 'sess-1' }))
      on('settings.read', () => ({ value: {} }))
      on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
      on('ui.status', () => ({ value: undefined }))
      on('prompt.fill', async ($, e) => {
        fills.push(e.text)
        if (fills.length === 1) await clock.sleep(500)
        return { isFilled: !(c.refuse ?? []).includes(e.text) }
      })
      on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
        yield { stream: 'stdout', text: c.lines.map((l) => JSON.stringify({ mod_message: 1, ...l })).join('\n') + '\n' }
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
      await clock.advance(2000)

      expect(fills).toEqual(c.fills)
      expect(replies.every((r) => r.id.startsWith('k') && r.ok)).toBe(true)
      expect(replies.map((r) => r.seq)).toEqual(c.acks)
    })
  }

  test('send with no text submits the box as the appends left it', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    let box = 'run the tests'
    const fills: { text: string; mode: string }[] = []
    const submits: string[] = []
    const replies: unknown[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('settings.read', () => ({ value: {} }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('ui.status', () => ({ value: undefined }))
    on('prompt.read', () => ({ value: { text: box, cursor: box.length } }))
    on('prompt.fill', ($, e) => {
      fills.push({ text: e.text, mode: e.mode })
      box = e.mode === 'replace' ? e.text : box + e.text
      return { isFilled: true }
    })
    on('prompt.submit', ($, e) => {
      submits.push(e.text)
      return { text: e.text }
    })
    on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
      yield { stream: 'stdout', text: '{"id":"s","kind":"send","mod_message":1,"text":""}\n' }
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
    await clock.advance(2000)

    expect(replies).toEqual([{ mod_reply: 1, session_id: 'sess-1', id: 's', ok: true, submitted: true }])
    expect(fills).toEqual([{ text: '', mode: 'replace' }])
    expect(submits).toEqual(['run the tests'])
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
    expect(parseMessage('{"mod_message":1,"kind":"state","id":"a","waiting":["api",3]}')?.waiting).toEqual(['api'])
    expect(parseMessage('{"mod_message":1,"kind":"append","id":"a","seq":2,"text":"x"}')?.seq).toBe(2)
    expect(parseMessage('{"mod_message":1,"kind":"append","id":"a","seq":1.5}')?.seq).toBeUndefined()
  })
})
