export function logFailure(event: string, error: unknown): void {
  const candidate = (error as { code?: unknown } | null)?.code;
  const code = typeof candidate === 'string' && /^[A-Z0-9_]{1,40}$/.test(candidate)
    ? candidate : 'UNKNOWN';
  console.error(JSON.stringify({ service: 'dados-api', event, code }));
}
