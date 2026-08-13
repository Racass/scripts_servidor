# Runbook de reconstrução: Samba + Nextcloud

Este documento descreve como reconstruir a integração implementada neste
repositório. Samba/Linux continua sendo a fonte de verdade de usuários,
grupos, memberships, ACLs e acesso aos shares. O Nextcloud mantém apenas uma
réplica de identidade e autorização para acesso web.

Para a operação diária de usuários, consulte
[`novo-usuario-onboarding.html`](novo-usuario-onboarding.html).

## 1. Arquitetura alvo

| Componente | Nome | Endereço | Responsabilidade |
|---|---|---:|---|
| Proxmox | `proxmox.corp` | `10.0.77.1` | Hypervisor e snapshots |
| AdGuard Home | `dns.corp` | `10.0.77.2` | DNS privado |
| Cloudflared privado | `cloudflared.corp` | `10.0.77.20` | WARP/Zero Trust e rede privada |
| Fileserver | `fileserver.corp` | `10.0.77.100` | Samba standalone e fonte de verdade |
| Nextcloud | `nextcloud.corp` | `10.0.77.101` | Interface web e réplica de autorização |
| Hostname público | `cloud.applaupertec.com` | Cloudflare | Acesso público pelo Tunnel |

Existem dois processos cloudflared independentes:

1. o CT `cloudflared` mantém a conectividade privada/WARP;
2. a VM Nextcloud mantém o túnel público `nextcloud-tunnel`.

Não migre nem misture as configurações desses conectores.

## 2. Invariantes de segurança

- Não sincronizar senhas Samba com o Nextcloud.
- `samba-admin` não concede administração da aplicação Nextcloud.
- Proteger sempre os usernames `admin` e `nextcloud_user`.
- Nunca executar `user:delete` automaticamente.
- O timer de sync executa somente `--dry-run`.
- Lifecycle, adoção, rename, purge, restore e recriação de containers exigem
  snapshots prévios da VM fileserver, VM Nextcloud e CT cloudflared.
- Não alterar `/etc/samba/fileserver.conf` como parte desta integração.
- Não usar tags Docker móveis.
- Não aceitar host key SSH obtida pelo mesmo canal que está sendo validado.

## 3. Pré-requisitos

Em ambos os servidores:

```bash
apt-get update
apt-get install -y git jq
git clone https://github.com/Racass/scripts_servidor.git \
  /home/rafael/git/scripts_servidor
```

No fileserver:

```bash
apt-get install -y samba acl openssh-server
```

No Nextcloud:

```bash
apt-get install -y \
  cifs-utils curl nginx certbot openssh-client openssl \
  python3-certbot-dns-cloudflare
```

Instale Docker Engine e o plugin Docker Compose pelo repositório oficial para
Debian. Confirme `docker version` e `docker compose version`; não use o pacote
legado `docker-compose`.

Antes de prosseguir, confirme relógio/NTP, DNS e conectividade entre
`10.0.77.100` e `10.0.77.101`.

## 4. DNS, WARP e resolução

No AdGuard Home, mantenha:

```text
dns.corp          -> 10.0.77.2
fileserver.corp   -> 10.0.77.100
cloudflared.corp  -> 10.0.77.20
nextcloud.corp    -> 10.0.77.101
proxmox.corp      -> 10.0.77.1
```

Para acesso privado ao mesmo hostname canônico, o AdGuard pode sobrescrever:

```text
cloud.applaupertec.com -> 10.0.77.101
```

No Cloudflare Zero Trust, configure Local Domain Fallback para `corp` e para
`cloud.applaupertec.com`, apontando ao DNS privado `10.0.77.2`.

Critério de sucesso:

- com WARP, `cloud.applaupertec.com` resolve para `10.0.77.101`;
- sem WARP, resolve para os endereços públicos da Cloudflare;
- nomes `.corp` resolvem apenas pelo DNS privado.

## 5. Fileserver Samba

O Samba deve permanecer:

```text
server role = standalone server
passdb backend = tdbsam
```

Grupos gerenciados:

