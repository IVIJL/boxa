#!/bin/bash

# Shared Project ownership classification, scanning, and repair. Sourced by
# docker-run.sh on the host and by the root entrypoint inside the Container.

OWNERSHIP_FIX_DEFAULT=auto
OWNERSHIP_SCAN_BUDGET_MS=500
OWNERSHIP_BACKGROUND_THRESHOLD=20000
# Consumed by docker-run.sh after sourcing this library.
# shellcheck disable=SC2034
OWNERSHIP_CONFIG_NAME=ownership.conf

_ownership_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Constants and old-map arithmetic have one owner.
# The source path must work both in-tree and from /usr/local/lib/boxa.
# shellcheck source=lib/subid.sh disable=SC1091
source "$_ownership_lib_dir/subid.sh"
unset _ownership_lib_dir

ownership_config_read() {
    local file="$1" value

    value=$(awk -F= '
        /^[[:space:]]*(#|$)/ { next }
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == "ownership_fix") {
                sub(/^[^=]*=/, "")
                sub(/[[:space:]]*#.*/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                found=$0
            }
        }
        END { print found }
    ' "$file" 2>/dev/null || true)
    [ -n "$value" ] || value=$OWNERSHIP_FIX_DEFAULT
    case "$value" in
        auto|warn|off) printf '%s\n' "$value" ;;
        *) return 1 ;;
    esac
}

ownership_config_write() {
    local file="$1" value="$2" tmp

    case "$value" in
        auto|warn|off) ;;
        *) return 1 ;;
    esac
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp "$file.tmp.XXXXXX") || return 1
    if ! printf 'ownership_fix=%s\n' "$value" > "$tmp" || \
        ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}

# Output: ok, fix-root, fix-old-mapping, or warn. Root wins because replacing
# the whole subtree with U:U also removes any old-mapping owner on the peer id.
boxa_ownership_classify() {
    local owner_uid="$1" owner_gid="$2" container_uid="$3"
    local old_end=$((BOXA_OLD_SUBID_START + BOXA_SUBID_LIMIT - 2))

    boxa_validate_container_uid "$container_uid" || return 1
    if ((owner_uid == 0 || owner_gid == 0)); then
        printf 'fix-root\n'
    elif ((owner_uid >= BOXA_OLD_SUBID_START && owner_uid <= old_end)) || \
        ((owner_gid >= BOXA_OLD_SUBID_START && owner_gid <= old_end)); then
        printf 'fix-old-mapping\n'
    elif { ((owner_uid == 65534)) && ((owner_uid != container_uid)); } || \
        { ((owner_gid == 65534)) && ((owner_gid != container_uid)); } || \
        ((owner_uid < 1 || owner_uid > 65535)) || \
        ((owner_gid < 1 || owner_gid > 65535)); then
        printf 'warn\n'
    else
        printf 'ok\n'
    fi
}

# Resolve both operands before comparing so `..` and symlink escapes cannot
# make a repair target appear to be below the Project root.
boxa_ownership_path_within_root() {
    local root="$1" path="$2" canonical_root canonical_path

    canonical_root=$(realpath -e -- "$root" 2>/dev/null) || return 1
    canonical_path=$(realpath -e -- "$path" 2>/dev/null) || return 1
    [ "$canonical_path" = "$canonical_root" ] || \
        [[ "$canonical_path" == "$canonical_root/"* ]]
}

_boxa_ownership_find_candidates() {
    local root="$1" depth="$2" output="$3"
    local -a base prune

    base=("$root" -xdev)
    [ "$depth" = unlimited ] || base+=(-maxdepth "$depth")
    prune=( -type d \( \
        -name .git -o -name node_modules -o -name .venv -o -name venv -o \
        -name .cache -o -name .pnpm-store -o -name __pycache__ -o \
        -name dist -o -name build -o -name target -o -name vendor -o \
        -name .tox -o -name .mypy_cache -o -name .pytest_cache \
        \) -prune )

    find "${base[@]}" \( "${prune[@]}" \) -o \
        \( -uid 0 -o -gid 0 \) -print0 -prune > "$output" || return 1
    find "${base[@]}" \( "${prune[@]}" \) -o \
        \( -uid 0 -o -gid 0 \) -prune -o \
        \( -uid 65534 -o -gid 65534 -o -uid +65535 -o -gid +65535 \) \
        -print0 -prune >> "$output"
}

