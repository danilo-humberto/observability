import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { serve, getJson } from './http-helper.mjs';

const dist = process.env.SERVICE_DIST_URL ?? new URL('../services/dados-api/dist/', import.meta.url).href;
const { createApp } = await import(dist + 'app.js');
const { readConfig } = await import(dist + 'config.js');

test('health não acessa o banco; ready consulta e responde JSON', async t => {
  let calls = 0;
  const base = await serve(createApp(async () => { calls++; }), t);
  assert.deepEqual(await getJson(base, '/health'), {
    status: 200, body: { status: 'ok', service: 'dados-api' }
  });
  assert.equal(calls, 0);
  assert.deepEqual(await getJson(base, '/ready'), {
    status: 200, body: { status: 'ok', service: 'dados-api' }
  });
  assert.equal(calls, 1);
  assert.equal((await getJson(base, '/pedidos/lento')).status, 404);
});

test('banco falha e se recupera sem recriar a aplicação; erro não vaza detalhes', async t => {
  let available = false;
  const base = await serve(createApp(async () => {
    if (!available) throw Object.assign(new Error('detalhe interno que não pode sair'), { code: 'ECONNREFUSED' });
  }), t);
  assert.deepEqual(await getJson(base, '/ready'), {
    status: 503, body: { error: { code: 'DATABASE_UNAVAILABLE', message: 'Banco indisponível.' } }
  });
  assert.equal((await getJson(base, '/health')).status, 200);
  available = true;
  assert.equal((await getJson(base, '/ready')).status, 200);
});

test('configuração obrigatória e limites são validados', () => {
  // Credencial fictícia gerada em memória, nunca usada em um banco real.
  const env = { PGHOST: 'postgres', PGDATABASE: 'observability', PGUSER: 'postgres', PGPASSWORD: crypto.randomUUID() };
  assert.equal(readConfig(env).database.max, 10);
  assert.equal(readConfig(env).database.statement_timeout, 1000);
  for (const name of ['PGHOST', 'PGDATABASE', 'PGUSER', 'PGPASSWORD']) {
    assert.throws(() => readConfig({ ...env, [name]: '' }), new RegExp(name));
  }
  for (const name of ['PORT', 'PGPORT', 'PGPOOL_MAX', 'PGCONNECT_TIMEOUT_MS', 'PGSTATEMENT_TIMEOUT_MS']) {
    for (const value of ['', '0', '-1', '1.5', 'abc', '9999999999999999999']) {
      assert.throws(() => readConfig({ ...env, [name]: value }), new RegExp(name));
    }
  }
  assert.throws(() => readConfig({ ...env, PGPORT: '65536' }));
});

test('processo rejeita configuração inválida sem imprimir o valor recebido', () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('server.js', dist))], {
    env: { ...process.env, PORT: 'valor-privado-inválido' }, encoding: 'utf8'
  });
  assert.equal(result.status, 1);
  assert.deepEqual(JSON.parse(result.stderr), {
    service: 'dados-api', event: 'initialization_failed', field: 'PORT'
  });
});
