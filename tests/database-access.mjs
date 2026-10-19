// Executado via stdin dentro da dados-api, com a credencial real da aplicação.
import assert from 'node:assert/strict';
import pg from 'pg';

const client = new pg.Client({ connectionTimeoutMillis: 3000, statement_timeout: Number(process.env.PGSTATEMENT_TIMEOUT_MS) });
try {
  await client.connect();
  assert.equal((await client.query('SELECT current_user AS name')).rows[0].name, 'postgres');
  for (const table of ['clients', 'orders']) {
    assert.ok((await client.query(`SELECT count(*)::int AS count FROM ${table}`)).rows[0].count >= 0);
  }
  const timeout = Date.now();
  await assert.rejects(client.query('SELECT pg_sleep(5)'), error => error.code === '57014');
  assert.ok(Date.now() - timeout < 4500, 'statement_timeout real não foi aplicado');
  console.log('PASS acesso como postgres, leitura e timeout SQL real');
} finally { await client.end(); }
