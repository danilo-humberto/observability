-- Apenas as três estruturas SQL atuais da aplicação. Sem queryid fixo,
-- sem SELECT 1, probes ou consultas do monitoramento. Não reseta estatísticas.
WITH expected(kind, statement) AS (
    VALUES
      ('pedidos', 'SELECT id, client_id, description, amount, created_at FROM orders ORDER BY id ASC LIMIT $1'),
      ('cliente', 'SELECT id, name FROM clients WHERE id = $1'),
      ('join', 'SELECT o.id, o.client_id, o.description, o.amount, o.created_at, c.id AS joined_client_id, c.name FROM orders o INNER JOIN clients c ON c.id = o.client_id ORDER BY o.id ASC LIMIT $1')
)
SELECT e.kind, s.queryid::text, s.query, s.calls,
       s.total_exec_time AS total_exec_ms, s.rows, s.stats_since
FROM pg_stat_statements s
JOIN expected e ON regexp_replace(trim(s.query), '\s+', ' ', 'g') = e.statement
WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND s.userid = (SELECT oid FROM pg_roles WHERE rolname = 'postgres')
  AND s.toplevel
ORDER BY e.kind;
