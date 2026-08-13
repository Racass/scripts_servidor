#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXPORTER="$SCRIPT_DIR/../export-nextcloud-state"
TEST_DIR="$(mktemp -d -t test-export-groups.XXXXXX)"
MOCK_BIN="$TEST_DIR/bin"

cleanup_test() {
    rm -rf -- "$TEST_DIR"
}
trap cleanup_test EXIT

mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/getent" <<'EOF'
#!/bin/bash
case "$1:$2" in
    group:samba-users)
        echo 'samba-users:x:1001:ana,nextcloud_user'
        ;;
    group:samba-admin)
        echo 'samba-admin:x:1002:admin'
        ;;
    group:samba-laudos)
        echo 'samba-laudos:x:1003:ana'
        ;;
    group:samba-laudos-mega)
        echo 'samba-laudos-mega:x:1004:'
        ;;
    group:samba-administrativo)
        echo 'samba-administrativo:x:1005:'
        ;;
    passwd:ana)
        echo 'ana:x:2001:2001::/home/ana:/bin/bash'
        ;;
    passwd:joao)
        echo 'joao:x:2002:1002::/home/joao:/bin/bash'
        ;;
    passwd:nextcloud_user)
        echo 'nextcloud_user:x:2003:1001::/nonexistent:/usr/sbin/nologin'
        ;;
    *)
        exit 2
        ;;
esac
EOF

cat >"$MOCK_BIN/pdbedit" <<'EOF'
#!/bin/bash
cat <<'OUT'
ana:2001:
joao:2002:
nextcloud_user:2003:
admin:2004:
OUT
EOF

chmod 0700 "$MOCK_BIN/getent" "$MOCK_BIN/pdbedit"
PATH="$MOCK_BIN:/usr/bin:/bin:$PATH"

# shellcheck source=../export-nextcloud-state
source "$EXPORTER"

capture_group_state "$TEST_DIR/result"

grep -Fxq 'ana' "$TEST_DIR/result/groups/samba-users"
grep -Fxq 'ana' "$TEST_DIR/result/groups/samba-laudos"
grep -Fxq 'joao' "$TEST_DIR/result/groups/samba-admin"
grep -Fxq 'nextcloud_user' "$TEST_DIR/result/excluded-users"
grep -Fxq 'admin' "$TEST_DIR/result/excluded-users"

if grep -R -E -x -q 'nextcloud_user|admin' "$TEST_DIR/result/groups"; then
    echo "ERRO: conta protegida apareceu nos grupos exportados" >&2
    exit 1
fi

echo "Leitura de grupos: testes concluidos com sucesso"
