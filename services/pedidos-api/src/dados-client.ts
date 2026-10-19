import { isOrders, type Order, type OrderMode } from "./orders.js";

export class DependencyError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

async function request(url: string, timeoutMs: number): Promise<unknown> {
  const signal = AbortSignal.timeout(timeoutMs);
  try {
    const response = await fetch(url, { signal, redirect: "error" });
    const body: unknown = await response.json();
    if (
      response.status === 503 &&
      typeof body === "object" &&
      body !== null &&
      "error" in body &&
      typeof body.error === "object" &&
      body.error !== null &&
      "code" in body.error &&
      body.error.code === "DATABASE_UNAVAILABLE" &&
      "message" in body.error &&
      typeof body.error.message === "string"
    ) {
      throw new DependencyError(
        503,
        "DEPENDENCY_UNAVAILABLE",
        "Serviço de dados indisponível.",
      );
    }
    if (response.status !== 200) {
      throw new DependencyError(
        502,
        "BAD_GATEWAY",
        "Resposta inválida do serviço de dados.",
      );
    }
    return body;
  } catch (error) {
    if (signal.aborted) {
      throw new DependencyError(
        504,
        "GATEWAY_TIMEOUT",
        "Tempo de espera do serviço de dados excedido.",
      );
    }
    if (error instanceof DependencyError) throw error;
    throw new DependencyError(
      502,
      "BAD_GATEWAY",
      "Falha na comunicação com o serviço de dados.",
    );
  }
}

export function createDadosClient(readyUrl: string, timeoutMs: number) {
  return async function check(): Promise<void> {
    const body = await request(readyUrl, timeoutMs);
    if (
      typeof body !== "object" ||
      body === null ||
      !("status" in body) ||
      body.status !== "ok" ||
      !("service" in body) ||
      body.service !== "dados-api"
    ) {
      throw new DependencyError(
        502,
        "BAD_GATEWAY",
        "Resposta inválida do serviço de dados.",
      );
    }
  };
}

export function createOrdersClient(baseUrl: string, timeoutMs: number) {
  return async function list(mode: OrderMode, limit: number): Promise<Order[]> {
    const url = new URL(`/pedidos/${mode}`, baseUrl);
    url.searchParams.set("limit", String(limit));
    const body = await request(url.href, timeoutMs);
    if (!isOrders(body, limit)) {
      throw new DependencyError(
        502,
        "BAD_GATEWAY",
        "Resposta inválida do serviço de dados.",
      );
    }
    return body;
  };
}
