import type { ProcessSpawnChunk, ProcessSpawnResult, RenderPropsOf } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

const PUBLISHER = '/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
const STARTED = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const
const EXITED: ProcessSpawnResult = { code: 0, signal: null }
const PROPS: RenderPropsOf['AbovePrompt'] = {
  hasSurvey: false,
  isWorking: false,
  maxRows: 4,
  bodyColumns: 80,
  scroll: { top: 0, height: 0 },
} as unknown as RenderPropsOf['AbovePrompt']

const state = (phase: string, text?: string) =>
  `${JSON.stringify({ mod_message: 1, kind: 'state', id: phase, phase, ...(text === undefined ? {} : { text }) })}\n`

describe('band', () => {
  for (const surface of ['terminal', 'desktop', 'mobile'] as const) {
    test(`shows the dictation above the prompt until it is done, unanswered: ${surface}`, async ($, on) => {
      const clock = mock.clock(on)
      mock.env(on, { HOME: '/Users/tom' })
      const replies: string[] = []
      on('session.start', ($, e) => ({ cwd: e.cwd }))
      on('session.id', () => ({ value: 'sess-1' }))
      on('settings.read', () => ({ value: {} }))
      on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
      on('ui.status', () => ({ value: undefined }))
      on('ui.render', ($, e) => $.ui.resolve(e).Box({}))
      on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
        yield { stream: 'stdout', text: state('listening', 'run the tests in') }
        await clock.sleep(1000)
        yield { stream: 'stdout', text: state('finishing', 'run the tests in the core package') }
        await clock.sleep(1000)
        yield { stream: 'stdout', text: state('done') }
        await clock.sleep(60000)
        return { value: EXITED }
      })
      on('process.run', ($, e) => {
        if (e.argv[1] === '--mod-reply') replies.push(e.init?.stdin ?? '')
        return {
          value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
        }
      })

      await $.session.start(STARTED)
      await clock.advance(10)
      const ui = await $.ui.mount({ plugin: 'localvoxtral-mod', surface, component: 'AbovePrompt', props: PROPS })
      expect((await ui.find({ type: 'Text', text: 'Listening ' }))).toBeDefined()
      expect((await ui.find({ type: 'Text', text: 'run the tests in' }))).toBeDefined()

      await clock.advance(1000)
      expect((await ui.find({ type: 'Text', text: 'Finishing ' }))).toBeDefined()

      await clock.advance(1000)
      expect(await ui.find({ type: 'Text', text: /Listening|Finishing/ })).toBeUndefined()
      expect(replies).toEqual([])
      await ui.unmount()
    })
  }

  test('a band whose end never arrives clears itself', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('settings.read', () => ({ value: {} }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('ui.status', () => ({ value: undefined }))
    on('ui.render', ($, e) => $.ui.resolve(e).Box({}))
    on('process.spawn', async function* (): AsyncGenerator<ProcessSpawnChunk, { value: ProcessSpawnResult }> {
      yield { stream: 'stdout', text: state('listening', 'and then the app quit') }
      await clock.sleep(600000)
      return { value: EXITED }
    })
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }))

    await $.session.start(STARTED)
    await clock.advance(10)
    const ui = await $.ui.mount({ plugin: 'localvoxtral-mod', surface: 'terminal', component: 'AbovePrompt', props: PROPS })
    expect(await ui.find({ type: 'Text', text: 'Listening ' })).toBeDefined()

    await clock.advance(30000)
    expect(await ui.find({ type: 'Text', text: 'Listening ' })).toBeUndefined()
    await ui.unmount()
  })
})