_boxa_ownership_bounded_count() {
    local path="$1"

    # awk deliberately stops the producer once the async threshold is known.
    # Disable pipefail only in this subshell: find's expected SIGPIPE is not an
    # error and the caller needs the bounded count rather than a full walk.
    (
        set +o pipefail
        find "$path" -xdev -printf '.\n' 2>/dev/null \
            | awk -v limit="$OWNERSHIP_BACKGROUND_THRESHOLD" \
                'NR > limit { print NR; exit } END { if (NR <= limit) print NR }'
    )
}

_boxa_ownership_fix_root() {
    local path="$1" container_uid="$2" purpose="$3" before count after log_file

    before=$(stat -c '%u:%g' -- "$path") || return 1
    count=$(_boxa_ownership_bounded_count "$path") || return 1
    if [ "$purpose" = startup ] && ((count > OWNERSHIP_BACKGROUND_THRESHOLD)); then
        log_file=/var/log/boxa-ownership.log
        printf 'boxa: Ownership repair queued in background: %q (before %s, more than %s entries; completion: %s).\n' \
            "$path" "$before" "$OWNERSHIP_BACKGROUND_THRESHOLD" "$log_file"
        (
            local background_count
            background_count=$(find "$path" -xdev -printf '.\n' | awk 'END { print NR }')
            if chown -R "$container_uid:$container_uid" -- "$path"; then
                after=$(stat -c '%u:%g' -- "$path")
                printf 'boxa: Ownership repair complete: %q (%s -> %s, %s entries).\n' \
                    "$path" "$before" "$after" "$background_count"
            else
                printf 'boxa: ERROR: Ownership repair failed: %q.\n' "$path" >&2
            fi
        ) >> "$log_file" 2>&1 &
        return 0
    fi
    chown -R "$container_uid:$container_uid" -- "$path" || return 1
    after=$(stat -c '%u:%g' -- "$path") || return 1
    printf 'boxa: Ownership repaired: %q (%s -> %s, %s entries).\n' \
        "$path" "$before" "$after" "$count"
}

_boxa_ownership_fix_old_mapping() {
    local path="$1" container_uid="$2" item ownership old_uid old_gid
    local new_uid new_gid before after paths_file visited=0 remapped=0 failed=0

    before=$(stat -c '%u:%g' -- "$path") || return 1
    paths_file=$(mktemp) || return 1
    if ! find "$path" -xdev -print0 > "$paths_file"; then
        rm -f "$paths_file"
        return 1
    fi
    while IFS= read -r -d '' item; do
        if ! ownership=$(stat -c '%u:%g' -- "$item"); then
            failed=1
            break
        fi
        old_uid=${ownership%%:*}
        old_gid=${ownership##*:}
        new_uid=$old_uid
        new_gid=$old_gid
        new_uid=$(boxa_old_subid_to_new "$old_uid" "$container_uid" 2>/dev/null) || \
            new_uid=$old_uid
        new_gid=$(boxa_old_subid_to_new "$old_gid" "$container_uid" 2>/dev/null) || \
            new_gid=$old_gid
        if ((new_uid != old_uid || new_gid != old_gid)); then
            if ! chown -h "$new_uid:$new_gid" -- "$item"; then
                failed=1
                break
            fi
            remapped=$((remapped + 1))
        fi
        visited=$((visited + 1))
    done < "$paths_file"
    rm -f "$paths_file"
    ((failed == 0)) || return 1
    after=$(stat -c '%u:%g' -- "$path") || return 1
    printf 'boxa: Old ownership remapped: %q (%s -> %s, %s/%s entries changed).\n' \
        "$path" "$before" "$after" "$remapped" "$visited"
}

# Process one snapshotted hit. Optional uid/gid arguments let unprivileged
# tests exercise the decision path without fabricating owners via chown.
boxa_ownership_process_hit() {
    local mode="$1" purpose="$2" path="$3" container_uid="$4"
    local owner_uid="${5:-}" owner_gid="${6:-}" ownership class

    if [ -z "$owner_uid" ] || [ -z "$owner_gid" ]; then
        ownership=$(stat -c '%u:%g' -- "$path") || return 1
        owner_uid=${ownership%%:*}
        owner_gid=${ownership##*:}
    fi
    class=$(boxa_ownership_classify "$owner_uid" "$owner_gid" "$container_uid") || return 1
    case "$class:$mode:$purpose" in
        ok:*) return 0 ;;
        fix-root:auto:*)
            _boxa_ownership_fix_root "$path" "$container_uid" "$purpose"
            ;;
        fix-old-mapping:auto:doctor)
            _boxa_ownership_fix_old_mapping "$path" "$container_uid" ;;
        *)
            printf 'boxa: Ownership action needed: %q (owner %s:%s, %s).\n' \
                "$path" "$owner_uid" "$owner_gid" "$class"
            return 3
            ;;
    esac
}

