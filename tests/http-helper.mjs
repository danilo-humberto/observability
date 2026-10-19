import { once } from 'node:events';
import { createServer } from 'node:http';

export async function serve(handler, test) {
  const server = createServer(handler);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  test.after(() => new Promise((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
    server.closeAllConnections();
  }));
  return `http://127.0.0.1:${server.address().port}`;
}

export async function getJson(base, path) {
  const response = await fetch(base + path, { signal: AbortSignal.timeout(5000) });
  return { status: response.status, body: await response.json() };
}
