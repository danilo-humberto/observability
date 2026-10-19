import express, { type ErrorRequestHandler } from 'express';
import { DependencyError } from './dados-client.js';
import { logFailure } from './log.js';

export function createApp(checkDados: () => Promise<void>) {
  const app = express();
  app.disable('x-powered-by');
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', service: 'pedidos-api' });
  });
  app.get('/ready', async (_req, res) => {
    res.set('Cache-Control', 'no-store');
    await checkDados();
    res.json({ status: 'ok', service: 'pedidos-api' });
  });
  app.use((_req, res) => {
    res.status(404).json({ error: { code: 'NOT_FOUND', message: 'Rota não encontrada.' } });
  });
  const handleError: ErrorRequestHandler = (error, _req, res, _next) => {
    logFailure('request_failed', error);
    if (error instanceof DependencyError) {
      res.status(error.status).json({ error: { code: error.code, message: error.message } });
      return;
    }
    res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'Erro interno.' } });
  };
  app.use(handleError);
  return app;
}
