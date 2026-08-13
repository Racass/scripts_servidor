def managed_users:
  .protected_users as $protected
  | [.users[]
   | select(.managed_by == "samba-nextcloud-sync")
   | .user as $user
   | select(($protected | index($user)) == null)
   | .user]
  | sort
  | unique;

. as $input
| ($input.previous.users // {}) as $previous
| ($input.source_users | sort | unique) as $source_users
| (
    $input.nextcloud
    + {protected_users: ($input.protected_users // [])}
    | managed_users
  ) as $managed_users
| reduce $managed_users[] as $user (
    {};
    if ($source_users | index($user)) != null then
      .
    else
      ($previous[$user] // null) as $old
      | .[$user] = {
          first_absent_at: (
            if $old == null
            then $input.now
            else $old.first_absent_at
            end
          ),
          consecutive_snapshots: (
            if $old == null then 1
            elif $old.last_generation == $input.generation_id
            then $old.consecutive_snapshots
            else ($old.consecutive_snapshots + 1)
            end
          ),
          last_generation: $input.generation_id,
          last_absent_at: $input.now
        }
    end
  ) as $users
| {
    version: 1,
    updated_at: $input.now,
    generation_id: $input.generation_id,
    users: $users
  }
