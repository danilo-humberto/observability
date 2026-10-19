import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { serve } from './http-helper.mjs';
import { percentile, summarize, runLoad } from './load.mjs';

test('percentis usam nearest rank e resumo separa falhas', () => {
  assert.equal(percentile([], 0.95), null);
  assert.equal(percentile([4, 1, 3, 2], 0.5), 2);
  assert.equal(percentile(Array.from({ length: 100 }, (_, i) => i + 1), 0.95), 95);
  const summary = summarize([
    { valid: true, durationMs: 10 }, { valid: true, durationMs: 30 },
    { status: 504 }, { status: 200 }, { transportError: true },
  ], 2000);
  assert.equal(summary.started, 5);
  assert.equal(summary.successes, 2);
  assert.equal(summary.meanMs, 20);
  assert.equal(summary.successesPerSecond, 1);
  assert.deepEqual(summary.errors, { http_504: 1, invalid_body: 1, transport: 1 });
});

test('limita concorrência, espera corpo completo e drena chamadas', async t => {
  let active = 0;
  let maxActive = 0;
  let requests = 0;
  const base = await serve((req, res) => {
    requests++;
    active++;
    maxActive = Math.max(maxActive, active);
    res.writeHead(200);
    res.write('[');
    setTimeout(() => { active--; res.end(']'); }, 60);
  }, t);
  const result = await runLoad({ url: base, concurrency: 5, durationMs: 160,
    expectedHash: createHash('sha256').update('[]').digest('hex') });
  assert.equal(maxActive, 5);
  assert.equal(active, 0);
  assert.equal(result.samples.length, requests);
  assert.equal(result.summary.successes, requests);
  assert.ok(result.samples.every(s => s.durationMs >= 50 && s.offsetMs < 160));
  assert.ok(result.summary.elapsedMs >= 160);
});

test('registra status HTTP, conteúdo inválido e timeout durante corpo', async t => {
  const base = await serve((req, res) => {
    if (req.url === '/timeout') { res.writeHead(200); res.write('['); return; }
    res.writeHead(req.url === '/error' ? 503 : 200);
    res.end('invalid');
  }, t);
  for (const [path, key] of [['/error', 'http_503'], ['/invalid', 'invalid_body'], ['/timeout', 'transport']]) {
    const result = await runLoad({ url: base + path, concurrency: 1, durationMs: 30, timeoutMs: 60, expectedHash: 'wrong' });
    assert.ok(result.summary.errors[key] > 0);
    assert.equal(result.summary.successes, 0);
  }
});
