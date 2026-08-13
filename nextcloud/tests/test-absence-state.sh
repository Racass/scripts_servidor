#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACTUAL="$(mktemp -t samba-nextcloud-absence.XXXXXX)"

cleanup_test() {
    rm -f -- "$ACTUAL"
}
trap cleanup_test EXIT

command -v jq >/dev/null 2>&1 || {
    echo "ERRO: jq nao encontrado" >&2
    exit 11
}

jq -f "$SCRIPT_DIR/../lib/update-absence-state.jq" \
    "$SCRIPT_DIR/fixtures/absence-input.json" >"$ACTUAL"

diff -u \
    <(jq -S . "$SCRIPT_DIR/fixtures/absence-expected.json") \
    <(jq -S . "$ACTUAL")

echo "Estado de ausencias: testes concluidos com sucesso"
