#!/bin/bash

# Shared arithmetic and migration decisions for the inner rootless engine.
# This file is sourced by both the root entrypoint and node-side startup.

BOXA_SUBID_LIMIT=65536
BOXA_OLD_SUBID_START=100000
BOXA_SUBID_STAMP_NAME=.boxa-subid-map

boxa_validate_container_uid() {
    local uid="$1"

    [[ "$uid" =~ ^[0-9]+$ ]] && ((uid >= 1))
}

boxa_subid_mapping_id() {
    local uid="$1"

    boxa_validate_container_uid "$uid" || return 1
    printf 'identity-hole-v1:uid=%s\n' "$uid"
}

boxa_generate_subid_ranges() {
    local uid="$1" user="${2:-node}"

    boxa_validate_container_uid "$uid" || return 1

    # A U at or above the 65536-ID budget leaves no room above the hole, so
    # the whole budget minus uid 0 sits below it as one identity range.
    if ((uid >= BOXA_SUBID_LIMIT)); then
        printf '%s:1:%s\n' "$user" "$((BOXA_SUBID_LIMIT - 1))"
        return 0
    fi
    # A zero-length first range is invalid syntax, so U=1 has only the range
    # above the hole. Production UIDs are larger, but keeping the edge valid
    # makes the generator total over every supported UID.
    if ((uid > 1)); then
        printf '%s:1:%s\n' "$user" "$((uid - 1))"
    fi
    printf '%s:%s:%s\n' "$user" "$((uid + 1))" \
        "$((BOXA_SUBID_LIMIT - uid))"
}

boxa_subid_data_root_state() {
    local data_root="$1" expected_mapping="$2" stamp

    stamp="$data_root/$BOXA_SUBID_STAMP_NAME"
    if [ -f "$stamp" ]; then
        if [ "$(cat "$stamp" 2>/dev/null)" = "$expected_mapping" ]; then
            printf 'current\n'
        else
            printf 'incompatible\n'
        fi
    elif [ -d "$data_root" ] && \
        [ -n "$(find "$data_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        printf 'legacy\n'
    else
        printf 'empty\n'
    fi
}

boxa_old_subid_to_new() {
    local old_id="$1" container_uid="$2" inner_id

    ((old_id >= BOXA_OLD_SUBID_START && \
        old_id < BOXA_OLD_SUBID_START + BOXA_SUBID_LIMIT - 1)) || return 1
    inner_id=$((old_id - BOXA_OLD_SUBID_START + 1))
    if ((inner_id >= container_uid)); then
        printf '%s\n' "$((inner_id + 1))"
    else
        printf '%s\n' "$inner_id"
    fi
}

boxa_migrate_legacy_subids() {
    local data_root="$1" container_uid="$2"
    local path ownership old_uid old_gid new_uid new_gid paths_file
    local visited=0 remapped=0 started_at=$SECONDS unsupported_id failed=0

    boxa_validate_container_uid "$container_uid" || return 1
    paths_file=$(mktemp) || return 1
    if ! find "$data_root" -print0 > "$paths_file"; then
        rm -f "$paths_file"
        return 1
    fi

    # The old 65536-entry subordinate range could represent inner uid 65536,
    # which the new 65535-entry map cannot represent. Refuse before changing
    # anything if such an owner exists; cleanup is the only lossless fallback.
    unsupported_id=$((BOXA_OLD_SUBID_START + BOXA_SUBID_LIMIT - 1))
    while IFS= read -r -d '' path; do
        if ! ownership=$(stat -c '%u:%g' -- "$path"); then
            failed=1
            break
        fi
        old_uid=${ownership%%:*}
        old_gid=${ownership##*:}
        if ((old_uid == unsupported_id || old_gid == unsupported_id)); then
            printf 'boxa: Cannot migrate inner Docker storage: owner %s has no representation in the new subid map.\n' \
                "$unsupported_id" >&2
            failed=1
            break
        fi
    done < "$paths_file"
    if ((failed)); then
        rm -f "$paths_file"
        return 1
    fi

    printf 'boxa: Migrating inner Docker storage ownership to the identity subid map...\n'
    while IFS= read -r -d '' path; do
        if ! ownership=$(stat -c '%u:%g' -- "$path"); then
            failed=1
            break
        fi
        old_uid=${ownership%%:*}
        old_gid=${ownership##*:}
        new_uid=$old_uid
        new_gid=$old_gid
        if ((old_uid >= BOXA_OLD_SUBID_START && old_uid < unsupported_id)); then
            if ! new_uid=$(boxa_old_subid_to_new "$old_uid" "$container_uid"); then
                failed=1
                break
            fi
        fi
        if ((old_gid >= BOXA_OLD_SUBID_START && old_gid < unsupported_id)); then
            if ! new_gid=$(boxa_old_subid_to_new "$old_gid" "$container_uid"); then
                failed=1
                break
            fi
        fi
        if ((new_uid != old_uid || new_gid != old_gid)); then
            if ! chown -h "$new_uid:$new_gid" -- "$path"; then
                failed=1
                break
            fi
            remapped=$((remapped + 1))
        fi
        visited=$((visited + 1))
        if ((visited % 10000 == 0)); then
            printf 'boxa: Ownership migration progress: %s entries checked, %s remapped.\n' \
                "$visited" "$remapped"
        fi
    done < "$paths_file"
    rm -f "$paths_file"
    ((failed == 0)) || return 1
    printf 'boxa: Ownership migration complete: %s entries checked, %s remapped in %ss.\n' \
        "$visited" "$remapped" "$((SECONDS - started_at))"
}

boxa_write_subid_stamp() {
    local data_root="$1" mapping="$2" stamp tmp

    stamp="$data_root/$BOXA_SUBID_STAMP_NAME"
    tmp=$(mktemp "$stamp.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$mapping" > "$tmp" || \
        ! chown node:node "$tmp" || ! chmod 0644 "$tmp" || \
        ! mv -f "$tmp" "$stamp"; then
        rm -f "$tmp"
        return 1
    fi
}