```text
samba-users
samba-admin
samba-laudos
samba-laudos-mega
samba-administrativo
```

Shares e paths:

| Share | Path |
|---|---|
| `Publico` | `/srv/files/publico` |
| `Usuarios` | `/srv/files/usuarios` |
| `Laudos` | `/srv/files/laudos` |
| `Laudos-Mega` | `/srv/files/laudos/mega` |
| `Administrativo` | `/srv/files/administrativo` |

Valide, sem reescrever a configuração:

```bash
testparm -s /etc/samba/fileserver.conf
pdbedit -L
getent group samba-users samba-admin samba-laudos \
  samba-laudos-mega samba-administrativo
```

## 6. Exportador Samba

No fileserver:

```bash
REPO=/home/rafael/git/scripts_servidor

install -D -o root -g root -m 0755 \
  "$REPO/samba/export-nextcloud-state" \
  /usr/local/sbin/export-nextcloud-state

install -D -o root -g root -m 0644 \
  "$REPO/samba/lib/validate-nextcloud-state.jq" \
  /usr/local/lib/samba-nextcloud/validate-nextcloud-state.jq

install -D -o root -g root -m 0644 \
  "$REPO/samba/STATE-CONTRACT.md" \
  /usr/local/share/doc/samba-nextcloud/STATE-CONTRACT.md

install -D -o root -g root -m 0640 \
  "$REPO/samba/nextcloud-export.conf.example" \
  /etc/samba-nextcloud-export.conf

install -D -o root -g root -m 0644 \
  "$REPO/samba/systemd/export-nextcloud-state.service" \
  /etc/systemd/system/export-nextcloud-state.service

install -D -o root -g root -m 0644 \
  "$REPO/samba/systemd/export-nextcloud-state.timer" \
  /etc/systemd/system/export-nextcloud-state.timer

systemctl daemon-reload
```

Não habilite o timer antes de configurar o transporte SFTP.

## 7. Transporte SFTP read-only

### 7.1 Gerar a chave no Nextcloud

```bash
cd /home/rafael/git/scripts_servidor
bash nextcloud/configure-samba-state-client
```

Copie somente:

```text
/etc/samba-nextcloud-sync/id_ed25519.pub
```

para um arquivo temporário root-only no fileserver.
O diretório de origem é `0700`; faça essa cópia como root.

### 7.2 Configurar o fileserver

```bash
cd /home/rafael/git/scripts_servidor
bash samba/configure-nextcloud-sync-sftp \
  --public-key-file /root/nextcloud-sync.pub
```

O script cria `nextcloud-sync` sem Samba, senha, sudo ou shell e restringe a
chave ao IP `10.0.77.101`.

Obtenha a host key Ed25519 do fileserver por canal administrativo confiável:

```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
```

### 7.3 Pinar a host key no Nextcloud

Salve a chave recebida em `/root/fileserver-ed25519.pub`:

```bash
cd /home/rafael/git/scripts_servidor
bash nextcloud/configure-samba-state-client \
  --host-key-file /root/fileserver-ed25519.pub
```

### 7.4 Publicar e testar

No fileserver:

```bash
systemctl enable --now export-nextcloud-state.timer
systemctl start export-nextcloud-state.service
jq . /var/lib/samba-nextcloud-export/state.json
```

No Nextcloud:

```bash
sftp -F /etc/samba-nextcloud-sync/ssh_config samba-state-source
```

O download deve funcionar. Upload e execução SSH devem ser negados.

## 8. CIFS no host Nextcloud

Defina a senha técnica somente no ambiente do shell:

```bash
export NEXTCLOUD_SMB_PASSWORD='SENHA_TEMPORARIA'
cd /home/rafael/git/scripts_servidor
bash nextcloud/docker/prepara_docker
unset NEXTCLOUD_SMB_PASSWORD
```

O arquivo `/etc/samba/creds/nextcloud` deve ser `root:root 0600`.

Valide:

