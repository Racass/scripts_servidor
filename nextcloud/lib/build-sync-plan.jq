def difference($left; $right):
  [$left[] | select(. as $item | $right | index($item) | not)];

def managed_by_sync($markers; $user):
  ($markers[$user] // "") == "samba-nextcloud-sync";

.source as $source
| (.mode // "dry-run") as $mode
| (.source_sha256 // "") as $source_sha256
| (.pending_provisioning // []) as $pending_provisioning
| .nextcloud_users as $nextcloud_users
| .nextcloud_groups as $nextcloud_groups
| .markers as $markers
| ($nextcloud_users | keys | sort) as $existing_users
| ($markers | keys | map(select(managed_by_sync($markers; .))) | sort)
    as $managed_users
| difference($source.managed_groups; ($nextcloud_groups | keys))
    as $missing_groups
| difference($source.users; $existing_users) as $new_users
| [
    $source.users[] as $user
    | select($existing_users | index($user))
    | select(managed_by_sync($markers; $user) | not)
    | $user
  ] as $conflicting_users
| [
    $managed_users[] as $user
    | select($source.users | index($user) | not)
    | $user
  ] as $absent_managed_users
| [
    $source.managed_groups[] as $group
    | $source.groups[$group][] as $user
    | select(
        ($new_users | index($user))
        or (
          managed_by_sync($markers; $user)
          and (($nextcloud_groups[$group] // []) | index($user) | not)
        )
      )
    | {
        user: $user,
        group: $group,
        after_create: (($new_users | index($user)) != null)
      }
  ] as $memberships_add
| [
    $source.managed_groups[] as $group
    | ($nextcloud_groups[$group] // [])[] as $user
    | select(managed_by_sync($markers; $user))
    | select(($source.users | index($user)) != null)
    | select($source.groups[$group] | index($user) | not)
    | {
        user: $user,
        group: $group
      }
  ] as $memberships_remove
| {
    mode: $mode,
    source_sha256: $source_sha256,
    generation_id: $source.generation_id,
    generated_at: $source.generated_at,
    missing_groups: $missing_groups,
    new_users: $new_users,
    conflicting_users: $conflicting_users,
    managed_users: $managed_users,
    absent_managed_users: $absent_managed_users,
    pending_provisioning: $pending_provisioning,
    memberships_add: $memberships_add,
    memberships_remove: $memberships_remove,
    counts: {
      source_users: ($source.users | length),
      nextcloud_users: ($existing_users | length),
      managed_users: ($managed_users | length),
      missing_groups: ($missing_groups | length),
      new_users: ($new_users | length),
      conflicts: ($conflicting_users | length),
      absent_managed_users: ($absent_managed_users | length),
      pending_provisioning: ($pending_provisioning | length),
      memberships_add: ($memberships_add | length),
      memberships_remove: ($memberships_remove | length)
    }
  }
