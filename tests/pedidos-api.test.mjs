import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { serve, getJson } from './http-helper.mjs';

const dist = process.env.SERVICE_DIST_URL ?? new URL('../services/pedidos-api/dist/', import.meta.url).href;
const { createApp } = await import(dist + 'app.js');
const { createDadosClient, createOrdersClient } = await import(dist + 'dados-client.js');
const { readConfig } = await import(dist + 'config.js');

async function setup(t, upstream, timeout = 500) {
  const dependency = await serve(upstream, t);
  return serve(createApp(createDadosClient(dependency + '/ready', timeout)), t);
}

const order = {
  id: 1, client_id: 2, description: 'Order 1', amount: '1.38',
  created_at: '2024-02-01T00:00:00.000Z', client: { id: 2, name: 'Client 2' }
};
async function setupOrders(t, upstream, timeout = 500) {
  const dependency = await serve(upstream, t);
  return serve(createApp(async () => {}, createOrdersClient(dependency, timeout)), t);
}

test('pedidos: valida limit e faz uma chamada HTTP por rota, sem mudar o JSON', async t => {
  const urls = [];
  const base = await setupOrders(t, (req, res) => { urls.push(req.url); res.end(JSON.stringify([order])); });
  for (const mode of ['lento', 'otimizado']) {
    for (const [query, expected] of [['', 100], ['?limit=1', 1], ['?limit=1000', 1000]]) {
      const count = urls.length;
      assert.deepEqual(await getJson(base, `/pedidos/${mode}${query}`), { status: 200, body: [order] });
      assert.equal(urls.length, count + 1);
      assert.equal(urls.at(-1), `/pedidos/${mode}?limit=${expected}`);
    }
    const count = urls.length;
    for (const query of ['limit=', 'limit=0', 'limit=-1', 'limit=1.5', 'limit=1001', 'limit=abc',
      'limit=1&limit=2', 'limit[]=1', 'limit[x]=1', 'limit=1&limit[]=2', 'limit=1e2', 'limit=%201', 'limit=99999999999999999999']) {
      const result = await getJson(base, `/pedidos/${mode}?${query}`);
      assert.equal(result.status, 400, query);
      assert.equal(result.body.error.code, 'INVALID_LIMIT');
    }
    assert.equal(urls.length, count);
  }
});

test('pedidos: lista vazia é preservada', async t => {
  const base = await setupOrders(t, (_req, res) => res.end('[]'));
  assert.deepEqual(await getJson(base, '/pedidos/lento'), { status: 200, body: [] });
});

for (const [name, body] of [
  ['objeto', { pedidos: [order] }], ['valor numérico', [{ ...order, amount: 1.38 }]],
  ['cliente errado', [{ ...order, client: { id: 3, name: 'Client 3' } }]],
  ['ordem inválida', [order, order]], ['campo ausente', [{ ...order, description: undefined }]],
  ['ordem decrescente', [{ ...order, id: 2 }, order]],
  ['data inválida', [{ ...order, created_at: '2024-02-31T00:00:00.000Z' }]],
  ['campo extra', [{ ...order, extra: 'privado' }]], ['limite excedido', [order, { ...order, id: 2 }]]
]) {
  test(`pedidos: resposta com ${name} recebe 502`, async t => {
    const base = await setupOrders(t, (_req, res) => res.end(JSON.stringify(body)));
    const limit = name === 'limite excedido' ? 1 : 100;
    assert.equal((await getJson(base, `/pedidos/otimizado?limit=${limit}`)).status, 502);
  });
}

for (const mode of ['lento', 'otimizado']) {
  test(`pedidos/${mode}: banco indisponível, JSON inválido e timeout não retornam lista parcial`, async t => {
    let behavior = 'database';
    let calls = 0;
    const base = await setupOrders(t, (_req, res) => {
      calls++;
      if (behavior === 'database') res.writeHead(503).end(JSON.stringify({ error: { code: 'DATABASE_UNAVAILABLE', message: 'privado' } }));
      if (behavior === 'json') res.end('{');
      if (behavior === 'body') { res.writeHead(200); res.write('['); }
      // 'headers' deixa a resposta pendente somente no servidor simulado.
    }, 100);
    for (const [next, status, code] of [['database', 503, 'DEPENDENCY_UNAVAILABLE'], ['json', 502, 'BAD_GATEWAY'],
      ['headers', 504, 'GATEWAY_TIMEOUT'], ['body', 504, 'GATEWAY_TIMEOUT']]) {
      behavior = next;
      const before = calls;
      const result = await getJson(base, `/pedidos/${mode}`);
      assert.equal(result.status, status);
      assert.equal(result.body.error.code, code);
      assert.equal(calls, before + 1);
      assert.ok(!JSON.stringify(result.body).includes('privado'));
    }
  });
}

test('health independente; ready valida resposta da dados-api; rota desconhecida recebe 404', async t => {
  let calls = 0;
  const base = await setup(t, (req, res) => {
    calls++;
    assert.equal(req.url, '/ready');
    res.end(JSON.stringify({ status: 'ok', service: 'dados-api' }));
  });
  assert.deepEqual(await getJson(base, '/health'), {
    status: 200, body: { status: 'ok', service: 'pedidos-api' }
  });
  assert.equal(calls, 0);
  assert.deepEqual(await getJson(base, '/ready'), {
    status: 200, body: { status: 'ok', service: 'pedidos-api' }
  });
  assert.equal(calls, 1);
  assert.equal((await getJson(base, '/desconhecida')).status, 404);
});

