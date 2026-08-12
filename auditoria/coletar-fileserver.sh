#!/bin/bash

set -Eeuo pipefail
umask 077

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Execute como root: sudo bash $0" >&2
    exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -s | tr -cd 'A-Za-z0-9._-')"
OUT="$PWD/auditoria-fileserver-${HOST}-${STAMP}"
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
Coleta somente-leitura do fileserver.

REVISE antes de compartilhar:
- grupos e pdbedit contêm usernames;
- ACLs contêm usernames e paths;
- não inclua arquivos de credenciais, chaves ou senhas.
EOF

capture "01-sistema.txt" hostnamectl
capture "02-debian.txt" cat /etc/debian_version
capture "03-kernel.txt" uname -a
capture_shell "04-samba-versao.txt" "smbd --version; testparm --version"
capture "05-smbd-estado.txt" systemctl show smbd \
    -p ActiveState -p SubState -p UnitFileState -p MainPID -p ExecMainStatus
capture "06-testparm.txt" testparm -s
capture_shell "07-samba-role-backend.txt" \
    "testparm -s --parameter-name='server role'; testparm -s --parameter-name='passdb backend'"

capture_shell "08-grupos-gerenciados.txt" '
for group in \
  samba-users \
  samba-admin \
  samba-laudos \
  samba-laudos-mega \
  samba-administrativo
do
  echo "=== $group ==="
  getent group "$group"
done'

capture "09-tdbsam-usuarios.txt" pdbedit -L

capture_shell "10-diretorios-stat.txt" \
    "stat -c '%A %a %U:%G %n' \
      /srv/files \
      /srv/files/publico \
      /srv/files/usuarios \
      /srv/files/laudos \
      /srv/files/laudos/mega \
      /srv/files/administrativo"

capture "11-acls-raizes.txt" getfacl -p \
    /srv/files/publico \
    /srv/files/usuarios \
    /srv/files/laudos \
    /srv/files/laudos/mega \
    /srv/files/administrativo

capture_shell "12-acls-usuarios-amostra.txt" '
find /srv/files/usuarios -mindepth 1 -maxdepth 1 -type d -printf "%f\n" |
  sort |
  head -n 2 |
  while IFS= read -r username; do
    echo "=== /srv/files/usuarios/$username ==="
    getfacl -p "/srv/files/usuarios/$username"
  done'

capture "13-nextcloud-user-id.txt" id nextcloud_user
capture_shell "14-nextcloud-user-samba.txt" \
    "pdbedit -Lv nextcloud_user | sed -n '/^Unix username:/p;/^Account Flags:/p'"
capture_shell "15-openssh-versao.txt" "ssh -V"
capture_shell "16-sshd-efetivo.txt" \
    "sshd -T | grep -E '^(subsystem|passwordauthentication|pubkeyauthentication|permitrootlogin) '"
capture "17-tempo.txt" timedatectl
capture_shell "18-espaco-filesystem.txt" \
    "df -hT /srv/files; df -i /srv/files"

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
echo "Coleta concluida:"
echo "  Pasta:   $OUT"
echo "  Arquivo: $ARCHIVE"
echo
echo "Revise o conteudo antes de transferir."
