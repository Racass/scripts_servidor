# Contrato de estado Samba -> Nextcloud

Este documento define o snapshot produzido pelo fileserver e consumido pelo
host Nextcloud. O JSON é um input não confiável: os dois lados devem validar
schema e invariantes antes de publicar ou aceitar o arquivo.

## Formato

- encoding: UTF-8;
- JSON sem comentários;
- tamanho máximo aceito pelo consumidor: 1 MiB;
- `schema_version`: `1`;
- timestamp UTC no formato RFC 3339, sem frações: `YYYY-MM-DDTHH:MM:SSZ`;
- `generation_id`: UUID;
- arrays de usuários ordenados por byte (`LC_ALL=C`) e sem duplicatas;
- usernames compatíveis com `^[a-z_][a-z0-9_-]{0,31}$`.

Exemplo:

```json
{
  "schema_version": 1,
  "source": {
    "host": "fileserver.corp",
    "role": "ROLE_STANDALONE"
  },
  "generation_id": "d6e66eb5-5f47-43e8-a9d4-41f5a1b5a2ac",
  "generated_at": "2026-08-12T22:00:00Z",
  "managed_groups": [
    "samba-users",
    "samba-admin",
    "samba-laudos",
    "samba-laudos-mega",
    "samba-administrativo"
  ],
  "groups": {
    "samba-users": ["ana", "joao"],
    "samba-admin": [],
    "samba-laudos": ["ana"],
    "samba-laudos-mega": [],
    "samba-administrativo": ["joao"]
  },
  "users": ["ana", "joao"],
  "counts": {
    "users": 2,
    "groups": 5
  }
}
```

## Invariantes

1. `managed_groups` contém exatamente, nessa ordem:
   - `samba-users`;
   - `samba-admin`;
   - `samba-laudos`;
   - `samba-laudos-mega`;
   - `samba-administrativo`.
2. `groups` contém exatamente essas cinco chaves. Grupos vazios são válidos.
3. `users` é exatamente a união ordenada e sem duplicatas dos membros.
4. Todo username é válido e existe em NSS e no `tdbsam` no momento da
   exportação.
5. `nextcloud_user` não aparece em `users` nem em qualquer grupo.
6. `counts.users` corresponde ao tamanho de `users`; `counts.groups` é `5`.
7. Propriedades desconhecidas são rejeitadas.
8. O exportador somente publica após obter duas leituras consecutivas e
   idênticas dos grupos.

## Freshness e gerações

Essas verificações são stateful e, portanto, são responsabilidade do
consumidor; não fazem parte da validação estrutural isolada executada pelo
filtro `tests/validate-nextcloud-state.jq`.

- o consumidor aceita snapshots com no máximo 6 horas;
- timestamps mais de 5 minutos no futuro são rejeitados;
- repetir o mesmo `generation_id` com conteúdo idêntico é um no-op válido;
- o mesmo `generation_id` com conteúdo diferente é corrupção e deve falhar;
- uma geração anterior ao último estado aceito é rejeitada;
- falha de relógio, transporte ou validação nunca substitui o last-known-good.

O hash SHA-256 do arquivo validado deve ser armazenado junto do
`generation_id` no estado local do consumidor.

## Circuit breakers

Os circuit breakers também dependem do last-known-good e devem ser testados
na implementação do sincronizador, além das fixtures estruturais deste
contrato.

Comparações destrutivas usam somente o último snapshot saudável aceito.
Nenhuma remoção de membership ou desativação é permitida quando:

- todos os usuários desaparecem;
- a redução é de pelo menos 25% da população anterior;
- a redução é de pelo menos 3 usuários;
- qualquer grupo obrigatório desaparece;
- o snapshot está stale, futuro, inválido ou fora de ordem.

O limiar de redução é uma condição `OR`. Exemplos:

| Usuários anteriores | Redução que bloqueia |
|---:|---:|
| 1 | 1 |
| 4 | 1 |
| 8 | 2 |
| 12 ou mais | 3 |

Ao acionar um circuit breaker, o consumidor não executa mutações e não
promove o candidato para last-known-good. A recuperação exige um snapshot que
não viole o limiar ou uma futura operação administrativa explícita de
aceitação de baseline.

## Ausência e desativação

Uma conta gerenciada somente pode ser desabilitada após:

- ausência em 3 snapshots saudáveis consecutivos;
- pelo menos 4 dias desde a primeira ausência saudável;
- marker de ownership `managed_by=samba-nextcloud-sync`;
- ausência da lista de contas protegidas;
- nenhum circuit breaker ativo.

Snapshots inválidos ou indisponíveis não avançam contadores. Reaparecimento
zera a ausência. O sincronizador normal nunca apaga contas ou arquivos.

## Exit codes

| Código | Classe |
|---:|---|
| 0 | sucesso ou no-op |
| 10 | uso ou configuração inválida |
| 11 | dependência ausente |
| 12 | privilégio incorreto |
| 20 | outra execução detém o lock |
| 30 | falha ao ler a origem |
| 31 | origem instável após as tentativas |
| 32 | divergência NSS/tdbsam |
| 33 | username inválido |
| 40 | JSON, schema ou invariante inválida |
| 41 | snapshot stale, futuro, repetido de forma inconsistente ou regressivo |
| 42 | circuit breaker acionado |
| 50 | falha de transporte |
| 51 | falha de identidade/host key SSH |
| 60 | Docker ou Nextcloud indisponível |
| 61 | falha de descoberta OCC |
| 62 | conflito com conta Nextcloud não gerenciada |
| 63 | convergência parcialmente aplicada |
| 70 | falha de filesystem ou publicação atômica |

Mensagens vão para stderr; nenhum segredo pode aparecer nos logs.
