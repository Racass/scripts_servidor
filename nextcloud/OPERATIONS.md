# Operação do Nextcloud

Este runbook preserva Samba/Linux como fonte de verdade. Os comandos OCC
devem ser executados como `www-data` no container `nextcloud-app`.

## Regra de snapshot

Antes de qualquer ação destrutiva ou que possa recriar containers, interrompa
o procedimento e faça snapshots no Proxmox da VM fileserver, da VM Nextcloud
e do CT cloudflared. Isso inclui:

- `sync-nextcloud-state --apply-lifecycle`;
- adoção, rename, transferência de ownership ou purge;
- restore;
- `docker compose up`, `pull` ou alteração de imagem que possa recriar
  containers.

Confirme que os snapshots terminaram antes de continuar. Para uma janela
consistente de manutenção, ative maintenance mode no Nextcloud, pare o
Compose, faça os snapshots, inicie o Compose e desative maintenance mode. Os
dados dos External Storages pertencem ao fileserver e não estão nos volumes
Docker do Nextcloud.

## Onboarding

Uma conta nova chega desabilitada, com
`managed_by=samba-nextcloud-sync` e `onboarding_pending=1`.

1. Confirme o estado:

   ```bash
   docker exec -u www-data nextcloud-app php occ user:info USUARIO
   docker exec -u www-data nextcloud-app php occ user:setting \
     USUARIO samba_nextcloud_sync managed_by --default-value=''
   docker exec -u www-data nextcloud-app php occ user:setting \
     USUARIO samba_nextcloud_sync onboarding_pending --default-value=''
   ```

2. Defina a senha interativamente, sem colocá-la na linha de comando:

   ```bash
   docker exec -it -u www-data nextcloud-app \
     php occ user:resetpassword USUARIO
   ```

3. Remova o marker de onboarding e habilite a conta:

   ```bash
   docker exec -u www-data nextcloud-app php occ user:setting \
     --delete USUARIO samba_nextcloud_sync onboarding_pending
   docker exec -u www-data nextcloud-app php occ user:enable USUARIO
   ```

4. Confirme login, grupos e External Storages com o próprio usuário.

Não remova `managed_by`. Não copie a senha Samba e não habilite a conta antes
de definir uma senha Nextcloud independente.

## Dry-run e lifecycle

O timer executa somente:

```bash
sync-nextcloud-state --dry-run
```

Para aplicar lifecycle:

1. Revise `/var/lib/samba-nextcloud-sync/state/last-plan.json`.
2. Confirme que o snapshot de origem é saudável e recente.
3. Faça os snapshots obrigatórios.
4. Execute:

   ```bash
   sync-nextcloud-state --apply-lifecycle
   ```

5. Revise o exit code, o journal e um novo dry-run.

Nunca automatize o lifecycle no timer. Ele pode remover memberships
gerenciadas e desabilitar contas elegíveis.

## Adoção manual

Uma conta Nextcloud preexistente com o mesmo username Samba gera conflito.
Adote-a somente após confirmar identidade, ownership dos dados e memberships.

Depois dos snapshots obrigatórios:

```bash
docker exec -u www-data nextcloud-app php occ user:setting \
  USUARIO samba_nextcloud_sync managed_by samba-nextcloud-sync
sync-nextcloud-state --dry-run
sync-nextcloud-state --apply-lifecycle
```

Não adote `admin`, `nextcloud_user` ou uma conta cujo dono seja incerto. A
partir da adoção, o lifecycle poderá remover os cinco memberships gerenciados
e desabilitar a conta após a carência de ausência.

## Rename

Não renomeie o UID de uma conta Nextcloud. Trate mudança de username como
migração:

1. crie o novo usuário no Samba;
2. execute dry-run e apply aditivo;
3. conclua o onboarding da conta nova;
4. transfira ownership de dados internos e compartilhamentos conforme a
   documentação da versão instalada;
5. valide External Storages e acessos;
6. remova o usuário antigo do Samba e deixe o lifecycle apenas desabilitá-lo.

Não use rename direto no banco e não presuma que External Storages são
transferidos com os dados internos.

## Purge manual

O sincronizador nunca executa `user:delete`. Purge exige ticket, snapshots,
backup validado, definição do destinatário dos dados e aprovação explícita.

Depois da transferência e validação:

```bash
docker exec -u www-data nextcloud-app php occ user:delete USUARIO
```

Esse comando é irreversível sem restore. Nunca inclua purge em timer, cron ou
no fluxo normal de lifecycle.

## Backup do estado do sincronizador

O estado não substitui backup do banco ou dos arquivos, mas é necessário para
auditoria e recuperação segura:

```bash
install -d -o root -g root -m 0700 /root/backup-samba-nextcloud
tar --acls --xattrs --numeric-owner -C / -czf \
  "/root/backup-samba-nextcloud/state-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" \
  etc/samba-nextcloud-sync \
  etc/samba-nextcloud-sync.conf \
  var/lib/samba-nextcloud-sync
chmod 0600 /root/backup-samba-nextcloud/state-*.tar.gz
```

O archive contém chave SSH privada e deve permanecer root-only, criptografado
quando sair do host.

## Restore do estado

Depois dos snapshots obrigatórios:

```bash
systemctl disable --now sync-nextcloud-state.timer
systemctl is-active --quiet sync-nextcloud-state.service && exit 1
tar --acls --xattrs --numeric-owner -C / -xzf ARQUIVO.tar.gz
sync-nextcloud-state --dry-run
systemctl enable --now sync-nextcloud-state.timer
```

Se o dry-run falhar, não habilite o timer. Corrija ownership, permissões,
host key ou geração antes de continuar.

## Atualização dos containers

As imagens ficam fixadas por versão e digest em `docker-compose.yml`.

1. Leia as notas de release e compatibilidade do Nextcloud e MariaDB.
2. Em instalação existente, confirme que a versão fixada é igual ou superior
   à versão retornada por `occ status`; downgrade não é suportado.
3. Atualize versão e digest no repositório.
4. Valide `docker compose config`.
5. Faça backup e os snapshots obrigatórios.
6. Entre em maintenance mode.
7. Faça pull e recrie de forma controlada.
8. Execute upgrades OCC exigidos pela versão.
9. Valide status, timers, HTTPS, WARP, External Storages e sync dry-run.
10. Saia de maintenance mode somente após todas as validações.

Não use tags móveis como `nextcloud:apache` ou apenas `mariadb:10.11`.
