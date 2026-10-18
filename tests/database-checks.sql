\set ON_ERROR_STOP on

DO $$
DECLARE
    statement text;
BEGIN
    IF EXISTS (
        SELECT 1 FROM orders o LEFT JOIN clients c ON c.id = o.client_id
        WHERE c.id IS NULL
    ) THEN
        RAISE EXCEPTION 'Pedido sem cliente existente';
    END IF;

    BEGIN
        INSERT INTO orders (id, client_id, description, amount, created_at) OVERRIDING SYSTEM VALUE
        VALUES (-1, 1, 'Constraint test', -0.01, '2024-01-01+00');
        RAISE EXCEPTION 'Valor negativo foi aceito';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    BEGIN
        INSERT INTO orders (id, client_id, description, amount, created_at) OVERRIDING SYSTEM VALUE
        VALUES (-1, -1, 'Constraint test', 1, '2024-01-01+00');
        RAISE EXCEPTION 'Cliente inexistente foi aceito';
    EXCEPTION WHEN foreign_key_violation THEN
        NULL;
    END;

    FOREACH statement IN ARRAY ARRAY[
        'INSERT INTO clients (id, name, created_at) OVERRIDING SYSTEM VALUE VALUES (NULL, ''Test'', now())',
        'INSERT INTO clients (id, name, created_at) OVERRIDING SYSTEM VALUE VALUES (-1, NULL, now())',
        'INSERT INTO clients (id, name, created_at) OVERRIDING SYSTEM VALUE VALUES (-1, ''Test'', NULL)',
        'INSERT INTO orders (id, client_id, description, amount, created_at) OVERRIDING SYSTEM VALUE VALUES (NULL, 1, ''Test'', 1, now())',
        'INSERT INTO orders (id, client_id, description, amount, created_at) OVERRIDING SYSTEM VALUE VALUES (-1, NULL, ''Test'', 1, now())',
        'INSERT INTO orders (id, client_id, description, amount, created_at) OVERRIDING SYSTEM VALUE VALUES (-1, 1, NULL, 1, now())',
        'INSERT INTO orders (id, client_id, description, amount, created_at) OVERRIDING SYSTEM VALUE VALUES (-1, 1, ''Test'', NULL, now())',
        'INSERT INTO orders (id, client_id, description, amount, created_at) OVERRIDING SYSTEM VALUE VALUES (-1, 1, ''Test'', 1, NULL)'
    ] LOOP
        BEGIN
            EXECUTE statement;
            RAISE EXCEPTION 'Campo obrigatório aceitou NULL: %', statement;
        EXCEPTION WHEN not_null_violation THEN
            NULL;
        END;
    END LOOP;

    -- Cada ambiente validado tem pelo menos um cliente com pedido.
    IF EXISTS (SELECT 1 FROM orders) THEN
        BEGIN
            DELETE FROM clients WHERE id = 1;
            RAISE EXCEPTION 'Exclusão de cliente com pedido foi aceita';
        EXCEPTION WHEN foreign_key_violation THEN
            NULL;
        END;
    END IF;
END
$$;
