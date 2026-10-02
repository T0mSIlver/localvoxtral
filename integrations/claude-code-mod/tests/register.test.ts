import { describe, expect, mock, test } from 'claude-code/testing'

const PUBLISHER = '/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
const STARTED = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const

describe('register', () => {
  test('pins the publisher answer for this session, refreshed on the clock', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    const statuses: (string | undefined)[] = []
    const runs: { argv: readonly string[]; stdin?: string }[] = []
    let answer = '\u001b[32mlvx ●\u001b[0m\n'
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('process.run', ($, e) => {
      runs.push({ argv: e.argv, stdin: e.init?.stdin })
      return { value: { exitCode: 0, stdout: answer, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('ui.status', ($, e) => {
      statuses.push(e.text)
      return { value: undefined }
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
    mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    const ran: (string | undefined)[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('fs.exists', () => ({ value: false }))
    on('process.run', ($, e) => {
      ran.push(e.argv[0])
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })

    await $.session.start(STARTED)

    expect(ran).toEqual([])
  })

  test('a failed run clears the line instead of throwing', async ($, on) => {
    mock.clock(on)
    mock.env(on, { HOME: '/Users/tom' })
    const statuses: (string | undefined)[] = []
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.id', () => ({ value: 'sess-1' }))
    on('fs.exists', ($, e) => ({ value: e.path === PUBLISHER }))
    on('process.run', () => {
      throw new Error('Exec format error')
    })
    on('ui.status', ($, e) => {
      statuses.push(e.text)
      return { value: undefined }
    })

    await $.session.start(STARTED)

    expect(statuses).toEqual([undefined])
  })
})
