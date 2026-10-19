export class ConfigurationError extends Error {
  constructor(public readonly field: string) { super(`Configuração inválida: ${field}`); }
}

export function readConfig(env: NodeJS.ProcessEnv = process.env) {
  function integer(name: string, fallback: number, max = 2147483647): number {
    const value = env[name] ?? String(fallback);
    const number = Number(value);
    if (!/^\d+$/.test(value) || !Number.isSafeInteger(number) || number < 1 || number > max) {
      throw new ConfigurationError(name);
    }
    return number;
  }
  let base: URL;
  try { base = new URL(env.DADOS_API_URL ?? ''); }
  catch { throw new ConfigurationError('DADOS_API_URL'); }
  if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password ||
      base.search || base.hash || base.pathname !== '/') {
    throw new ConfigurationError('DADOS_API_URL');
  }
  const host = env.HOST ?? '0.0.0.0';
  if (!host.trim()) throw new ConfigurationError('HOST');
  return {
    host,
    port: integer('PORT', 3000, 65535),
    readyUrl: new URL('/ready', base).href,
    httpTimeoutMs: integer('HTTP_TIMEOUT_MS', 3000)
  };
}
