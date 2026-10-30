import assert from 'node:assert/strict'
import test from 'node:test'
import type { SessionEvent } from '@deepseek-ai/dsh-session'
import type { SessionLogSnapshot } from '@deepseek-ai/dsh-session-query'
import { createProjection, projectHistory } from '../../src/host/dsh-runtime/history.js'
import { itemId, userMessageId } from '../../src/host/dsh-runtime/identity.js'

function input(kind: string, time: unknown = 1000, id = 'scheduled-message', rpcId?: string): SessionEvent {
  return { seq: 0, time, type: 'user/message', data: { id, role: 'user',
    content: [{ type: 'text', text: '[SCHEDULE REMINDER]\nreminder_prompt_json: "Synthetic task"' }],
    source: { kind, ...(rpcId ? { rpcId } : {}) },
  } } as unknown as SessionEvent
}
function snapshot(events: SessionEvent[]): SessionLogSnapshot {
  return { session: { id: 'native', version: 0, createdAt: 0, isSeeded: false }, inheritedEventCount: 0, events } as SessionLogSnapshot
}

test('native schedule input remains a stable user message with complete body and native automation marker', () => {
  const scheduled = input('schedule', 25_000)
  const reply = { seq: 1, time: 26_000, type: 'assistant/message', data: { turn: 1, step: 1, interrupted: false,
    message: { id: 'result', role: 'assistant', source: { kind: 'model', provider: 'test', model: 'test' },
      content: [{ type: 'text', text: 'Synthetic automation result' }] },
  } } as unknown as SessionEvent
  const items = projectHistory(snapshot([scheduled, reply]), 'platform')
  assert.equal(items.length, 2)
  assert.equal(items[0]!.id, itemId('native', 'message', 'scheduled-message:0'))
  assert.equal(items[0]!.role, 'user')
  assert.equal(items[0]!.content.text, '[SCHEDULE REMINDER]\nreminder_prompt_json: "Synthetic task"')
  assert.deepEqual(items[0]!.content.automation, { kind: 'schedule', timestampMs: 25_000 })
  assert.equal(items[1]!.content.text, 'Synthetic automation result')
  assert.equal(items[1]!.content.automation, undefined)
  const live = createProjection('native', 'platform')
  live.apply(scheduled); live.drain(); live.apply(reply)
  assert.deepEqual(live.snapshot(), items)
})

test('schedule kind survives missing or invalid native time without inventing a timestamp', () => {
  for (const time of [NaN, Infinity, -1, undefined]) {
    const event = input('schedule', time)
    // Explicit undefined bypasses this helper's default native time.
    if (time === undefined) (event as unknown as { time: unknown }).time = undefined
    const [item] = projectHistory(snapshot([event]), 'platform')
    assert(item)
    assert.deepEqual(item.content.automation, { kind: 'schedule' })
  }
})

test('internal and other unapproved non-user producers remain filtered', () => {
  for (const kind of ['runtime-context', 'model-selection', 'tool-registry', 'ptc-mode',
    'user-approval', 'user-question-reply', 'skill-invocation', 'goal', 'webhook', 'unknown-producer']) {
    assert.deepEqual(projectHistory(snapshot([input(kind)]), 'platform'), [])
  }
})

test('automation cannot consume human send receipts or client message correlation', () => {
  const nativeId = userMessageId('native', 'client-send')
  const receipt = { platformId: 'platform', fingerprint: 'synthetic', attachments: [
    { fileId: 'file_human', name: 'human.txt', mediaType: 'text/plain', size: 1, sha256: 'a'.repeat(64) },
  ] }
  for (const kind of ['schedule', 'user']) {
    const projection = createProjection('native', 'platform')
    projection.apply(input(kind, 1000, nativeId, nativeId), receipt)
    const [item] = projection.snapshot(); assert(item)
    assert.equal(item.source.clientMessageId, kind === 'user' ? 'client-send' : undefined)
    assert.deepEqual(item.content.attachments, kind === 'user' ? receipt.attachments : undefined)
    assert.equal(item.content.automation === undefined, kind === 'user')
  }
})
