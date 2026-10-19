import express, { type ErrorRequestHandler } from "express";
import { DependencyError } from "./dados-client.js";
import { logFailure } from "./log.js";
import { parseLimit } from "./limit.js";
import type { Order, OrderMode } from "./orders.js";

export function createApp(
  checkDados: () => Promise<void>,
  listOrders: (
    mode: OrderMode,
    limit: number,
  ) => Promise<Order[]> = async () => {
    throw new Error("Consulta não configurada.");
  },
) {
  const app = express();
  app.disable("x-powered-by");
  app.set("query parser", "simple");
  for (const mode of ["lento", "otimizado"] as const) {
    app.get(`/pedidos/${mode}`, async (req, res) => {
      res.set("Cache-Control", "no-store");
      const limit = parseLimit(req.query.limit);
      const structured = Object.keys(req.query).some((key) =>
        key.startsWith("limit["),
      );
      if (limit === undefined || structured) {
        res
          .status(400)
          .json({
            error: {
              code: "INVALID_LIMIT",
              message: "limit deve ser um inteiro entre 1 e 1000.",
            },
          });
        return;
      }
      res.json(await listOrders(mode, limit));
    });
  }
  app.get("/health", (_req, res) => {
    res.json({ status: "ok", service: "pedidos-api" });
  });
  app.get("/ready", async (_req, res) => {
    res.set("Cache-Control", "no-store");
    await checkDados();
    res.json({ status: "ok", service: "pedidos-api" });
  });
  app.use((_req, res) => {
    res
      .status(404)
      .json({ error: { code: "NOT_FOUND", message: "Rota não encontrada." } });
  });
  const handleError: ErrorRequestHandler = (error, _req, res, _next) => {
    logFailure("request_failed", error);
    if (error instanceof DependencyError) {
      res
        .status(error.status)
        .json({ error: { code: error.code, message: error.message } });
      return;
    }
    res
      .status(500)
      .json({ error: { code: "INTERNAL_ERROR", message: "Erro interno." } });
  };
  app.use(handleError);
  return app;
}