test('503 da dependência é traduzido sem repassar mensagens internas', async t => {
  const base = await setup(t, (_req, res) => {
    res.writeHead(503).end(JSON.stringify({ error: { code: 'DATABASE_UNAVAILABLE', message: 'detalhe privado' } }));
  });
  assert.deepEqual(await getJson(base, '/ready'), {
    status: 503, body: { error: { code: 'DEPENDENCY_UNAVAILABLE', message: 'Serviço de dados indisponível.' } }
  });
});

for (const [name, status, body] of [
  ['JSON inválido', 200, '{'], ['corpo inválido', 200, 'null'],
  ['serviço errado', 200, '{"status":"ok","service":"outro"}'],
  ['status inesperado', 500, '{}'], ['503 fora do contrato', 503, '{}']
]) {
  test(`${name} retorna 502`, async t => {
    const base = await setup(t, (_req, res) => res.writeHead(status).end(body));
    const result = await getJson(base, '/ready');
    assert.equal(result.status, 502);
    assert.equal(result.body.error.code, 'BAD_GATEWAY');
  });
}

test('conexão recusada retorna 502 e health permanece disponível', async t => {
  const closed = createServer();
  closed.listen(0, '127.0.0.1');
  await once(closed, 'listening');
  const port = closed.address().port;
  await new Promise(resolve => closed.close(resolve));
  const base = await serve(createApp(createDadosClient(`http://127.0.0.1:${port}/ready`, 500)), t);
  assert.equal((await getJson(base, '/ready')).status, 502);
  assert.equal((await getJson(base, '/health')).status, 200);
});

for (const bodyStarted of [false, true]) {
  test(`timeout ${bodyStarted ? 'durante corpo' : 'antes dos headers'} retorna 504 sem retry`, async t => {
    let calls = 0;
    const base = await setup(t, (_req, res) => {
      calls++;
      if (bodyStarted) { res.writeHead(200); res.write('{'); }
      // O servidor de teste não termina a resposta. Não há atraso nas APIs.
    }, 100);
    const result = await getJson(base, '/ready');
    assert.equal(result.status, 504);
    assert.equal(result.body.error.code, 'GATEWAY_TIMEOUT');
    assert.equal(calls, 1);
  });
}

test('redirecionamento é rejeitado; erro inesperado recebe 500 seguro', async t => {
  const base = await setup(t, (_req, res) => res.writeHead(302, { location: '/outro' }).end());
  assert.equal((await getJson(base, '/ready')).status, 502);
  const broken = await serve(createApp(async () => { throw new Error('detalhe privado'); }), t);
  assert.deepEqual(await getJson(broken, '/ready'), {
    status: 500, body: { error: { code: 'INTERNAL_ERROR', message: 'Erro interno.' } }
  });
});

test('configuração exige URL sem credenciais e limites positivos', () => {
  assert.equal(readConfig({ DADOS_API_URL: 'http://dados-api:3001' }).httpTimeoutMs, 3000);
  for (const url of ['', 'inválida', 'ftp://dados-api', 'http://usuario@dados-api', 'http://dados-api/path', 'http://dados-api/?x=1']) {
    assert.throws(() => readConfig({ DADOS_API_URL: url }));
  }
  for (const name of ['PORT', 'HTTP_TIMEOUT_MS']) {
    for (const value of ['', '0', '-1', '1.5', 'abc', '9999999999999999999']) {
      assert.throws(() => readConfig({ DADOS_API_URL: 'http://dados-api:3001', [name]: value }));
    }
  }
});

test('processo rejeita configuração inválida sem imprimir o valor recebido', () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('server.js', dist))], {
    env: { ...process.env, DADOS_API_URL: 'http://dados-api:3001', PORT: 'valor-privado-inválido' }, encoding: 'utf8'
  });
  assert.equal(result.status, 1);
  assert.deepEqual(JSON.parse(result.stderr), {
    service: 'pedidos-api', event: 'initialization_failed', field: 'PORT'
  });
});

for (const completeRequest of [true, false]) {
  test(`SIGTERM com requisição ativa: ${completeRequest ? 'conclui e sai com 0' : 'limita espera a 5 segundos'}`,
    { skip: process.platform === 'win32', timeout: 12000 }, async t => {
      let upstreamResponse;
      let notifyRequest;
      const arrived = new Promise(resolve => { notifyRequest = resolve; });
      const dependency = await serve((_req, res) => { upstreamResponse = res; notifyRequest(); }, t);
      const reservation = createServer();
      reservation.listen(0, '127.0.0.1');
      await once(reservation, 'listening');
      const port = reservation.address().port;
      await new Promise(resolve => reservation.close(resolve));
      const child = spawn(process.execPath, [fileURLToPath(new URL('server.js', dist))], {
        env: { ...process.env, HOST: '127.0.0.1', PORT: String(port), DADOS_API_URL: dependency, HTTP_TIMEOUT_MS: '10000' },
        stdio: ['ignore', 'pipe', 'pipe']
      });
      t.after(() => { if (child.exitCode === null) child.kill('SIGKILL'); });
      const finished = once(child, 'exit');
      const [output] = await once(child.stdout, 'data');
      assert.equal(JSON.parse(output).event, 'listening');
      const response = fetch(`http://127.0.0.1:${port}/ready`).catch(() => null);
      await arrived;
      const start = Date.now();
      child.kill('SIGTERM');
      if (completeRequest) upstreamResponse.end(JSON.stringify({ status: 'ok', service: 'dados-api' }));
      const [code, signal] = await finished;
      assert.equal(signal, null);
      assert.equal(code, completeRequest ? 0 : 1);
      if (completeRequest) {
        assert.equal((await response)?.status, 200);
        assert.ok(Date.now() - start < 5000);
      } else {
        assert.equal(await response, null);
        assert.ok(Date.now() - start >= 4500 && Date.now() - start < 8000);
      }
    });
}
