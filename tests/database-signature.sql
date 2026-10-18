-- Compara conteúdo completo e ordem por ID, incluindo datas em UTC.
-- MD5 serve como assinatura de comparação, não como proteção de segurança.
SET TIME ZONE 'UTC';
SELECT 'clients|' || count(*) || '|' ||
       md5(coalesce(string_agg(row_to_json(c)::text, E'\n' ORDER BY id), ''))
FROM clients c;
SELECT 'orders|' || count(*) || '|' ||
       md5(coalesce(string_agg(row_to_json(o)::text, E'\n' ORDER BY id), ''))
FROM orders o;
-- Sequences não são revertidas por rollback; conferir seus estados também.
SELECT 'clients_id_seq|' || last_value || '|' || is_called FROM clients_id_seq;
SELECT 'orders_id_seq|' || last_value || '|' || is_called FROM orders_id_seq;
