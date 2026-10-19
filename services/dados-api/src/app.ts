import express, { type ErrorRequestHandler } from 'express';
import { logFailure } from './log.js';

export function createApp(checkDatabase: () => Promise<void>) {
  const app = express();
  app.disable('x-powered-by');
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', service: 'dados-api' });
  });
  app.get('/ready', async (_req, res) => {
    res.set('Cache-Control', 'no-store');
    try {
      await checkDatabase();
      res.json({ status: 'ok', service: 'dados-api' });
    } catch (error) {
      logFailure('database_not_ready', error);
      res.status(503).json({ error: { code: 'DATABASE_UNAVAILABLE', message: 'Banco indisponível.' } });
    }
  });
  app.use((_req, res) => {
    res.status(404).json({ error: { code: 'NOT_FOUND', message: 'Rota não encontrada.' } });
  });
  const handleError: ErrorRequestHandler = (error, _req, res, _next) => {
    logFailure('internal_error', error);
    res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'Erro interno.' } });
  };
  app.use(handleError);
  return app;
}
