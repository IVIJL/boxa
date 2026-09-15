#!/bin/bash

# Shared Project ownership classification, scanning, and repair. Sourced by
# docker-run.sh on the host and by the root entrypoint inside the Container.

OWNERSHIP_FIX_DEFAULT=auto
OWNERSHIP_SCAN_BUDGET_MS=500
OWNERSHIP_BACKGROUND_THRESHOLD=20000
# Consumed by docker-run.sh after sourcing this library.
# shellcheck disable=SC2034
OWNERSHIP_CONFIG_NAME=ownership.conf
# Device number of the Project root, set by boxa_ownership_run; repairs walk
# only entries on this filesystem.
OWNERSHIP_ROOT_DEVICE=

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

# A host owner is expected when it is U itself or one of the host IDs the
# identity map can emit: 1..65536 when U sits inside the 65536-ID budget
# (inner 65535 shifts to 65536), 1..65535 when U is at or above it and the
# single range below the hole is all there is.
boxa_ownership_host_id_expected() {
    local id="$1" container_uid="$2"

    ((id == container_uid)) && return 0
    # 65534 is `nobody` on the host, and inside the inner engine it is
    # what every unmapped owner collapses to; the spec keeps it a warning.
    ((id == 65534)) && return 1
    if ((container_uid < BOXA_SUBID_LIMIT)); then
        ((id >= 1 && id <= BOXA_SUBID_LIMIT))
    else
        ((id >= 1 && id < BOXA_SUBID_LIMIT))
    fi
}