```bash
findmnt /mnt/nextcloud-data/publico
findmnt /mnt/nextcloud-data/usuarios
findmnt /mnt/nextcloud-data/laudos
findmnt /mnt/nextcloud-data/laudos-mega
findmnt /mnt/nextcloud-data/administrativo
```

Instale o drop-in que impede o Docker de iniciar sem os mounts:

```bash
install -D -o root -g root -m 0644 \
  /home/rafael/git/scripts_servidor/nextcloud/systemd/docker-nextcloud-cifs.conf \
  /etc/systemd/system/docker.service.d/nextcloud-cifs.conf
systemctl daemon-reload
```

## 9. Nextcloud e MariaDB em Docker

```bash
cd /home/rafael/git/scripts_servidor/nextcloud/docker
cp .env.example .env
chmod 0600 .env
```

Preencha senhas fortes e exclusivas. Na primeira instalação:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.bootstrap.yml \
  up -d
```

Depois da instalação:

1. use apenas `docker-compose.yml`;
2. remova `NEXTCLOUD_ADMIN_PASSWORD` do `.env`;
3. não use novamente o override de bootstrap.

Valide:

```bash
docker compose -f docker-compose.yml config --quiet
docker exec -u www-data nextcloud-app php occ status --output=json
```

## 10. HTTPS privado e túnel público

Use token Cloudflare limitado a `Zone/DNS/Edit` e `Zone/Zone/Read`, armazenado
fora do Git com modo `0600`.

Instale a configuração Nginx:

```bash
install -o root -g root -m 0644 \
  /home/rafael/git/scripts_servidor/nextcloud/nginx/cloud.applaupertec.com.conf \
  /etc/nginx/sites-available/cloud.applaupertec.com
ln -s /etc/nginx/sites-available/cloud.applaupertec.com \
  /etc/nginx/sites-enabled/cloud.applaupertec.com
nginx -t
systemctl reload nginx
```

Crie `/root/cloudflare-dns.ini` com:

```ini
dns_cloudflare_api_token = TOKEN_DNS
```

Proteja o arquivo, emita o certificado por DNS-01 e teste a renovação:

```bash
chown root:root /root/cloudflare-dns.ini
chmod 0600 /root/cloudflare-dns.ini

certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/cloudflare-dns.ini \
  -d cloud.applaupertec.com

certbot renew --dry-run
```

O arquivo deve conter somente o token DNS no formato exigido pelo plugin.
Não o grave no repositório.

O túnel público da VM Nextcloud deve encaminhar para:

```yaml
service: https://localhost:443
originRequest:
  originServerName: cloud.applaupertec.com
```

Use `nextcloud/cloudflared/config.yml.example` como referência. Mantenha
configuração e credenciais como `root:root 0600`.

```bash
cloudflared --config /etc/cloudflared/config.yml tunnel ingress validate
systemctl enable --now cloudflared
```

Não migre o túnel local para gerenciamento pelo dashboard.

## 11. Configuração do Nextcloud

Descubra primeiro o gateway real da rede Docker:

```bash
DOCKER_GATEWAY="$(
  docker inspect nextcloud-app \
    --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'
)"
test -n "$DOCKER_GATEWAY"
printf '%s\n' "$DOCKER_GATEWAY"
```

Use esse valor, sem presumir `172.18.0.1`:

```bash
occ() {
  docker exec -u www-data nextcloud-app php occ "$@"
}

occ config:system:set trusted_domains 0 --value=localhost
occ config:system:set trusted_domains 1 --value=10.0.77.101
occ config:system:set trusted_domains 2 \
  --value=cloud.applaupertec.com
occ config:system:set trusted_proxies 0 --value="$DOCKER_GATEWAY"
occ config:system:set overwritehost --value=cloud.applaupertec.com
occ config:system:set overwriteprotocol --value=https
occ config:system:set overwrite.cli.url \
  --value=https://cloud.applaupertec.com
