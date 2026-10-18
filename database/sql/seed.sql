-- Parâmetros validados por init/00-init.sh. Executado junto ao modelo,
-- na mesma transação, somente na inicialização de um volume vazio.
INSERT INTO clients (name, created_at)
SELECT
    'Client ' || n,
    TIMESTAMPTZ '2024-01-01 00:00:00+00' + (n - 1) * INTERVAL '1 minute'
FROM generate_series(1, :clients_count) AS series(n)
ORDER BY n;

INSERT INTO orders (client_id, description, amount, created_at)
SELECT
    ((n - 1) % :clients_count) + 1,
    'Order ' || n,
    (((n::bigint * 137) % 100000) + 1)::numeric / 100,
    TIMESTAMPTZ '2024-02-01 00:00:00+00' + (n - 1) * INTERVAL '1 minute'
FROM generate_series(1, :orders_count) AS series(n)
ORDER BY n;
