import type { On, ProcessRunResult } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

const PUBLISHER = '/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
const STARTED = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const

function ran(stdout: string): { value: ProcessRunResult } {
  return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
}

/** The world beneath the mod: a Mac with the app installed, no status-line setting. */
function world(on: On, settings: Record<string, unknown> = {}, hasPublisher = true) {
  const clock = mock.clock(on)
  mock.env(on, { HOME: '/Users/tom' })
  const statuses: (string | undefined)[] = []
  const runs: { argv: readonly string[]; stdin?: string }[] = []
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('settings.read', () => ({ value: settings }))
  on('fs.exists', ($, e) => ({ value: hasPublisher && e.path === PUBLISHER }))
  on('ui.status', ($, e) => {
    statuses.push(e.text)
    return { value: undefined }
  })
  return { clock, statuses, runs }
}

describe('register', () => {
  test('pins the publisher answer for this session, refreshed on the clock', async ($, on) => {
    const { clock, statuses, runs } = world(on)
    let answer = '\u001b[32mlvx ●\u001b[0m\n'
    on('process.run', ($, e) => {
      runs.push({ argv: e.argv, stdin: e.init?.stdin })
      return ran(answer)
    })

    await $.session.start(STARTED)
    answer = 'lvx ○\n'
    await clock.advance(5000)

    expect(runs[0]).toEqual({
      argv: [PUBLISHER, '--statusline'],
      stdin: JSON.stringify({ session_id: 'sess-1' }),
    })
    expect(statuses).toEqual(['lvx ●', 'lvx ○'])
  })

  test('without a publisher it draws nothing and runs nothing', async ($, on) => {
    const { statuses, runs } = world(on, {}, false)
    on('process.run', ($, e) => {
      runs.push({ argv: e.argv })
      return ran('lvx ●')
    })

    await $.session.start(STARTED)

    expect({ runs, statuses }).toEqual({ runs: [], statuses: [] })
  })

  test('a failed run clears the line instead of throwing', async ($, on) => {
    const { statuses } = world(on)
    on('process.run', () => {
      throw new Error('Exec format error')
    })

    await $.session.start(STARTED)

    expect(statuses).toEqual([undefined])
  })

  for (const command of [
    `${PUBLISHER} --statusline`,
    '/Users/tom/.claude/localvoxtral-statusline.sh',
  ]) {
    test(`a status-line setting that already shows it wins: ${command}`, async ($, on) => {
      const { statuses, runs } = world(on, { statusLine: { type: 'command', command } })
      on('process.run', ($, e) => {
        runs.push({ argv: e.argv })
        return ran('lvx ●')
      })

      await $.session.start(STARTED)

      expect({ runs, statuses }).toEqual({ runs: [], statuses: [] })
    })
  }

  test("the person's own status line does not stop it", async ($, on) => {
    const { statuses } = world(on, { statusLine: { type: 'command', command: '~/bin/my-line' } })
    on('process.run', () => ran('lvx ●'))

    await $.session.start(STARTED)

    expect(statuses).toEqual(['lvx ●'])
  })
})
