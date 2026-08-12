#!/bin/bash

set -Eeuo pipefail
umask 077

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Execute como root: sudo bash $0 [--run-scan]" >&2
    exit 1
fi

RUN_SCAN=0
if [ "${1:-}" = "--run-scan" ]; then
    RUN_SCAN=1
elif [ "$#" -gt 0 ]; then
    echo "Uso: sudo bash $0 [--run-scan]" >&2
    exit 2
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -s | tr -cd 'A-Za-z0-9._-')"
OUT="$PWD/auditoria-nextcloud-${HOST}-${STAMP}"
CONTAINER="nextcloud-app"
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

occ() {
    docker exec -u www-data "$CONTAINER" php occ "$@"
}

cat >"$OUT/LEIA-ME.txt" <<'EOF'
Coleta somente-leitura do host Nextcloud.

REVISE antes de compartilhar:
- listas de usuários/grupos contêm usernames;
- files_external pode conter paths internos;
- findmnt mostra o path do arquivo de credenciais, mas não deve mostrar a senha;
- nenhum docker inspect de Environment foi executado;
- nenhum arquivo de credenciais ou Compose foi copiado.

O files:scan --all somente roda quando o script recebe --run-scan.
EOF

capture "01-sistema.txt" hostnamectl
capture "02-debian.txt" cat /etc/debian_version
capture_shell "03-docker-versoes.txt" \
    "docker version --format 'Server={{.Server.Version}}'; docker compose version"
capture_shell "04-containers.txt" \
    "docker ps --filter name=nextcloud-app --filter name=db --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"
capture "05-nextcloud-status.json" occ status --output=json_pretty

capture_shell "06-nextcloud-proxy-url.txt" '
for key in \
  trusted_domains \
  trusted_proxies \
  forwarded_for_headers \
  overwritehost \
  overwriteprotocol \
  overwritecondaddr \
  overwrite.cli.url
do
  echo "=== $key ==="
  docker exec -u www-data nextcloud-app php occ config:system:get "$key"
done'

capture_shell "07-occ-ajudas.txt" '
for command in \
  user:add \
  user:disable \
  user:enable \
  user:setting \
  group:add \
  group:adduser \
  group:removeuser \
  files_external:list
do
  echo "================ $command ================"
  docker exec -u www-data nextcloud-app php occ help "$command"
done'

capture "08-nextcloud-usuarios.txt" occ user:list
capture "09-nextcloud-grupos.txt" occ group:list
capture_shell "10-apps.txt" \
    "docker exec -u www-data nextcloud-app php occ app:list | sed -n '/Enabled:/,/Disabled:/p'"
capture "11-external-storage.txt" occ files_external:list

capture_shell "12-sharing-global.txt" '
for key in \
  shareapi_allow_links \
  shareapi_enforce_links_password \
  shareapi_default_expire_date \
  shareapi_enforce_expire_date \
  shareapi_expire_after_n_days
do
  echo "=== $key ==="
  docker exec -u www-data nextcloud-app php occ config:app:get core "$key"
done'

capture_shell "13-cifs-findmnt.txt" \
    "findmnt -t cifs -o TARGET,SOURCE,FSTYPE,OPTIONS | sed -E 's/((password|pass)=)[^, ]+/\\1REDACTED/Ig'"
capture_shell "14-docker-mounts.txt" \
    "docker inspect --format '{{range .Mounts}}{{println .Source \"->\" .Destination \"rw=\" .RW}}{{end}}' nextcloud-app"
capture_shell "15-permissoes-container.txt" '
docker exec -u www-data nextcloud-app sh -c '"'"'
  id
  for p in /mnt/samba/publico /mnt/samba/usuarios /mnt/samba/laudos \
           /mnt/samba/laudos-mega /mnt/samba/administrativo; do
    stat -c "%A %a %U:%G %n" "$p"
  done
'"'"''

capture_shell "16-crontab-root.txt" "crontab -l"
capture_shell "17-crontab-www-data.txt" "crontab -u www-data -l"
capture "18-systemd-timers.txt" systemctl list-timers --all --no-pager
capture "19-background-status.txt" occ background:status
capture "20-tempo.txt" timedatectl
capture_shell "21-url-publica-headers.txt" \
    "curl -sS -o /dev/null -D - https://cloud.applaupertec.com/; \
     curl -sS -o /dev/null -D - https://cloud.applaupertec.com/status.php; \
     curl -sS -o /dev/null -D - https://cloud.applaupertec.com/.well-known/caldav; \
     curl -sS -o /dev/null -D - https://cloud.applaupertec.com/.well-known/carddav"

if [ "$RUN_SCAN" -eq 1 ]; then
    capture_shell "22-files-scan-all-medicao.txt" \
        "/usr/bin/time -v docker exec -u www-data nextcloud-app php occ files:scan --all"
else
    cat >"$OUT/22-files-scan-nao-executado.txt" <<'EOF'
O scan completo não foi executado.

Para medir em uma janela aprovada, confirme antes que não existe outro scan e rode:

sudo bash coletar-nextcloud.sh --run-scan
EOF
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
