#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../lib/validate-nextcloud-state.jq"
FIXTURES="$SCRIPT_DIR/fixtures"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERRO: jq nao encontrado" >&2
    exit 11
fi

assert_valid() {
    local fixture="$1"

    if ! jq -e -f "$VALIDATOR" "$fixture" >/dev/null; then
        echo "ERRO: fixture deveria ser valida: $fixture" >&2
        exit 1
    fi
}

assert_invalid() {
    local fixture="$1"

    if jq -e -f "$VALIDATOR" "$fixture" >/dev/null 2>&1; then
        echo "ERRO: fixture deveria ser invalida: $fixture" >&2
        exit 1
    fi
}

assert_valid "$FIXTURES/valid-state.json"

for fixture in "$FIXTURES"/invalid-*.json; do
    assert_invalid "$fixture"
done

echo "Contrato de estado: testes concluidos com sucesso"
