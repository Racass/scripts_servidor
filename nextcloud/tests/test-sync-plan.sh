#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACTUAL="$(mktemp -t samba-nextcloud-plan.XXXXXX)"

cleanup_test() {
    rm -f -- "$ACTUAL"
}
trap cleanup_test EXIT

command -v jq >/dev/null 2>&1 || {
    echo "ERRO: jq nao encontrado" >&2
    exit 11
}

jq -f "$SCRIPT_DIR/../lib/build-sync-plan.jq" \
    "$SCRIPT_DIR/fixtures/planner-input.json" >"$ACTUAL"

if ! diff -u \
    <(jq -S . "$SCRIPT_DIR/fixtures/planner-expected.json") \
    <(jq -S . "$ACTUAL")
then
    echo "ERRO: plano calculado diverge do esperado" >&2
    exit 1
fi

echo "Plano de sincronizacao: testes concluidos com sucesso"
