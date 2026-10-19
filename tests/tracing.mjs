import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';

const api = 'http://pedidos-api:3000';
const jaeger = 'http://jaeger:16686';
const secret = process.env.TEST_SECRET;
assert.ok(secret, 'Credencial efêmera necessária para verificar ausência nos traces');
const markers = [secret, 'fictional-header-marker', 'fictional-query-marker', 'fictional-path-marker'];
const traceId = n => 'abcdef0123456789' + n.toString(16).padStart(16, '0');
const parentId = '1234567890abcdef';
const headers = n => ({
  traceparent: `00-${traceId(n)}-${parentId}-01`,
  authorization: `Bearer ${secret}`,
  cookie: 'session=fictional-header-marker',
  'x-test-secret': 'fictional-header-marker',
  tracestate: 'test=fictional-header-marker',
});

async function json(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(5000) });
  assert.equal(response.status, 200);
  return response.json();
}
async function waitFor(check, description, timeout = 30000) {
  const deadline = Date.now() + timeout;
  let last;
  do {
    try { return await check(); } catch (error) { last = error; }
    await delay(250);
  } while (Date.now() < deadline);
  throw new Error(`Prazo excedido: ${description}`, { cause: last });
}
function assertPrivate(data) {
  const raw = JSON.stringify(data);
  for (const marker of markers) assert.ok(!raw.includes(marker), 'Marcador sensível exportado');
  assert.ok(!/url\.query|url\.full|http\.url|http\.target|http\.request\.header|db\.query\.parameter|exception\.message/.test(raw), 'Atributo proibido exportado');
}
async function getTrace(n) {
  return getTraceById(traceId(n));
}
async function getTraceById(id) {
  const response = await fetch(`${jaeger}/api/traces/${id}`, { signal: AbortSignal.timeout(5000) });
  if (response.status === 404) return undefined;
  assert.equal(response.status, 200);
  const body = await response.json();
  assertPrivate(body);
  return body.data?.[0];
}
const tags = span => Object.fromEntries(span.tags.map(tag => [tag.key, tag.value]));
const serviceOf = (trace, span) => trace.processes[span.processID].serviceName;