# Output: ok, fix-root, fix-old-mapping, or warn. Root wins because replacing
# the whole subtree with U:U also removes any old-mapping owner on the peer id.
# Expected owners are checked before the old-map range so a U that happens to
# fall inside 100000..165534 is never "repaired" away from itself.
boxa_ownership_classify() {
    local owner_uid="$1" owner_gid="$2" container_uid="$3"
    local old_end=$((BOXA_OLD_SUBID_START + BOXA_SUBID_LIMIT - 2))

    boxa_validate_container_uid "$container_uid" || return 1
    if ((owner_uid == 0 || owner_gid == 0)); then
        printf 'fix-root\n'
    elif boxa_ownership_host_id_expected "$owner_uid" "$container_uid" && \
        boxa_ownership_host_id_expected "$owner_gid" "$container_uid"; then
        printf 'ok\n'
    elif ((owner_uid >= BOXA_OLD_SUBID_START && owner_uid <= old_end)) || \
        ((owner_gid >= BOXA_OLD_SUBID_START && owner_gid <= old_end)); then
        printf 'fix-old-mapping\n'
    else
        printf 'warn\n'
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

# Usage: _boxa_ownership_find_candidates <root> <depth|unlimited> <U> <output>
# The unexpected-owner predicate mirrors boxa_ownership_host_id_expected, so
# an expected owner (U itself above the budget, host id 65536 below it) is
# never printed and, more importantly, never pruned away with its children.
_boxa_ownership_find_candidates() {
    local root="$1" depth="$2" container_uid="$3" output="$4"
    local -a base prune unexpected
    local expected_max

    if ((container_uid < BOXA_SUBID_LIMIT)); then
        expected_max=$BOXA_SUBID_LIMIT
    else
        expected_max=$((BOXA_SUBID_LIMIT - 1))
    fi
    unexpected=( \( \
        \( -uid 65534 ! -uid "$container_uid" \) -o \
        \( -gid 65534 ! -gid "$container_uid" \) -o \
        \( -uid +"$expected_max" ! -uid "$container_uid" \) -o \
        \( -gid +"$expected_max" ! -gid "$container_uid" \) \) )

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
        "${unexpected[@]}" -print0 -prune >> "$output"
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

# Usage: _boxa_ownership_walk <path> <root-device> <output>
# Snapshot every entry of a subtree that lives on the Project root's
# filesystem (<root-device> = `stat -c %d` of the root), NUL-separated, into
# <output>. The baseline is the root's device, not the candidate's, so a
# candidate that is itself a nested mount point yields nothing. `find -xdev` does not descend into a
# nested mount but still prints the mount point itself, whose inode belongs
# to the other filesystem, so entries are filtered by device number. No
# pipeline is involved, so a failing find is reported regardless of pipefail.
_boxa_ownership_walk() {
    local path="$1" root_dev="$2" output="$3" raw dev item

    raw=$(mktemp) || return 1
    if ! find "$path" -xdev -printf '%D\0%p\0' > "$raw"; then
        rm -f "$raw"
        return 1
    fi
    while IFS= read -r -d '' dev && IFS= read -r -d '' item; do
        [ "$dev" = "$root_dev" ] || continue
        printf '%s\0' "$item"
    done < "$raw" > "$output"
    rm -f "$raw"
}

# `chown -R` crosses into nested mounts, while the scan stays on one
# filesystem (-xdev). Walk the tree the same way the scan did so a repair
# never rewrites owners on a filesystem mounted below the Project root, and
# change symlinks themselves (-h) instead of whatever they point at.
_boxa_ownership_chown_tree() {
    local container_uid="$1" path="$2" paths_file

    paths_file=$(mktemp) || return 1
    if ! _boxa_ownership_walk "$path" "$OWNERSHIP_ROOT_DEVICE" "$paths_file" || \
        ! xargs -0 --no-run-if-empty chown -h "$container_uid:$container_uid" -- \
            < "$paths_file"; then
        rm -f "$paths_file"
        return 1
    fi
    rm -f "$paths_file"
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
            if _boxa_ownership_chown_tree "$container_uid" "$path"; then
                after=$(stat -c '%u:%g' -- "$path")
                printf 'boxa: Ownership repair complete: %q (%s -> %s, %s entries).\n' \
                    "$path" "$before" "$after" "$background_count"
            else
                printf 'boxa: ERROR: Ownership repair failed: %q.\n' "$path" >&2
            fi
        ) >> "$log_file" 2>&1 &
        return 0
    fi
    _boxa_ownership_chown_tree "$container_uid" "$path" || return 1
    after=$(stat -c '%u:%g' -- "$path") || return 1
    printf 'boxa: Ownership repaired: %q (%s -> %s, %s entries).\n' \
        "$path" "$before" "$after" "$count"
}

# Old-map id -> identity id, leaving U untouched even when U happens to lie
# inside the old 100000+ range (a U-owned component is legitimate as is).
_boxa_ownership_remap_old_id() {
    local old_id="$1" container_uid="$2" new_id

    if ((old_id == container_uid)); then
        printf '%s\n' "$old_id"
        return 0
    fi
    new_id=$(boxa_old_subid_to_new "$old_id" "$container_uid" 2>/dev/null) || \
        new_id=$old_id
    printf '%s\n' "$new_id"
}

# Remap every old-map owner below <path> on the Project root's filesystem.
# One find selects only entries owned inside the old 100000+ range and prints
# numeric owners, so no fork happens per entry; paths are grouped by old owner
# pair and each group is one chown. Prints the per-subtree summary line.
_boxa_ownership_remap_old_tree() {
    local path="$1" container_uid="$2" raw group_dir dev old_uid old_gid item
    local pair new_uid new_gid entries=0 remapped=0 failed=0 before after
    local first_old last_old root_pair=""

    first_old=$BOXA_OLD_SUBID_START
    last_old=$((BOXA_OLD_SUBID_START + BOXA_SUBID_LIMIT - 1))
    before=$(stat -c '%u:%g' -- "$path") || return 1
    raw=$(mktemp) || return 1
    group_dir=$(mktemp -d) || { rm -f "$raw"; return 1; }
    # -depth: children before their parent, so an interrupted (background)
    # remap leaves the parent with its old owner and the next shallow startup
    # scan finds the subtree again.
    if ! find "$path" -xdev -depth \
            \( \( -uid +"$((first_old - 1))" -uid -"$((last_old + 1))" \) \
            -o \( -gid +"$((first_old - 1))" -gid -"$((last_old + 1))" \) \) \
            -printf '%D\0%U\0%G\0%p\0' > "$raw"; then
        rm -rf "$raw" "$group_dir"
        return 1
    fi
    while IFS= read -r -d '' dev && IFS= read -r -d '' old_uid && \
            IFS= read -r -d '' old_gid && IFS= read -r -d '' item; do
        [ "$dev" = "$OWNERSHIP_ROOT_DEVICE" ] || continue
        entries=$((entries + 1))
        # The hit itself is repaired last, after every group succeeded. Groups
        # do not preserve the -depth order across owner pairs, so this is what
        # guarantees an interrupted remap leaves the hit with its old owner
        # for the next shallow startup scan to find again.
        if [ "$item" = "$path" ]; then
            root_pair="$old_uid.$old_gid"
            continue
        fi
        if ! printf '%s\0' "$item" >> "$group_dir/$old_uid.$old_gid"; then
            failed=1
            break
        fi
    done < "$raw"
    rm -f "$raw"
    if ((failed)); then
        rm -rf "$group_dir"
        return 1
    fi
    # Old inner uid 65536 (host 165535) has no place in the new map. Stop
    # before touching anything so the hit keeps its old owner and stays
    # visible to the next scan, instead of hiding an unrepaired entry.
    if compgen -G "$group_dir/$last_old.*" > /dev/null || \
        compgen -G "$group_dir/*.$last_old" > /dev/null || \
        [ "${root_pair%%.*}" = "$last_old" ] || [ "${root_pair##*.}" = "$last_old" ]; then
        printf 'boxa: Cannot remap old ownership under %q: owner %s has no representation in the identity map.\n' \
            "$path" "$last_old" >&2
        rm -rf "$group_dir"
        return 1
    fi
    for pair in "$group_dir"/*; do
        [ -f "$pair" ] || continue
        old_uid=${pair##*/}
        old_gid=${old_uid##*.}
        old_uid=${old_uid%%.*}
        new_uid=$(_boxa_ownership_remap_old_id "$old_uid" "$container_uid")
        new_gid=$(_boxa_ownership_remap_old_id "$old_gid" "$container_uid")
        if ((new_uid == old_uid && new_gid == old_gid)); then
            continue
        fi
        if ! xargs -0 --no-run-if-empty chown -h "$new_uid:$new_gid" -- < "$pair"; then
            failed=1
            break
        fi
        remapped=$((remapped + $(tr -dc '\0' < "$pair" | wc -c)))
    done
    rm -rf "$group_dir"
    ((failed == 0)) || return 1
    if [ -n "$root_pair" ]; then
        old_uid=${root_pair%%.*}
        old_gid=${root_pair##*.}
        new_uid=$(_boxa_ownership_remap_old_id "$old_uid" "$container_uid")
        new_gid=$(_boxa_ownership_remap_old_id "$old_gid" "$container_uid")
        if ((new_uid != old_uid || new_gid != old_gid)); then
            chown -h "$new_uid:$new_gid" -- "$path" || return 1
            remapped=$((remapped + 1))
        fi
    fi
    after=$(stat -c '%u:%g' -- "$path") || return 1
    printf 'boxa: Old ownership remapped: %q (%s -> %s, %s/%s entries changed).\n' \
        "$path" "$before" "$after" "$remapped" "$entries"
}

_boxa_ownership_fix_old_mapping() {
    local path="$1" container_uid="$2" purpose="$3" count log_file

    count=$(_boxa_ownership_bounded_count "$path") || return 1
    if [ "$purpose" = startup ] && ((count > OWNERSHIP_BACKGROUND_THRESHOLD)); then
        log_file=/var/log/boxa-ownership.log
        printf 'boxa: Old ownership remap queued in background: %q (more than %s entries; completion: %s).\n' \
            "$path" "$OWNERSHIP_BACKGROUND_THRESHOLD" "$log_file"
        (
            _boxa_ownership_remap_old_tree "$path" "$container_uid" || \
                printf 'boxa: ERROR: Old ownership remap failed: %q.\n' "$path" >&2
        ) >> "$log_file" 2>&1 &
        return 0
    fi
    _boxa_ownership_remap_old_tree "$path" "$container_uid"
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
        ok:*) return 4 ;;
        fix-root:auto:*)
            _boxa_ownership_fix_root "$path" "$container_uid" "$purpose"
            ;;
        fix-old-mapping:auto:*)
            _boxa_ownership_fix_old_mapping "$path" "$container_uid" "$purpose" ;;
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

    OWNERSHIP_ROOT_DEVICE=$(stat -c '%d' -- "$root") || return 1
    paths_file=$(mktemp) || return 1
    started_ns=$(date +%s%N)
    if ! _boxa_ownership_find_candidates "$root" "$depth" "$container_uid" \
        "$paths_file"; then
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
        # `find -xdev` still prints a nested mount point; it belongs to
        # another filesystem and is never repaired.
        [ "$(stat -c '%d' -- "$path" 2>/dev/null)" = "$OWNERSHIP_ROOT_DEVICE" ] || continue
        rc=0
        boxa_ownership_process_hit "$effective_mode" "$purpose" "$path" \
            "$container_uid" || rc=$?
        # 4 = the owner is expected after all (e.g. host id 65536, or U
        # itself); the candidate scan is deliberately broader than the rule.
        [ "$rc" != 4 ] || continue
        hits=$((hits + 1))
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
