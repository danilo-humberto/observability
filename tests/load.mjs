import { performance } from 'node:perf_hooks';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

export function summarize(samples, elapsedMs) {
  const latencies = samples.filter(s => s.valid).map(s => s.durationMs);
  const errors = {};
  for (const s of samples.filter(s => !s.valid)) {
    const key = s.transportError ? 'transport' : s.status === 200 ? 'invalid_body' : `http_${s.status}`;
    errors[key] = (errors[key] ?? 0) + 1;
  }
  return {
    started: samples.length, successes: latencies.length, errors,
    meanMs: latencies.length ? latencies.reduce((a, b) => a + b, 0) / latencies.length : null,
    medianMs: percentile(latencies, 0.5), p95Ms: percentile(latencies, 0.95),
    elapsedMs, successesPerSecond: latencies.length / (elapsedMs / 1000),
  };
}

const digest = body => createHash('sha256').update(body).digest('hex');

export async function runLoad({ url, concurrency, durationMs, expectedHash, timeoutMs = 10000 }) {
  if (!Number.isInteger(concurrency) || concurrency < 1 || !Number.isFinite(durationMs) || durationMs <= 0) {
    throw new Error('Parâmetros de carga inválidos');
  }
  const samples = [];
  const startedUtc = new Date().toISOString();
  const start = performance.now();
  const deadline = start + durationMs;
  async function worker() {
    while (performance.now() < deadline) {
      const begin = performance.now();
      let status = null;
      let body;
      let transportError = false;
      try {
        const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
        status = response.status;
        body = await response.text();
      } catch {
        transportError = true;
      }
      const duration = performance.now() - begin;
      // O corpo completo participa do tempo; validação ocorre depois do relógio.
      const valid = !transportError && status === 200 && digest(body) === expectedHash;
      samples.push({ offsetMs: begin - start, durationMs: duration, status, transportError, valid });
    }
  }
  await Promise.all(Array.from({ length: concurrency }, worker));
  const elapsedMs = performance.now() - start;
  return { startedUtc, endedUtc: new Date().toISOString(), concurrency, durationMs,
    summary: summarize(samples, elapsedMs), samples };
}

async function main() {
  const [mode, route, concurrency, seconds, output] = process.argv.slice(2);
  const base = 'http://pedidos-api:3000';
  if (mode === 'verify') {
    const responses = [];
    for (const name of ['lento', 'otimizado']) {
      const response = await fetch(`${base}/pedidos/${name}?limit=100`, { signal: AbortSignal.timeout(10000) });
      if (response.status !== 200) throw new Error(`Pré-verificação falhou: ${name}, HTTP ${response.status}`);
      responses.push(await response.text());
    }
    const rows = JSON.parse(responses[0]);
    if (responses[0] !== responses[1] || !Array.isArray(rows) || rows.length !== 100 ||
      rows.some((r, i) => i > 0 && r.id <= rows[i - 1].id)) throw new Error('Respostas diferentes ou incompletas');
    await writeFile('/results/expected.json', JSON.stringify({ hash: digest(responses[0]), count: rows.length }));
    return;
  }
  if (mode !== 'run' || !['lento', 'otimizado'].includes(route) || !/^[a-z0-9-]+$/.test(output ?? '')) {
    throw new Error('Comando de carga inválido');
  }
  const expected = JSON.parse(await readFile('/results/expected.json', 'utf8'));
  const result = await runLoad({ url: `${base}/pedidos/${route}?limit=100`, concurrency: Number(concurrency),
    durationMs: Number(seconds) * 1000, expectedHash: expected.hash });
  await writeFile(`/results/${output}.json`, JSON.stringify(result));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => { console.error('Falha no gerador de carga; resultados anteriores preservados.'); process.exitCode = 1; });
}