function assertTree(trace, n, count, mode, { failed = false, root = false } = {}) {
  assert.ok(trace);
  const spans = trace.spans;
  const byId = new Map(spans.map(span => [span.spanID, span]));
  const sql = spans.filter(span => tags(span)['db.query.text']);
  assert.equal(sql.length, count, 'Contagem de spans SQL');
  assert.equal(new Set(spans.map(span => span.spanID)).size, spans.length, 'Spans duplicados');
  for (const span of spans) {
    assert.equal(span.traceID, typeof n === 'string' ? n : traceId(n));
    assert.ok(['pedidos-api', 'dados-api'].includes(serviceOf(trace, span)));
    assert.ok(!span.operationName.includes('connect'), 'Span de conexão inesperado');
    const parent = span.references.find(ref => ref.refType === 'CHILD_OF');
    if (!parent) {
      assert.ok(root && tags(span)['span.kind'] === 'server' && serviceOf(trace, span) === 'pedidos-api', 'Span sem relação com o pai');
    } else {
      assert.ok((!root && parent.spanID === parentId) || byId.has(parent.spanID), 'Pai ausente no trace');
    }
  }
  const servers = spans.filter(span => tags(span)['span.kind'] === 'server');
  assert.equal(servers.length, 2, 'Uma entrada HTTP por API');
  const entry = servers.find(span => serviceOf(trace, span) === 'pedidos-api');
  const dataEntry = servers.find(span => serviceOf(trace, span) === 'dados-api');
  if (root) assert.equal(entry.references.length, 0);
  else assert.equal(entry.references[0].spanID, parentId);
  const client = spans.find(span => tags(span)['span.kind'] === 'client' && serviceOf(trace, span) === 'pedidos-api');
  assert.ok(client, 'Span do fetch ausente');
  assert.equal(dataEntry.references[0].spanID, client.spanID, 'Contexto não propagado pelo fetch');
  for (const span of sql) {
    assert.equal(serviceOf(trace, span), 'dados-api');
    // Follow the ancestry, allowing Express to add an intermediate handler span.
    let ancestor = span;
    const seen = new Set();
    while (ancestor && ancestor.spanID !== dataEntry.spanID) {
      assert.ok(!seen.has(ancestor.spanID), 'Ciclo de spans');
      seen.add(ancestor.spanID);
      ancestor = byId.get(ancestor.references.find(ref => ref.refType === 'CHILD_OF')?.spanID);
    }
    assert.equal(ancestor?.spanID, dataEntry.spanID, 'SQL fora da requisição da dados-api');
  }
  if (!failed) {
    assert.ok(sql.every(span => tags(span)['db.query.text'].includes('$1')), 'SQL deve permanecer parametrizado');
    assert.equal(sql.filter(span => tags(span)['db.query.text'].includes('INNER JOIN')).length, mode === 'otimizado' ? 1 : 0);
  }
  assertPrivate(trace);
  return trace;
}
async function waitTrace(n, count, mode, options) {
  return waitFor(async () => assertTree(await getTrace(n), n, count, mode, options), `trace ${n} completo`);
}
async function request(n, path, expectedStatus = 200, base = api) {
  const response = await fetch(base + path, { headers: headers(n), signal: AbortSignal.timeout(40000) });
  assert.equal(response.status, expectedStatus, `HTTP em ${path.split('?')[0]}`);
  return response.json();
}
async function searchTraces(service) {
    const query = new URLSearchParams({
      'query.serviceName': service,
      'query.startTimeMin': new Date(Date.now() - 3600000).toISOString(),
      'query.startTimeMax': new Date().toISOString(),
      'query.searchDepth': '100',
    });
    return json(`${jaeger}/api/v3/traces?${query}`);
}
async function checkNoProbes() {
  const services = await json(`${jaeger}/api/v3/services`);
  assert.deepEqual(services.services.sort(), ['dados-api', 'pedidos-api']);
  for (const service of services.services) {
    const traces = await searchTraces(service);
    assertPrivate(traces);
    for (const resource of traces.result?.resourceSpans ?? []) {
      for (const span of resource.scopeSpans.flatMap(scope => scope.spans ?? [])) {
        assert.ok(!JSON.stringify(span).includes('SELECT 1'), 'Consulta órfã de prontidão');
        assert.ok(!/\/ready|\/health/.test(JSON.stringify(span)), 'Probe exportado');
        assert.ok(span.parentSpanId, 'Span órfão inesperado');
      }
    }
  }
}