# Usage: boxa_ownership_run <project-root> <U> <auto|warn|off> <depth|unlimited>
#                           <startup|doctor>
boxa_ownership_run() {
    local root="$1" container_uid="$2" mode="$3" depth="$4" purpose="$5"
    local paths_file path started_ns elapsed_ms effective_mode="$mode"
    local hits=0 fixed=0 pending=0 failed=0 rc

    case "$mode" in auto|warn|off) ;; *) return 1 ;; esac
    case "$purpose" in startup|doctor) ;; *) return 1 ;; esac
    if [ "$mode" = off ]; then
        [ "$purpose" != doctor ] || \
            printf 'boxa: Ownership summary: 0 hit(s), 0 handled, 0 pending, 0 failed (disabled).\n'
        return 0
    fi
    boxa_ownership_path_within_root "$root" "$root" || {
        printf 'boxa: ERROR: Ownership path does not resolve under the Project root: %q\n' "$root" >&2
        return 1
    }

    paths_file=$(mktemp) || return 1
    started_ns=$(date +%s%N)
    if ! _boxa_ownership_find_candidates "$root" "$depth" "$paths_file"; then
        rm -f "$paths_file"
        return 1
    fi
    elapsed_ms=$((($(date +%s%N) - started_ns) / 1000000))
    if [ "$purpose" = startup ] && ((elapsed_ms > OWNERSHIP_SCAN_BUDGET_MS)); then
        effective_mode=warn
        printf 'boxa: WARNING: Project ownership scan took %sms (budget %sms); this start is warn-only.\n' \
            "$elapsed_ms" "$OWNERSHIP_SCAN_BUDGET_MS" >&2
    fi

    declare -A seen=()
    while IFS= read -r -d '' path; do
        [ -z "${seen[$path]:-}" ] || continue
        seen["$path"]=1
        boxa_ownership_path_within_root "$root" "$path" || {
            printf 'boxa: ERROR: Refusing ownership path outside the Project root: %q\n' "$path" >&2
            failed=$((failed + 1))
            continue
        }
        hits=$((hits + 1))
        rc=0
        boxa_ownership_process_hit "$effective_mode" "$purpose" "$path" \
            "$container_uid" || rc=$?
        case "$rc" in
            0) fixed=$((fixed + 1)) ;;
            3) pending=$((pending + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done < "$paths_file"
    rm -f "$paths_file"

    if ((pending > 0)); then
        printf "boxa: Run 'boxa doctor --fix ownership%s' on the host.\n" \
            "${BOXA_PROJECT_NAME:+ $BOXA_PROJECT_NAME}"
    fi
    if [ "$purpose" = doctor ]; then
        printf 'boxa: Ownership summary: %s hit(s), %s handled, %s pending, %s failed.\n' \
            "$hits" "$fixed" "$pending" "$failed"
    fi
    ((failed == 0)) || return 1
    ((pending == 0)) || return 3
}
