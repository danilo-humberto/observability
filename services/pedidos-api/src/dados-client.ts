export class DependencyError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message);
  }
}

export function createDadosClient(readyUrl: string, timeoutMs: number) {
  return async function check(): Promise<void> {
    const signal = AbortSignal.timeout(timeoutMs);
    try {
      const response = await fetch(readyUrl, { signal, redirect: 'error' });
      // Consumir o corpo dentro do mesmo prazo também limita respostas que não terminam.
      const body: unknown = await response.json();
      if (response.status === 503 && typeof body === 'object' && body !== null &&
          'error' in body && typeof body.error === 'object' && body.error !== null &&
          'code' in body.error && body.error.code === 'DATABASE_UNAVAILABLE' &&
          'message' in body.error && typeof body.error.message === 'string') {
        throw new DependencyError(503, 'DEPENDENCY_UNAVAILABLE', 'Serviço de dados indisponível.');
      }
      if (response.status !== 200 || typeof body !== 'object' || body === null ||
          !('status' in body) || body.status !== 'ok' ||
          !('service' in body) || body.service !== 'dados-api') {
        throw new DependencyError(502, 'BAD_GATEWAY', 'Resposta inválida do serviço de dados.');
      }
    } catch (error) {
      if (signal.aborted) {
        throw new DependencyError(504, 'GATEWAY_TIMEOUT', 'Tempo de espera do serviço de dados excedido.');
      }
      if (error instanceof DependencyError) throw error;
      throw new DependencyError(502, 'BAD_GATEWAY', 'Falha na comunicação com o serviço de dados.');
    }
  };
}
