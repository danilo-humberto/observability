-- Idempotente, inclusive em volumes anteriores à Etapa 6.
-- O preload depende do comando de partida do PostgreSQL no Compose.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
