# Auditoria runtime

Coletores somente-leitura para reunir as evidências necessárias antes da
implementação da sincronização Samba/Linux para Nextcloud.

Os scripts não alteram usuários, grupos, ACLs, Samba, Nextcloud, Cloudflare,
mounts, cron ou systemd. Cada execução cria:

- uma pasta com arquivos de evidência;
- um arquivo `SHA256SUMS`;
- um pacote `.tar.gz`.

Revise o pacote antes de transferi-lo. Não envie senhas, tokens, chaves,
cookies, credenciais CIFS, arquivos `.env`, Compose, credenciais do
`cloudflared`, dumps de banco ou conteúdo dos shares.

## Atualizar ou clonar nos servidores

Primeiro acesso:

```bash
git clone https://github.com/Racass/scripts_servidor.git
cd scripts_servidor/auditoria
```

Se o repositório já estiver clonado:

```bash
cd scripts_servidor
git pull --rebase
cd auditoria
```

## 1. Fileserver

Servidor:

- hostname: `fileserver.corp`
- IP: `10.0.77.100`

Execute:

```bash
sudo bash ./coletar-fileserver.sh
```

Resultado:

```text
auditoria-fileserver-<host>-<data>.tar.gz
```

## 2. Host Nextcloud

Servidor:

- hostname: `nextcloud.corp`
- IP: `10.0.77.101`

Coleta normal, sem executar o scan completo:

```bash
sudo bash ./coletar-nextcloud.sh
```

Para medir também `files:scan --all`, somente em janela aprovada e após
confirmar que não existe outro scan em execução:

```bash
sudo bash ./coletar-nextcloud.sh --run-scan
```

Resultado:

```text
auditoria-nextcloud-<host>-<data>.tar.gz
```

## 3. VM cloudflared

Servidor:

- hostname: `cloudflared.corp`
- IP: `10.0.77.20`

Execute:

```bash
sudo bash ./coletar-cloudflared.sh
```

Resultado:

```text
auditoria-cloudflared-<host>-<data>.tar.gz
```

## Copiar as evidências dos servidores para o computador local

Execute estes comandos no PowerShell do computador local. Substitua
`USUARIO` pelo usuário SSH usado em cada VM:

```powershell
New-Item -ItemType Directory -Force .\evidencias-auditoria

scp 'USUARIO@10.0.77.100:~/scripts_servidor/auditoria/auditoria-fileserver-*.tar.gz' .\evidencias-auditoria\
scp 'USUARIO@10.0.77.101:~/scripts_servidor/auditoria/auditoria-nextcloud-*.tar.gz' .\evidencias-auditoria\
scp 'USUARIO@10.0.77.20:~/scripts_servidor/auditoria/auditoria-cloudflared-*.tar.gz' .\evidencias-auditoria\
```

Se o clone estiver em outro diretório, ajuste o caminho remoto. O caminho
exato do `.tar.gz` também é exibido ao final de cada coletor.

## Conferir os checksums

Depois de extrair cada pacote:

```bash
cd auditoria-<tipo>-<host>-<data>
sha256sum -c SHA256SUMS
```

Os usernames e memberships são necessários para a auditoria, mas podem ser
substituídos consistentemente por `USUARIO_01`, `USUARIO_02` etc. antes de
compartilhar as evidências.
