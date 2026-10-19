import pg from 'pg';
import type { readConfig } from './config.js';
import { logFailure } from './log.js';

export function createDatabase(config: ReturnType<typeof readConfig>['database']) {
  const pool = new pg.Pool(config);
  pool.on('error', (error) => logFailure('database_idle_connection_failed', error));
  return {
    async check(): Promise<void> { await pool.query('SELECT 1'); },
    async close(): Promise<void> { await pool.end(); }
  };
}
