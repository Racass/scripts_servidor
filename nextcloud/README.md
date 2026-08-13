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
