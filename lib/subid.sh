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
    local path old_uid old_gid new_uid new_gid pair paths_file group_dir
    local entries=0 remapped=0 groups=0 started_at=$SECONDS heartbeat_pid
    local unsupported_id last_old_id failed=0

    boxa_validate_container_uid "$container_uid" || return 1
    unsupported_id=$((BOXA_OLD_SUBID_START + BOXA_SUBID_LIMIT - 1))
    last_old_id=$((unsupported_id - 1))

    printf 'boxa: Checking inner Docker storage ownership for the identity subid map (one-time)...\n'
    # Only entries owned by the old range change. find selects them in one
    # pass and prints numeric owners, so the walk costs no fork per entry (a
    # data-root with 2M entries took about an hour with one stat per entry).
    # The temp file keeps find's exit status visible without pipefail.
    paths_file=$(mktemp) || return 1
    group_dir=$(mktemp -d) || { rm -f "$paths_file"; return 1; }
    # Neither the scan nor a large chown batch prints anything by itself, so
    # a heartbeat runs for the whole migration: it tells the user (and the
    # host-side start, which relays these lines) that a large data-root is
    # still being processed rather than hung.
    (
        while sleep 5; do
            printf 'boxa: Ownership migration still running (%ss elapsed)...\n' \
                "$((SECONDS - started_at))"
        done
    ) &
    heartbeat_pid=$!
    # -depth lists children before their parent, so an interrupted remap
    # leaves the parent with its old owner and the next startup scan finds
    # the subtree again instead of seeing a repaired directory over an
    # unrepaired remainder.
    if ! find "$data_root" -depth \
            \( \( -uid +"$((BOXA_OLD_SUBID_START - 1))" -uid -"$((unsupported_id + 1))" \) \
            -o \( -gid +"$((BOXA_OLD_SUBID_START - 1))" -gid -"$((unsupported_id + 1))" \) \) \
            -printf '%U\0%G\0%p\0' > "$paths_file"; then
        kill "$heartbeat_pid" 2>/dev/null
        rm -rf "$paths_file" "$group_dir"
        return 1
    fi

    # Group paths by their old owner pair so each distinct pair costs one
    # chown invocation instead of one per entry. printf is a builtin, so this
    # pass forks nothing.
    while IFS= read -r -d '' old_uid && IFS= read -r -d '' old_gid && \
            IFS= read -r -d '' path; do
        entries=$((entries + 1))
        pair="$old_uid.$old_gid"
        if [ ! -f "$group_dir/$pair" ]; then
            groups=$((groups + 1))
        fi
        # A short write (e.g. a full /tmp) would silently drop entries from
        # the remap while the caller still stamps the data-root as current.
        if ! printf '%s\0' "$path" >> "$group_dir/$pair"; then
            failed=1
            break
        fi
    done < "$paths_file"
    rm -f "$paths_file"
    if ((failed)); then
        printf 'boxa: Cannot snapshot inner Docker storage ownership (temporary space exhausted?).\n' >&2
        kill "$heartbeat_pid" 2>/dev/null
        rm -rf "$group_dir"
        return 1
    fi

    # The old 65536-entry subordinate range could represent inner uid 65536,
    # which the new 65535-entry map cannot represent. Refuse before changing
    # anything if such an owner exists; cleanup is the only lossless fallback.
    if [ -f "$group_dir/$unsupported_id.$unsupported_id" ] || \
        compgen -G "$group_dir/$unsupported_id.*" > /dev/null || \
        compgen -G "$group_dir/*.$unsupported_id" > /dev/null; then
        printf 'boxa: Cannot migrate inner Docker storage: owner %s has no representation in the new subid map.\n' \
            "$unsupported_id" >&2
        kill "$heartbeat_pid" 2>/dev/null
        rm -rf "$group_dir"
        return 1
    fi
    printf 'boxa: Migrating inner Docker storage ownership to the identity subid map: %s entries in %s owner groups...\n' \
        "$entries" "$groups"

    for path in "$group_dir"/*; do
        [ -f "$path" ] || continue
        pair=${path##*/}
        old_uid=${pair%%.*}
        old_gid=${pair##*.}
        new_uid=$old_uid
        new_gid=$old_gid
        if ((old_uid >= BOXA_OLD_SUBID_START && old_uid <= last_old_id)); then
            if ! new_uid=$(boxa_old_subid_to_new "$old_uid" "$container_uid"); then
                failed=1
                break
            fi
        fi
        if ((old_gid >= BOXA_OLD_SUBID_START && old_gid <= last_old_id)); then
            if ! new_gid=$(boxa_old_subid_to_new "$old_gid" "$container_uid"); then
                failed=1
                break
            fi
        fi
        if ! xargs -0 -r chown -h "$new_uid:$new_gid" -- < "$path"; then
            failed=1
            break
        fi
        remapped=$((remapped + $(tr -dc '\0' < "$path" | wc -c)))
        printf 'boxa: Ownership migration progress: %s of %s entries remapped.\n' \
            "$remapped" "$entries"
    done
    kill "$heartbeat_pid" 2>/dev/null
    rm -rf "$group_dir"
    ((failed == 0)) || return 1
    printf 'boxa: Ownership migration complete: %s entries remapped in %ss.\n' \
        "$remapped" "$((SECONDS - started_at))"
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
