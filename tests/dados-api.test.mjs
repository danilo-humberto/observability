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
  assert.equal((await getJson(base, '/desconhecida')).status, 404);
});

test('pedidos: valida limit nas duas rotas antes de acessar o banco', async t => {
  const calls = [];
  const base = await serve(createApp(async () => {}, async (mode, limit) => {
    calls.push({ mode, limit }); return [];
  }), t);
  for (const mode of ['lento', 'otimizado']) {
    for (const [query, expected] of [['', 100], ['?limit=1', 1], ['?limit=1000', 1000], ['?limit=001', 1]]) {
      assert.deepEqual(await getJson(base, `/pedidos/${mode}${query}`), { status: 200, body: [] });
      assert.deepEqual(calls.at(-1), { mode, limit: expected });
    }
    const before = calls.length;
    for (const query of ['limit=', 'limit=0', 'limit=-1', 'limit=1.5', 'limit=1001', 'limit=abc',
      'limit=1&limit=2', 'limit[]=1', 'limit[x]=1', 'limit=1&limit[]=2', 'limit=1e2', 'limit=%201', 'limit=999999999999999999999']) {
      const result = await getJson(base, `/pedidos/${mode}?${query}`);
      assert.equal(result.status, 400, query);
      assert.equal(result.body.error.code, 'INVALID_LIMIT');
    }
    assert.equal(calls.length, before);
  }
});

test('pedidos: falha não retorna lista parcial nem detalhes e permite recuperação', async t => {
  let fail = true;
  const base = await serve(createApp(async () => {}, async () => {
    if (fail) throw new Error('SQL privado');
    return [];
  }), t);
  for (const mode of ['lento', 'otimizado']) {
    assert.deepEqual(await getJson(base, `/pedidos/${mode}`), {
      status: 503, body: { error: { code: 'DATABASE_UNAVAILABLE', message: 'Banco indisponível.' } }
    });
  }
  fail = false;
  assert.equal((await getJson(base, '/pedidos/lento')).status, 200);
});

test('repositório: N+1 sequencial sem cache e JOIN usam o mesmo contrato', async () => {
  const { createOrdersRepository } = await import(dist + 'orders.js');
  const rows = [1, 2].map(id => ({ id, client_id: 7, description: `Pedido ${id}`,
    amount: '10.20', created_at: new Date('2026-01-01T00:00:00.000Z') }));
  const calls = [];
  let active = false;
  const list = createOrdersRepository({ async query(sql, params) {
    assert.equal(active, false);
    active = true;
    await Promise.resolve();
    active = false;
    calls.push({ sql, params });
    if (sql.includes('INNER JOIN')) return { rows: rows.map(row => ({ ...row, joined_client_id: 7, name: 'Cliente 7' })) };
    if (sql.includes('FROM orders')) return { rows };
    return { rows: [{ id: 7, name: 'Cliente 7' }] };
  } });
  const slow = await list('lento', 100);
  assert.equal(calls.length, 3);
  assert.deepEqual(calls.map(call => call.params), [[100], [7], [7]]);
  assert.ok(calls[0].sql.includes('ORDER BY id ASC LIMIT $1'));
  calls.length = 0;
  assert.deepEqual(await list('otimizado', 100), slow);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].params, [100]);
  assert.deepEqual(slow[0], { ...rows[0], created_at: '2026-01-01T00:00:00.000Z', client: { id: 7, name: 'Cliente 7' } });
  let emptyCalls = 0;
  const empty = createOrdersRepository({ async query() { emptyCalls++; return { rows: [] }; } });
  assert.deepEqual(await empty('lento', 100), []);
  assert.equal(emptyCalls, 1);
  assert.deepEqual(await empty('otimizado', 100), []);
  assert.equal(emptyCalls, 2);
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
