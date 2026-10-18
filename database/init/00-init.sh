#!/bin/sh
# A imagem oficial pode executar ou carregar este arquivo com source.
# Use um subshell para não alterar as opções do entrypoint.
(
    set -eu

    validate_count() {
        name=$1
        value=$2
        minimum=$3
        case "$value" in
            ''|*[!0-9]*)
                printf '%s deve ser um inteiro entre %s e 2147483647.\n' "$name" "$minimum" >&2
                exit 1
                ;;
        esac
        if [ "${#value}" -gt 10 ] || [ "$value" -lt "$minimum" ] || [ "$value" -gt 2147483647 ]; then
            printf '%s deve ser um inteiro entre %s e 2147483647.\n' "$name" "$minimum" >&2
            exit 1
        fi
    }

    validate_count CLIENTS_COUNT "$CLIENTS_COUNT" 1
    validate_count ORDERS_COUNT "$ORDERS_COUNT" 0

    psql -X --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        --set=ON_ERROR_STOP=1 --single-transaction \
        --set=clients_count="$CLIENTS_COUNT" --set=orders_count="$ORDERS_COUNT" \
        --file=/opt/database/schema.sql --file=/opt/database/seed.sql
)
