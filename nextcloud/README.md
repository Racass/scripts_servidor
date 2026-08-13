# Nextcloud

Arquitetura:

```text
Internet -> Cloudflare -> nextcloud-tunnel -> HTTPS localhost:443
WARP/LAN -> AdGuard -> 10.0.77.101:443
Nginx -> 127.0.0.1:8080 -> nextcloud-app
```

O LXC `cloudflared` executa o túnel privado `laupertec-home`. O
`nextcloud-tunnel` público é executado pelo `cloudflared` instalado no host
Nextcloud. Não misture as configurações dos dois conectores.

## Docker

Crie `nextcloud/docker/.env` a partir de `.env.example`, com permissão `0600`.
O Compose recusa iniciar se as variáveis obrigatórias não estiverem definidas.

O Nextcloud publica HTTP somente em `127.0.0.1:8080`. A porta não deve ser
exposta diretamente à LAN ou ao WARP.

## CIFS

Instale o drop-in:

```bash
install -D -m 0644 \
  nextcloud/systemd/docker-nextcloud-cifs.conf \
  /etc/systemd/system/docker.service.d/nextcloud-cifs.conf

systemctl daemon-reload
```

Isso impede o Docker de iniciar antes dos cinco mounts CIFS.

## HTTPS privado

O certificado público é emitido por Let's Encrypt com DNS-01 e token
Cloudflare limitado a:

```text
Zone / DNS / Edit
Zone / Zone / Read
```

O token deve ficar fora do Git em um arquivo `0600`.

Instale:

```bash
apt-get install nginx certbot python3-certbot-dns-cloudflare
```

Copie `nextcloud/nginx/cloud.applaupertec.com.conf` para a configuração do
Nginx. Os certificados ficam em:

```text
/etc/letsencrypt/live/cloud.applaupertec.com/
```

## Tunnel público

O arquivo local do `nextcloud-tunnel` deve usar:

```yaml
service: https://localhost:443
originRequest:
  originServerName: cloud.applaupertec.com
```

Não é necessário migrar esse túnel para gerenciamento pelo dashboard.

## Transporte do estado Samba

O script `configure-samba-state-client` prepara:

- chave Ed25519 dedicada, root-only;
- `known_hosts` dedicado e pinado;
- cliente SSH sem senha e com `StrictHostKeyChecking=yes`;
- diretórios de staging e estado fora do container.

Primeiro gere a chave:

```bash
sudo bash nextcloud/configure-samba-state-client
```

Copie somente o arquivo público
`/etc/samba-nextcloud-sync/id_ed25519.pub` para o fileserver. Depois obtenha
`/etc/ssh/ssh_host_ed25519_key.pub` do fileserver por um canal administrativo
confiável e conclua:

```bash
sudo bash nextcloud/configure-samba-state-client \
  --host-key-file /root/fileserver-ed25519.pub
```

O consumidor deve usar:

```bash
sftp -F /etc/samba-nextcloud-sync/ssh_config samba-state-source
```

## Sincronizacao em dry-run

`sync-nextcloud-state` inicialmente aceita somente `--dry-run`. Ele:

- baixa o snapshot por SFTP para staging root-only;
- valida tamanho, schema, freshness, geração e circuit breakers;
- lista usuários e grupos do OCC com limite alto e falha fechada se houver
  possível truncamento;
- lê o marker `samba_nextcloud_sync/managed_by`;
- calcula contas novas, conflitos e memberships;
- grava `last-plan.json` e, somente em execução saudável sem conflitos,
  promove `last-known-good.json`;
- nunca cria, altera, habilita, desabilita ou apaga contas.

Instale:

```bash
install -o root -g root -m 0755 \
  nextcloud/sync-nextcloud-state \
  /usr/local/sbin/sync-nextcloud-state

install -D -o root -g root -m 0644 \
  nextcloud/lib/build-sync-plan.jq \
  /usr/local/lib/samba-nextcloud/build-sync-plan.jq

install -o root -g root -m 0640 \
  nextcloud/nextcloud-sync.conf.example \
  /etc/samba-nextcloud-sync.conf
```

Execute manualmente:

```bash
sudo sync-nextcloud-state --dry-run
```

Um username que já exista no Nextcloud sem o marker do sincronizador é
tratado como conflito e nunca é adotado automaticamente.

As contas `admin` e `nextcloud_user` são protegidas. O consumidor rejeita
qualquer snapshot que contenha uma delas.
