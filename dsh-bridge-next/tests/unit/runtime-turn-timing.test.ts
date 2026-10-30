import assert from 'node:assert/strict'
import test from 'node:test'
import type { SessionLogSnapshot } from '@deepseek-ai/dsh-session-query'
import { createProjection, projectHistory } from '../../src/host/dsh-runtime/history.js'
import { contentHash } from '../../src/host/dsh-runtime/identity.js'

function log(events: { type: string, time: number, data: unknown }[]): SessionLogSnapshot {
  return { session: { id: 'native', version: 0, createdAt: 0, isSeeded: false }, inheritedEventCount: 0,
    events: events.map((event, seq) => ({ ...event, seq })) } as SessionLogSnapshot
}
const start = (time = 1000, turn = 1) => ({ type: 'turn/start', time, data: { turn } })
const end = (time = 3000, turn = 1, kind = 'completed') => ({ type: 'turn/end', time, data: { turn, reason: { kind } } })
const message = (time = 2000) => ({ type: 'assistant/message', time, data: {
  turn: 1, step: 1, interrupted: false, message: { id: 'assistant', role: 'assistant',
    source: { kind: 'model', provider: 'test', model: 'test' },
    content: [{ type: 'text', text: 'Synthetic completed reply' }],
  },
} })

test('native turn end refreshes already completed items with timing, revision and content hash', () => {
  const call = message(12_000)
  const snapshot = log([start(10_000), { ...call, data: { ...call.data,
    message: { ...call.data.message, content: [{ type: 'tool-call', id: 'call-1', name: 'bash', arguments: '{"command":"pwd"}' }] },
  } }, { type: 'tool/result', time: 14_000, data: { turn: 1, step: 1, message: { toolCallId: 'call-1', content: [] } } },
  message(15_000), end(39_000)])
  const projection = createProjection('native', 'platform')
  for (const event of snapshot.events.slice(0, -1)) projection.apply(event)
  const before = projection.drain().items.find(item => item.type === 'tool')!
  assert.equal(before.status, 'done')
  assert.deepEqual(before.content.turnTiming, { startedAt: 10_000, status: 'running' })
  projection.apply(snapshot.events.at(-1)!)
  const updated = projection.drain().items
  const after = updated.find(item => item.id === before.id)!
  assert.equal(after.status, 'done')
  assert.equal(after.revision, Number(snapshot.events.at(-1)!.seq) + 1)
  assert.notEqual(after.contentHash, before.contentHash)
  assert.deepEqual(after.content.turnTiming, { startedAt: 10_000, completedAt: 39_000, durationMs: 29_000, status: 'done' })
  assert.deepEqual(before.content.turnTiming, { startedAt: 10_000, status: 'running' })
  assert(updated.every(item => item.contentHash === contentHash(item)))
  assert.deepEqual(projection.snapshot(), projectHistory(snapshot, 'platform'))
})

test('native wall time and failure status stay isolated from a following turn', () => {
  const items = projectHistory(log([start(), message(), end(3000, 1, 'error'),
    start(4000, 2), end(9000, 2, 'interrupted')]), 'platform')
  const first = items.find(item => item.type === 'message')!
  assert.deepEqual(first.content.turnTiming, { startedAt: 1000, completedAt: 3000, durationMs: 2000, status: 'failed' })
  const last = items.findLast(item => item.type === 'turn.end')!
  assert.deepEqual(last.content.turnTiming, { startedAt: 4000, completedAt: 9000, durationMs: 5000, status: 'interrupted' })
})

test('missing invalid reversed or mismatched native boundaries never invent elapsed time', () => {
  for (const [startTime, endTime, endTurn] of [[NaN, 3000, 1], [1000, Infinity, 1], [3000, 1000, 1], [1000, 3000, 2]]) {
    const item = projectHistory(log([start(startTime), message(), end(endTime, endTurn)]), 'platform').find(item => item.type === 'message')!
    const timing = item.content.turnTiming as Record<string, unknown> | undefined
    assert.equal(timing?.durationMs, undefined)
  }
  const orphan = projectHistory(log([message(), end()]), 'platform').find(item => item.type === 'message')!
  assert.equal(orphan.content.turnTiming, undefined)
})


test('native failure status survives absent clocks without fabricating a duration', () => {
  const snapshot = log([start(NaN), message(), end(NaN, 1, 'error')])
  const first = projectHistory(snapshot, 'platform').find(item => item.type === 'message')!
  assert.equal(first.status, 'done')
  assert.deepEqual(first.content.turnTiming, { status: 'failed' })
})
