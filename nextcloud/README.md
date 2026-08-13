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

As imagens são fixadas por versão e digest. Atualizações exigem mudança
explícita no repositório, backup e validação antes de recriar os containers.

Somente na primeira instalação, use o override de bootstrap:

```bash
cd nextcloud/docker
docker compose \
  -f docker-compose.yml \
  -f docker-compose.bootstrap.yml \
  up -d
```

Depois da instalação, use apenas `docker-compose.yml`. A senha administrativa
não fica no ambiente normal do container e pode ser removida do `.env`.

O Nextcloud publica HTTP somente em `127.0.0.1:8080`. A porta não deve ser
exposta diretamente à LAN ou ao WARP.

## Disco dedicado

Instale o drop-in:

```bash
install -D -m 0644 \
  nextcloud/systemd/docker-nextcloud-storage.conf \
  /etc/systemd/system/docker.service.d/nextcloud-storage.conf

systemctl daemon-reload
```

Isso impede o Docker de iniciar antes do mount
`/srv/nextcloud-storage`. O Compose usa:

```text
/srv/nextcloud-storage/app-data -> /var/www/html/data
/srv/nextcloud-storage/shares   -> /mnt/storage/shares
```

Os shares são locais e começam vazios. O storage `Laudos-Mega` aponta para
`/mnt/storage/shares/laudos/mega`, compartilhando o mesmo subdiretório físico
visível em `Laudos`.

Enquanto o fileserver Samba estiver desligado, mantenha
`sync-nextcloud-state.timer` desabilitado e administre usuários e grupos
diretamente no Nextcloud.

Após remover os grupos legados `samba-*`, mantenha os seis External Storages
restritos ao grupo vazio `nextcloud-storage-disabled`. Substitua essa
associação pelos novos grupos de acesso antes de remover o grupo de
quarentena; um storage sem usuários ou grupos aplicáveis fica global.

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
Mantenha `/etc/cloudflared/config.yml`, o arquivo de credencial do túnel e
qualquer cópia em `/root/.cloudflared/` como `root:root`, modo `0600` ou mais
restritivo. Valide o ingress antes de reiniciar:

```bash
cloudflared --config /etc/cloudflared/config.yml tunnel ingress validate
```

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

`sync-nextcloud-state --dry-run`:

- baixa o snapshot por SFTP para staging root-only;
- valida tamanho, schema, freshness, geração e circuit breakers;
- lista usuários e grupos do OCC com limite alto e falha fechada se houver
  possível truncamento;
- lê o marker `samba_nextcloud_sync/managed_by`;
- calcula contas novas, conflitos e memberships;
- grava `last-plan.json` e, somente em execução saudável sem conflitos,
  promove `last-known-good.json`;
- nunca cria, altera, habilita, desabilita ou apaga contas.

Depois de revisar o plano, `--apply-additive` pode:

- criar grupos gerenciados ausentes;
- criar contas com senha aleatória não exibida;
- desabilitar imediatamente cada conta nova;
- gravar os markers `managed_by=samba-nextcloud-sync` e
  `onboarding_pending=1`;
- adicionar memberships ausentes.

O modo aditivo não remove memberships, não habilita contas, não processa
ausências e nunca apaga usuários ou arquivos.

## Lifecycle seguro

`--apply-lifecycle` executa convergência de memberships de contas já
gerenciadas e mantém um estado local de ausências. Uma conta somente é
desabilitada quando:

- está ausente em pelo menos 3 snapshots saudáveis consecutivos;
- passaram pelo menos 4 dias desde a primeira ausência saudável;
- possui marker `managed_by=samba-nextcloud-sync`;
- nenhum circuit breaker está ativo;
- não é uma conta protegida.

Ao atingir a carência, os cinco memberships gerenciados são removidos e a
conta é desabilitada. Nunca há `user:delete` ou purge. Se o usuário retornar,
somente uma conta com marker `disabled_by_sync=1` pode ser reabilitada
automaticamente. Contas ainda com `onboarding_pending=1` nunca são habilitadas
automaticamente.

O marker transitório `disable_pending=1` torna uma falha entre marcação e
desativação recuperável. O estado de ausências é preparado a cada snapshot
saudável, inclusive em dry-run, mas só é persistido após a execução inteira
terminar com sucesso.

Antes de habilitar esse modo em produção, faça snapshots das VMs conforme o
procedimento operacional.

Instale:

```bash
install -o root -g root -m 0755 \
  nextcloud/sync-nextcloud-state \
  /usr/local/sbin/sync-nextcloud-state

install -D -o root -g root -m 0644 \
  nextcloud/lib/build-sync-plan.jq \
  /usr/local/lib/samba-nextcloud/build-sync-plan.jq

install -D -o root -g root -m 0644 \
  nextcloud/lib/update-absence-state.jq \
  /usr/local/lib/samba-nextcloud/update-absence-state.jq

install -o root -g root -m 0640 \
  nextcloud/nextcloud-sync.conf.example \
  /etc/samba-nextcloud-sync.conf
```

Execute manualmente:

```bash
sudo sync-nextcloud-state --dry-run
```

O apply exige vinculação ao plano revisado:

```bash
sudo sync-nextcloud-state \
  --apply-additive \
  --reviewed-generation UUID_DO_DRY_RUN
```

Contas em criação passam temporariamente pelo grupo interno
`samba-nextcloud-provisioning`. Isso permite que uma execução interrompida
retome com segurança a desativação e os markers antes de adicionar os grupos
Samba. Um display name imprevisível registrado no journal prova que a conta
foi criada pelo sincronizador; o grupo sozinho nunca é usado como prova de
ownership. Um journal root-only fica em
`/var/lib/samba-nextcloud-sync/state/provisioning/` até a conclusão.

Um username que já exista no Nextcloud sem o marker do sincronizador é
tratado como conflito e nunca é adotado automaticamente.

As contas `admin` e `nextcloud_user` são protegidas. O consumidor rejeita
qualquer snapshot que contenha uma delas.

## Timers systemd

O instalador `install-systemd-schedulers` salva o estado anterior, substitui
somente as duas linhas cron legadas conhecidas e testa as unidades sem manter
agendadores duplicados. Se a migração falhar, restaura units, timers e crontab;
um job já iniciado termina antes de o cron anterior voltar:

- `nextcloud-cron.timer`: `cron.php` a cada cinco minutos;
- `nextcloud-files-scan.timer`: `files:scan --all` a cada cinco minutos após
  a execução anterior terminar, com prioridade reduzida;
- `sync-nextcloud-state.timer`: sincronização horária somente em `dry-run`.

O lifecycle destrutivo permanece manual para permitir snapshots e revisão
antes de remoções de memberships ou desativações.

```bash
sudo bash nextcloud/install-systemd-schedulers
```

## Operacao

Os procedimentos de onboarding, lifecycle, adoção, rename, purge, backup,
restore e atualização dos containers estão em
[`OPERATIONS.md`](OPERATIONS.md).
