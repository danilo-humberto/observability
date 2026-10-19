import { NodeSDK } from "@opentelemetry/sdk-node";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-proto";
import {
  BatchSpanProcessor,
  type SpanExporter,
  type ReadableSpan,
} from "@opentelemetry/sdk-trace-base";
import { HttpInstrumentation } from "@opentelemetry/instrumentation-http";
import { ExpressInstrumentation } from "@opentelemetry/instrumentation-express";
import { PgInstrumentation } from "@opentelemetry/instrumentation-pg";

const service = "dados-api";
const routes = new Set(["/pedidos/lento", "/pedidos/otimizado"]);
const attributes = new Set([
  "http.route",
  "http.method",
  "http.status_code",
  "http.request.method",
  "http.response.status_code",
  "db.system.name",
  "db.namespace",
  "db.operation.name",
  "db.query.text",
]);

function isProbe(path: string): boolean {
  // Espelha o Express: ignora caixa e aceita uma barra final opcional.
  return /^\/(?:health|ready)\/?$/i.test(path.split("?")[0] ?? "");
}

// Allowlist at the export boundary: hooks alone cannot remove late error events.
function sanitize(span: ReadableSpan): ReadableSpan {
  const route = span.attributes["http.route"];
  const safeRoute =
    typeof route === "string" && routes.has(route) ? route : undefined;
  const safeAttributes = Object.fromEntries(
    Object.entries(span.attributes).filter(
      ([key]) =>
        attributes.has(key) &&
        (key !== "http.route" || safeRoute !== undefined),
    ),
  );
  const context = span.spanContext();
  return {
    kind: span.kind,
    startTime: span.startTime,
    endTime: span.endTime,
    duration: span.duration,
    ended: span.ended,
    parentSpanContext: span.parentSpanContext && {
      traceId: span.parentSpanContext.traceId,
      spanId: span.parentSpanContext.spanId,
      traceFlags: span.parentSpanContext.traceFlags,
    },
    instrumentationScope: {
      name: span.instrumentationScope.name,
      version: span.instrumentationScope.version,
    },
    droppedAttributesCount: span.droppedAttributesCount,
    droppedEventsCount: span.droppedEventsCount,
    droppedLinksCount: span.droppedLinksCount,
    name: span.attributes["db.query.text"]
      ? "SELECT observability"
      : (safeRoute ?? "HTTP"),
    attributes: safeAttributes,
    status: { code: span.status.code },
    events: [],
    links: [],
    resource: resourceFromAttributes({ "service.name": service }),
    spanContext: () => ({
      traceId: context.traceId,
      spanId: context.spanId,
      traceFlags: context.traceFlags,
    }),
  };
}

const exporter = new OTLPTraceExporter({ timeoutMillis: 1000 });
const safeExporter: SpanExporter = {
  export(spans, callback) {
    exporter.export(spans.map(sanitize), (result) => {
      if (result.code !== 0)
        console.error(
          JSON.stringify({ service, event: "trace_export_failed" }),
        );
      callback({ code: result.code });
    });
  },
  shutdown: () => exporter.shutdown(),
};

const sdk = new NodeSDK({
  resource: resourceFromAttributes({ "service.name": service }),
  autoDetectResources: false,
  spanProcessors: [
    new BatchSpanProcessor(safeExporter, {
      maxQueueSize: 4096,
      maxExportBatchSize: 512,
      exportTimeoutMillis: 1000,
    }),
  ],
  // No metric reader or log processor: this stage exports only traces.
  logRecordProcessors: [],
  instrumentations: [
    new HttpInstrumentation({
      ignoreIncomingRequestHook: (req) => isProbe(req.url ?? ""),
    }),
    new ExpressInstrumentation(),
    new PgInstrumentation({
      requireParentSpan: true,
      ignoreConnectSpans: true,
      enhancedDatabaseReporting: false,
      addSqlCommenterCommentToQueries: false,
    }),
  ],
});
sdk.start();

export async function shutdownTelemetry(): Promise<void> {
  await sdk.shutdown();
}
