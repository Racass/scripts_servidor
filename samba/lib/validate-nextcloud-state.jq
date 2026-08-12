def fail($message):
  error($message);

def require($condition; $message):
  if $condition then . else fail($message) end;

def valid_username:
  type == "string"
  and test("^[a-z_][a-z0-9_-]{0,31}$")
  and . != "nextcloud_user";

def sorted_unique:
  . == (sort | unique);

[
  "samba-users",
  "samba-admin",
  "samba-laudos",
  "samba-laudos-mega",
  "samba-administrativo"
] as $managed
| require(type == "object"; "a raiz deve ser um objeto")
| require(
    (keys | sort) == ([
      "schema_version",
      "source",
      "generation_id",
      "generated_at",
      "managed_groups",
      "groups",
      "users",
      "counts"
    ] | sort);
    "propriedades obrigatorias ou desconhecidas na raiz"
  )
| require(.schema_version == 1; "schema_version nao suportada")
| require(
    (.source | type == "object")
    and (.source | keys | sort) == ["host", "role"]
    and (.source.host | type == "string")
    and (.source.host | test("^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$"))
    and .source.role == "ROLE_STANDALONE";
    "source invalido"
  )
| require(
    (.generation_id | type == "string")
    and (.generation_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"));
    "generation_id invalido"
  )
| require(
    (.generated_at | type == "string")
    and (.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (try (.generated_at | fromdateiso8601) catch false) != false;
    "generated_at invalido"
  )
| require(.managed_groups == $managed; "managed_groups invalido")
| require(
    (.groups | type == "object")
    and (.groups | keys | sort) == ($managed | sort);
    "chaves de groups invalidas"
  )
| . as $state
| require(
    all($managed[];
      . as $group
      | ($state.groups[$group] | type == "array")
      and ($state.groups[$group] | length <= 10000)
      and ($state.groups[$group] | sorted_unique)
      and all($state.groups[$group][]; valid_username)
    );
    "membros de groups invalidos, desordenados ou duplicados"
  )
| require(
    (.users | type == "array")
    and (.users | length <= 10000)
    and (.users | sorted_unique)
    and all(.users[]; valid_username);
    "users invalido, desordenado ou duplicado"
  )
| ([.groups[$managed[]][]] | sort | unique) as $union
| require(.users == $union; "users nao corresponde a uniao dos grupos")
| require(
    (.counts | type == "object")
    and (.counts | keys | sort) == ["groups", "users"]
    and .counts.groups == 5
    and .counts.users == (.users | length);
    "counts invalido"
  )
| true