const stage = process.argv[2];
if (stage === 'verify') {
  await waitFor(() => json(`${jaeger}/api/v3/services`), 'Jaeger pronto');
  for (const [limit, first] of [[100, 100], [1000, 1000]]) {
    const slow = await request(first, `/pedidos/lento?limit=${limit}&extra=fictional-query-marker`);
    const fast = await request(first + 1, `/pedidos/otimizado?limit=${limit}`);
    assert.equal(slow.length, limit);
    assert.deepEqual(slow, fast);
    await waitTrace(first, limit + 1, 'lento');
    await waitTrace(first + 1, 1, 'otimizado');
    console.log(`PASS ${limit} pedidos: respostas idênticas; ${limit + 1} consultas contra uma no mesmo trace das duas APIs`);
  }
  const probes = [];
  const unknownPaths = [];
  for (const [base, service] of [[api, 'pedidos-api'], ['http://dados-api:3001', 'dados-api']]) {
    for (const path of ['/health', '/ready', '/health/', '/ready/', '/HEALTH', '/READY',
      '/HeAlTh/', '/ReAdY/', '/HeAlTh/?extra=fictional-query-marker', '/ReAdY/?extra=fictional-query-marker']) {
      const id = 700 + probes.length;
      assert.deepEqual(await request(id, path, 200, base), { status: 'ok', service });
      probes.push({ id, path, service });
    }
    // Caminhos parecidos não são probes e devem continuar sendo rastreados.
    for (const path of ['/healthcheck', '/ready/extra', '/ready//']) {
      const id = 800 + unknownPaths.length;
      const body = await request(id, path, 404, base);
      assert.equal(body.error.code, 'NOT_FOUND');
      unknownPaths.push({ id, path, service });
    }
  }
  // Unknown paths and errors must not leak their raw path, query or headers.
  await request(204, '/fictional-path-marker?extra=fictional-query-marker', 404);
  await request(205, '/pedidos/lento?limit=invalid&extra=fictional-query-marker', 400);
  const unsampled = await fetch(`${api}/pedidos/otimizado?limit=1`, {
    headers: { ...headers(206), traceparent: `00-${traceId(206)}-${parentId}-00` },
    signal: AbortSignal.timeout(5000),
  });
  assert.equal(unsampled.status, 200);
  await unsampled.json();
  await waitFor(async () => assert.ok(await getTrace(205)), 'trace de erro de validação');
  await delay(2500);
  for (const { id, path, service } of probes) {
    assert.equal(await getTrace(id), undefined, `Probe gerou trace: ${service} ${path}`);
  }
  for (const { id, path, service } of unknownPaths) {
    await waitFor(async () => assert.ok(await getTrace(id)), `trace de ${service} ${path}`);
  }
  assert.equal(await getTrace(206), undefined, 'Contexto não amostrado tem trace');
  const unknown = await getTrace(204);
  assert.ok(unknown, 'Rota desconhecida não foi instrumentada');
  assertPrivate(unknown);
  await checkNoProbes();
  console.log('PASS probes com variações de caixa, barra final e query não geram traces; caminhos semelhantes continuam rastreados');
  console.log('PASS propagação, relações, ausência de probes e de marcadores sensíveis nos traces');
  const listedIds = data => new Set((data.result?.resourceSpans ?? []).flatMap(resource => resource.scopeSpans.flatMap(scope => scope.spans.map(span => span.traceId))));
  const before = listedIds(await searchTraces('pedidos-api'));
  const local = await fetch(`${api}/pedidos/otimizado?limit=1`, { signal: AbortSignal.timeout(5000) });
  assert.equal(local.status, 200);
  await local.json();
  await waitFor(async () => {
    const created = [...listedIds(await searchTraces('pedidos-api'))].filter(id => !before.has(id));
    assert.equal(created.length, 1, 'Uma chamada local deve criar um trace');
    return assertTree(await getTraceById(created[0]), created[0], 1, 'otimizado', { root: true });
  }, 'trace raiz sem contexto externo');
  console.log('PASS sampler grava chamada sem contexto e respeita pai remoto não amostrado');
} else if (stage === 'offline') {
  const slow = await request(300, '/pedidos/lento?limit=100');
  const fast = await request(301, '/pedidos/otimizado?limit=100');
  assert.equal(slow.length, 100);
  assert.deepEqual(slow, fast);
  await delay(3500); // Allow attempted exports to exercise the unavailable receiver.
  console.log('PASS APIs atendem com Jaeger indisponível');
} else if (stage === 'recovered') {
  await waitFor(() => json(`${jaeger}/api/v3/services`), 'Jaeger recuperado');
  for (const n of [100, 101, 1000, 1001]) assert.equal(await getTrace(n), undefined, 'Histórico sobreviveu ao reinício');
  await request(400, '/pedidos/otimizado?limit=100');
  await waitTrace(400, 1, 'otimizado');
  console.log('PASS histórico em memória descartado e novas requisições exportadas após recuperação');
} else if (stage === 'database-error') {
  const body = await request(500, '/pedidos/lento?limit=100&extra=fictional-query-marker', 503);
  assert.equal(body.error.code, 'DEPENDENCY_UNAVAILABLE');
  // The pool cannot acquire a connection: no SQL reached PostgreSQL.
  // With connect spans disabled, the failure is represented by the HTTP spans.
  const trace = await waitTrace(500, 0, 'lento', { failed: true });
  assert.ok(trace.spans.some(span => tags(span).error === true), 'Erro ausente no trace');
  assertPrivate(trace);
  console.log('PASS falha real do banco rastreada sem detalhes sensíveis');
} else if (stage === 'before-shutdown') {
  await request(600, '/pedidos/otimizado?limit=1');
  assert.equal(await getTrace(600), undefined, 'Spans deveriam estar pendentes antes do encerramento');
} else if (stage === 'after-shutdown') {
  await waitTrace(600, 1, 'otimizado');
  console.log('PASS encerramento exporta spans pendentes das duas APIs');
} else {
  throw new Error('Etapa de teste desconhecida');
}
