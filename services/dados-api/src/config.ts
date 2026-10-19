export class ConfigurationError extends Error {
  constructor(public readonly field: string) { super(`Configuração inválida: ${field}`); }
}

export function readConfig(env: NodeJS.ProcessEnv = process.env) {
  function required(name: string): string {
    const value = env[name];
    if (!value?.trim()) throw new ConfigurationError(name);
    return value;
  }
  function integer(name: string, fallback: number, max = 2147483647): number {
    const value = env[name] ?? String(fallback);
    const number = Number(value);
    if (!/^\d+$/.test(value) || !Number.isSafeInteger(number) || number < 1 || number > max) {
      throw new ConfigurationError(name);
    }
    return number;
  }
  const host = env.HOST ?? '0.0.0.0';
  if (!host.trim()) throw new ConfigurationError('HOST');
  return {
    host,
    port: integer('PORT', 3001, 65535),
    database: {
      host: required('PGHOST'),
      port: integer('PGPORT', 5432, 65535),
      database: required('PGDATABASE'),
      user: required('PGUSER'),
      password: required('PGPASSWORD'),
      max: integer('PGPOOL_MAX', 10),
      connectionTimeoutMillis: integer('PGCONNECT_TIMEOUT_MS', 1000),
      statement_timeout: integer('PGSTATEMENT_TIMEOUT_MS', 1000),
      application_name: 'dados-api'
    }
  };
}