occ background:cron
```

Repita essa descoberta se a rede Docker for recriada. Não confie em ranges
amplos sem necessidade.

## 12. External Storages

Habilite o app External storage support e crie storages do tipo **Local**:

| Nome | Path no container | Grupos |
|---|---|---|
| `Publico` | `/mnt/samba/publico` | `samba-users`, `samba-admin` |
| `Laudos` | `/mnt/samba/laudos` | `samba-laudos`, `samba-admin` |
| `Laudos-Mega` | `/mnt/samba/laudos-mega` | `samba-laudos-mega`, `samba-admin` |
| `Administrativo` | `/mnt/samba/administrativo` | `samba-administrativo`, `samba-admin` |
| `Minha pasta` | `/mnt/samba/usuarios/$user` | `samba-users`, `samba-admin` |
| `Usuarios - Administração` | `/mnt/samba/usuarios` | `samba-admin` |

Não configure o grupo administrativo interno `admin`.

## 13. Sincronizador no Nextcloud

```bash
REPO=/home/rafael/git/scripts_servidor

install -o root -g root -m 0755 \
  "$REPO/nextcloud/sync-nextcloud-state" \
  /usr/local/sbin/sync-nextcloud-state

install -D -o root -g root -m 0644 \
  "$REPO/samba/lib/validate-nextcloud-state.jq" \
  /usr/local/lib/samba-nextcloud/validate-nextcloud-state.jq

install -D -o root -g root -m 0644 \
  "$REPO/nextcloud/lib/build-sync-plan.jq" \
  /usr/local/lib/samba-nextcloud/build-sync-plan.jq

install -D -o root -g root -m 0644 \
  "$REPO/nextcloud/lib/update-absence-state.jq" \
  /usr/local/lib/samba-nextcloud/update-absence-state.jq

install -D -o root -g root -m 0644 \
  "$REPO/samba/STATE-CONTRACT.md" \
  /usr/local/share/doc/samba-nextcloud/STATE-CONTRACT.md

install -o root -g root -m 0640 \
  "$REPO/nextcloud/nextcloud-sync.conf.example" \
  /etc/samba-nextcloud-sync.conf
```

Execute:

```bash
sync-nextcloud-state --dry-run
```

Revise:

```bash
jq . /var/lib/samba-nextcloud-sync/state/last-plan.json
```

Para criação aditiva:

```bash
GENERATION="$(
  jq -r '.generation_id' \
    /var/lib/samba-nextcloud-sync/state/last-plan.json
)"
sync-nextcloud-state \
  --apply-additive \
  --reviewed-generation "$GENERATION"
```

Não execute apply se houver conflitos, remoções inesperadas ou mudança de
geração.

## 14. Agendadores

```bash
cd /home/rafael/git/scripts_servidor
bash nextcloud/install-systemd-schedulers
```

Valide:

```bash
systemctl list-timers --all \
  nextcloud-cron.timer \
  nextcloud-files-scan.timer \
  sync-nextcloud-state.timer

systemctl show \
  nextcloud-cron.service \
  nextcloud-files-scan.service \
  sync-nextcloud-state.service \
  -p Result -p ExecMainStatus
```

As duas linhas cron legadas não podem permanecer ativas.

## 15. Validação final

```bash
curl --fail --head \
  --resolve cloud.applaupertec.com:443:127.0.0.1 \
  https://cloud.applaupertec.com/status.php

docker exec -u www-data nextcloud-app php occ status --output=json
sync-nextcloud-state --dry-run
```

Confirme também:

- acesso público sem WARP;
- acesso ao IP privado pelo hostname canônico com WARP;
- certificado válido;
- seis External Storages verdes;
- download SFTP permitido e upload negado;
- timers ativos;
- zero conflitos no plano;
- contas novas desabilitadas até onboarding.

## 16. Operação e recuperação

- Onboarding, adoção, lifecycle, rename, purge e restore:
  `nextcloud/OPERATIONS.md`.
- Contrato do estado: `samba/STATE-CONTRACT.md`.
- Guia humano de criação:
  `novo-usuario-onboarding.html`.
- Evidências devem registrar data, operador, geração, hash e resultado.

Se uma etapa falhar, pare. Não apague conta, pasta, journal ou estado local
para “tentar de novo”. Preserve logs e corrija a causa ou restaure snapshots.
