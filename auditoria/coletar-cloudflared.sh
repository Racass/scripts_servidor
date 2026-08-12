#!/bin/bash

set -Eeuo pipefail
umask 077

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Execute como root: sudo bash $0" >&2
    exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -s | tr -cd 'A-Za-z0-9._-')"
OUT="$PWD/auditoria-cloudflared-${HOST}-${STAMP}"
mkdir -p "$OUT"

capture() {
    local file="$1"
    shift
    {
        printf 'Comando:'
        printf ' %q' "$@"
        printf '\n\n'
        "$@"
    } >"$OUT/$file" 2>&1 || {
        local rc=$?
        printf '\n[WARN] exit code: %s\n' "$rc" >>"$OUT/$file"
        return 0
    }
}

capture_shell() {
    local file="$1"
    local command="$2"
    {
        printf 'Comando: %s\n\n' "$command"
        bash -o pipefail -c "$command"
    } >"$OUT/$file" 2>&1 || {
        local rc=$?
        printf '\n[WARN] exit code: %s\n' "$rc" >>"$OUT/$file"
        return 0
    }
}

cat >"$OUT/LEIA-ME.txt" <<'EOF'
Coleta somente-leitura da VM cloudflared.

REVISE antes de compartilhar:
- o config sanitizado remove token, tunnel e credentials-file;
- não inclua JSON de credenciais, certificados ou tokens;
- IPs públicos de clientes devem ser removidos de qualquer evidência manual.
EOF

capture "01-sistema.txt" hostnamectl
capture "02-debian.txt" cat /etc/debian_version
capture_shell "03-cloudflared-versao.txt" "cloudflared --version"
capture "04-cloudflared-estado.txt" systemctl show cloudflared \
    -p ActiveState -p SubState -p UnitFileState -p MainPID -p ExecMainStatus
capture_shell "05-rotas.txt" \
    "ip -brief address; ip route; ip route get 10.0.77.101; ip route get 10.0.77.2"
capture_shell "06-resolver.txt" \
    "resolvectl status 2>/dev/null || cat /etc/resolv.conf"

capture_shell "07-dns-interno.txt" '
for host in \
  dns.corp \
  fileserver.corp \
  cloudflared.corp \
  nextcloud.corp \
  proxmox.corp \
  cloud.applaupertec.com
do
  echo "=== $host ==="
  getent hosts "$host"
done'

capture_shell "08-nextcloud-conectividade.txt" \
    "curl -sS -o /dev/null -D - --connect-timeout 10 http://10.0.77.101:8080/ || true"
capture_shell "09-url-publica-headers.txt" \
    "curl -sS -o /dev/null -D - https://cloud.applaupertec.com/; \
     curl -sS -o /dev/null -D - https://cloud.applaupertec.com/status.php"
capture "10-tempo.txt" timedatectl

CONFIG=""
for candidate in \
    /etc/cloudflared/config.yml \
    /etc/cloudflared/config.yaml \
    /root/.cloudflared/config.yml \
    /root/.cloudflared/config.yaml
do
    if [ -f "$candidate" ]; then
        CONFIG="$candidate"
        break
    fi
done

if [ -n "$CONFIG" ]; then
    {
        echo "Origem: $CONFIG"
        echo
        sed -E \
            -e 's/^([[:space:]]*(token|tunnel|credentials-file)[[:space:]]*:).*/\1 REDACTED/I' \
            -e 's/(eyJ[A-Za-z0-9._-]{20,})/REDACTED_TOKEN/g' \
            "$CONFIG"
    } >"$OUT/11-cloudflared-config-SANITIZADO.txt"
else
    echo "Nenhum config.yml/config.yaml encontrado nos paths padrão." \
        >"$OUT/11-cloudflared-config-SANITIZADO.txt"
fi

(
    cd "$OUT"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 |
        sort -z |
        xargs -0 sha256sum >SHA256SUMS
)

ARCHIVE="${OUT}.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$OUT")" "$(basename "$OUT")"

if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    OWNER_GROUP="$(id -gn "$SUDO_USER")"
    chown -R "$SUDO_USER:$OWNER_GROUP" "$OUT" "$ARCHIVE"
fi

echo
echo "Coleta concluída:"
echo "  Pasta:   $OUT"
echo "  Arquivo: $ARCHIVE"
echo
echo "Revise o conteúdo antes de transferir."
