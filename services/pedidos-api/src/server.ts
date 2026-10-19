import { createApp } from "./app.js";
import { ConfigurationError, readConfig } from "./config.js";
import { createDadosClient, createOrdersClient } from "./dados-client.js";
import { logFailure } from "./log.js";
import { shutdownTelemetry } from "./telemetry.js";

try {
  const config = readConfig();
  const server = createApp(
    createDadosClient(config.readyUrl, config.httpTimeoutMs),
    createOrdersClient(config.readyUrl, config.httpTimeoutMs),
  ).listen(config.port, config.host, () => {
    console.log(
      JSON.stringify({
        service: "pedidos-api",
        event: "listening",
        port: config.port,
      }),
    );
  });
  server.on("error", (error) => {
    logFailure("server_failed", error);
    process.exit(1);
  });
  let stopping = false;
  function stop() {
    if (stopping) return;
    stopping = true;
    const deadline = setTimeout(() => process.exit(1), 5000);
    deadline.unref();
    server.close(() => {
      void shutdownTelemetry().then(() => {
        clearTimeout(deadline);
        process.exit(0);
      }).catch((error: unknown) => {
        logFailure("shutdown_failed", error);
        process.exit(1);
      });
    });
  }
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
} catch (error) {
  console.error(
    JSON.stringify({
      service: "pedidos-api",
      event: "initialization_failed",
      field: error instanceof ConfigurationError ? error.field : undefined,
    }),
  );
  process.exitCode = 1;
}
