# Exportacao Samba para Nextcloud

O exportador le os cinco grupos gerenciados sem alterar usuarios, ACLs,
shares ou a configuracao Samba. O arquivo final e publicado atomicamente para
consumo read-only pelo host Nextcloud.

Consulte [STATE-CONTRACT.md](STATE-CONTRACT.md) antes de alterar o formato.

## Dependencias

```bash
apt-get install jq
```

As ferramentas `getent`, `pdbedit`, `testparm`, `flock` e coreutils tambem
devem estar disponiveis.

## Instalacao

Antes da primeira execucao, a conta/grupo de transporte `nextcloud-sync`
precisa existir. A configuracao de SFTP e feita em uma fase separada.

O configurador `configure-nextcloud-sync-sftp` cria essa conta sem Samba,
senha, sudo ou shell e aplica:

- chroot em `/var/lib/samba-nextcloud-export`;
- `internal-sftp -R`;
- autenticacao somente por chave;
- chave limitada ao IP `10.0.77.101`;
- forwarding, TTY e ambiente desabilitados.

Use a chave publica gerada no host Nextcloud:

```bash
configure-nextcloud-sync-sftp \
  --public-key-file /root/nextcloud-sync.pub
```

```bash
install -D -o root -g root -m 0755 \
  samba/export-nextcloud-state \
  /usr/local/sbin/export-nextcloud-state

install -D -o root -g root -m 0644 \
  samba/lib/validate-nextcloud-state.jq \
  /usr/local/lib/samba-nextcloud/validate-nextcloud-state.jq

install -D -o root -g root -m 0644 \
  samba/STATE-CONTRACT.md \
  /usr/local/share/doc/samba-nextcloud/STATE-CONTRACT.md

install -D -o root -g root -m 0640 \
  samba/nextcloud-export.conf.example \
  /etc/samba-nextcloud-export.conf

install -D -o root -g root -m 0644 \
  samba/systemd/export-nextcloud-state.service \
  /etc/systemd/system/export-nextcloud-state.service

install -D -o root -g root -m 0644 \
  samba/systemd/export-nextcloud-state.timer \
  /etc/systemd/system/export-nextcloud-state.timer

systemctl daemon-reload
systemctl enable --now export-nextcloud-state.timer
```

Execute manualmente para validar antes de depender do timer:

```bash
systemctl start export-nextcloud-state.service
systemctl status export-nextcloud-state.service
journalctl -u export-nextcloud-state.service
```

O snapshot atual fica em:

```text
/var/lib/samba-nextcloud-export/state.json
```

Snapshots horarios ficam em `archive/` por sete dias e sao legiveis somente
por root.
