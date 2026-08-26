# shellcheck shell=bash
# =============================================================================
# Boxa forge credential and persona stores plus per-project gate
# =============================================================================
# Credentials and catalog personas stay in host-owned 0600 files. Persona
# files under identities/<chosen-name> use the strict version=3 key=value
# grammar parsed below. Token values live separately under tokens/<name>.<forge>.
# A repeated key=<absolute-private-key-path> attaches key references;
# forge-specific metadata fields are prefixed with github_ or gitlab_.
# forge.conf is parsed
# without sourcing it and follows the same global/project precedence as
# ssh.conf.
# =============================================================================

_BOXA_FORGE_GATE=off
_BOXA_FORGE_SOURCE=default
_BOXA_FORGE_CONF_VALID=1
_BOXA_FORGE_TOKEN=
_BOXA_FORGE_USERNAME=
_BOXA_FORGE_HOST=
_BOXA_FORGE_CREATED_AT=
_BOXA_FORGE_IDENTITY_KIND=
_BOXA_FORGE_IDENTITY_AUTH=
_BOXA_FORGE_RESOLVED_IDENTITY_ID=
_BOXA_FORGE_SYNTHESIZED_SSH_GATE=
_BOXA_FORGE_PERSONA_NAME=
_BOXA_FORGE_PERSONA_KEYS=
_BOXA_FORGE_GITHUB_TOKEN=
_BOXA_FORGE_GITHUB_USERNAME=
_BOXA_FORGE_GITHUB_CREATED_AT=
_BOXA_FORGE_GITLAB_TOKEN=
_BOXA_FORGE_GITLAB_USERNAME=
_BOXA_FORGE_GITLAB_HOST=
_BOXA_FORGE_GITLAB_CREATED_AT=
_BOXA_FORGE_COMMITTER_NAME=
_BOXA_FORGE_COMMITTER_EMAIL=
_BOXA_FORGE_DASHBOARD_PROJECTS=()
_BOXA_FORGE_DASHBOARD_HAS_LEGACY=
_BOXA_FORGE_DASHBOARD_MISSING_SSH_PROJECTS=()

BOXA_FORGE_TOKEN_LIFETIME_DAYS="${BOXA_FORGE_TOKEN_LIFETIME_DAYS:-365}"
BOXA_FORGE_EXPIRY_WARN_DAYS="${BOXA_FORGE_EXPIRY_WARN_DAYS:-30}"

_boxa::forge_store_dir() {
    printf '%s\n' "${BOXA_FORGE_DIR:-$HOME/.config/boxa/forge}"
}

_boxa::forge_legacy_ssh_gate_migration_declined_path() {
    printf '%s/legacy-ssh-gate-migration-declined\n' "$(_boxa::forge_store_dir)"
}

_boxa::forge_record_legacy_ssh_gate_migration_decline() {
    local store marker

    store="$(_boxa::forge_store_dir)"
    marker="$(_boxa::forge_legacy_ssh_gate_migration_declined_path)"
    mkdir -p "$store" || return 1
    chmod 700 "$store" || return 1
    (umask 077 && : > "$marker")
}

_boxa::forge_credential_path() {
    local forge="$1"

    case "$forge" in
        github|gitlab) ;;
        *) return 1 ;;
    esac
    printf '%s/%s\n' "$(_boxa::forge_store_dir)" "$forge"
}

_boxa::forge_identity_store_dir() {
    printf '%s/identities\n' "$(_boxa::forge_store_dir)"
}

_boxa::forge_token_store_dir() {
    printf '%s/tokens\n' "$(_boxa::forge_store_dir)"
}

_boxa::forge_validate_persona_name() {
    local name="$1"

    [ -n "$name" ] && [[ "$name" != *[!A-Za-z0-9._-]* ]] || return 1
    case "$name" in
        .|..) return 1 ;;
    esac
}

_boxa::forge_persona_token_path() {
    local name="$1" forge="$2"

    _boxa::forge_validate_persona_name "$name" || return 1
    case "$forge" in github|gitlab) ;; *) return 1 ;; esac
    printf '%s/%s.%s\n' "$(_boxa::forge_token_store_dir)" "$name" "$forge"
}

_boxa::forge_remove_persona_files() {
    local name="$1" identity_path github_path gitlab_path

    identity_path="$(_boxa::forge_identity_path "$name")" || return 1
    github_path="$(_boxa::forge_persona_token_path "$name" github)" || return 1
    gitlab_path="$(_boxa::forge_persona_token_path "$name" gitlab)" || return 1
    rm -f -- "$identity_path" "$github_path" "$gitlab_path"
}

_boxa::forge_mask_token() {
    local token="$1" length="${#1}"

    if [ "$length" -gt 11 ]; then
        printf '%s…%s\n' "${token:0:8}" "${token:length-3}"
    elif [ "$length" -gt 5 ]; then
        printf '%s…%s\n' "${token:0:2}" "${token:length-2}"
    else
        printf '…\n'
    fi
}

_boxa::forge_load_persona_token() {
    local name="$1" forge="$2" path line token='' seen=''

    path="$(_boxa::forge_persona_token_path "$name" "$forge")" || return 1
    [ -f "$path" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$seen" ] || return 1
        token="$line"
        seen=1
    done < "$path"
    [ -n "$seen" ] && [ -n "$token" ] \
        && [[ "$token" != *$'\r'* && "$token" != *$'\n'* ]] || return 1
    printf '%s\n' "$token"
}

# A malformed non-comment line invalidates the complete file. A gate grants
# credentials, so partially accepting a damaged config would be unsafe.
_boxa::resolve_forge_gate() {
    local project_path="$1"
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local line key value section="" global_value="" project_value=""
    local seen_key global_identity="" project_identity=""
    local -A seen=()

    _BOXA_FORGE_GATE=off
    _BOXA_FORGE_SOURCE=default
    _BOXA_FORGE_CONF_VALID=1
    _BOXA_FORGE_GLOBAL_IDENTITY=
    _BOXA_FORGE_PROJECT_IDENTITY=
    _BOXA_FORGE_GLOBAL_GITHUB=
    _BOXA_FORGE_GLOBAL_GITLAB=
    _BOXA_FORGE_PROJECT_GITHUB=
    _BOXA_FORGE_PROJECT_GITLAB=
    [ -f "$conf" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue

        if [[ "$line" == \[* ]]; then
            if [[ "$line" != \[*\] ]]; then
                _BOXA_FORGE_CONF_VALID=
                break
            fi
            value="${line:1:${#line}-2}"
            if [[ "$value" != /* || "$value" == *$'\r'* \
                || "$value" == *$'\n'* ]]; then
                _BOXA_FORGE_CONF_VALID=
                break
            fi
            section="$value"
            continue
        fi

        key="${line%%=*}"
        value="${line#*=}"
        if [ "$key" = "$line" ]; then
            _BOXA_FORGE_CONF_VALID=
            break
        fi
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
            forge|identity) ;;
            *)
                _BOXA_FORGE_CONF_VALID=
                break
                ;;
        esac
        seen_key="${section}"$'\n'"${key}"
        if [ -n "${seen[$seen_key]:-}" ]; then
            _BOXA_FORGE_CONF_VALID=
            break
        fi
        seen["$seen_key"]=1

        if [ "$key" = forge ]; then
            case "$value" in
                on|off) ;;
                *)
                    _BOXA_FORGE_CONF_VALID=
                    break
                    ;;
            esac
        else
            if [ "$value" != none ] \
                    && ! _boxa::forge_validate_persona_name "$value"; then
                _BOXA_FORGE_CONF_VALID=
                break
            fi
        fi

        if [ -z "$section" ]; then
            case "$key" in
                forge) global_value="$value" ;;
                identity) global_identity="$value" ;;
            esac
        elif [ "$section" = "$project_path" ]; then
            case "$key" in
                forge) project_value="$value" ;;
                identity) project_identity="$value" ;;
            esac
        fi
    done < "$conf"

    if [ -z "$_BOXA_FORGE_CONF_VALID" ]; then
        _BOXA_FORGE_GATE=off
        _BOXA_FORGE_SOURCE=invalid
    elif [ -n "$project_value" ]; then
        _BOXA_FORGE_GATE="$project_value"
        _BOXA_FORGE_SOURCE=project
    elif [ -n "$global_value" ]; then
        _BOXA_FORGE_GATE="$global_value"
        _BOXA_FORGE_SOURCE=global
    fi

    _BOXA_FORGE_GLOBAL_IDENTITY="$global_identity"
    _BOXA_FORGE_PROJECT_IDENTITY="$project_identity"
    # Transitional internal aliases keep the pre-persona registration code
    # isolated until issue 15 removes it. They are never parsed or written.
    _BOXA_FORGE_GLOBAL_GITHUB="$global_identity"
    _BOXA_FORGE_GLOBAL_GITLAB="$global_identity"
    _BOXA_FORGE_PROJECT_GITHUB="$project_identity"
    _BOXA_FORGE_PROJECT_GITLAB="$project_identity"
}

_boxa::resolve_forge_identity() {
    local project_path="$1" forge="${2:-}" resolved

    _BOXA_FORGE_RESOLVED_IDENTITY_ID=
    case "$forge" in github|gitlab|'') ;; *) return 1 ;; esac

    _boxa::resolve_forge_gate "$project_path"
    [ -n "$_BOXA_FORGE_CONF_VALID" ] || return 0
    resolved="${_BOXA_FORGE_PROJECT_IDENTITY:-$_BOXA_FORGE_GLOBAL_IDENTITY}"
    [ "$resolved" != none ] || resolved=
    if [ -n "$resolved" ] && [ -n "$forge" ]; then
        _boxa::forge_load_persona "$resolved" || resolved=
        case "$forge" in
            github) [ -n "$_BOXA_FORGE_GITHUB_TOKEN" ] || resolved= ;;
            gitlab) [ -n "$_BOXA_FORGE_GITLAB_TOKEN" ] || resolved= ;;
        esac
    fi
    _BOXA_FORGE_RESOLVED_IDENTITY_ID="$resolved"
}

# True when any global or per-Project forge gate is on. Section discovery only
# supplies paths to the strict canonical resolver, which still rejects the
# complete file when any line is malformed.
_boxa::forge_usage_configured() {
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local line parsed section

    _boxa::resolve_forge_gate ""
    [ -n "$_BOXA_FORGE_CONF_VALID" ] || return 1
    if [ "$_BOXA_FORGE_SOURCE" = global ] && [ "$_BOXA_FORGE_GATE" = on ]; then
        return 0
    fi
    [ -f "$conf" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        parsed="${line%%#*}"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"
        [[ "$parsed" == \[*\] ]] || continue
        section="${parsed:1:${#parsed}-2}"
        [[ "$section" == /* ]] || continue
        _boxa::resolve_forge_gate "$section"
        [ -n "$_BOXA_FORGE_CONF_VALID" ] || return 1
        if [ "$_BOXA_FORGE_SOURCE" = project ] \
                && [ "$_BOXA_FORGE_GATE" = on ]; then
            return 0
        fi
    done < "$conf"
    return 1
}

# Replace one value without normalising any bytes outside that key.
# Usage: _boxa::write_forge_conf <global|project> <path> <value> [forge|identity]
_boxa::write_forge_conf_locked() {
    local scope="$1" project_path="$2" config_value="$3"
    local config_key="${4:-forge}"
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local conf_dir temp stripped line parsed value section="" target_seen=''
    local output_started='' file_had_newline=''

    case "$config_key" in
        forge)
            case "$config_value" in
                on|off) ;;
                *)
                    printf 'Invalid forge gate value: %s (expected on or off)\n' \
                        "$config_value" >&2
                    return 1
                    ;;
            esac
            ;;
        identity)
            if [ "$config_value" != none ] \
                    && ! _boxa::forge_validate_persona_name "$config_value"; then
                printf 'Invalid persona name: %s\n' "$config_value" >&2
                return 1
            fi
            ;;
        *)
            printf 'Unknown forge.conf key: %s\n' "$config_key" >&2
            return 1
            ;;
    esac
    case "$scope" in
        global) ;;
        project)
            if [[ "$project_path" != /* ]]; then
                printf 'Forge gate requires an absolute host project path: %s\n' \
                    "$project_path" >&2
                return 1
            fi
            if [[ "$project_path" == *'#'* || "$project_path" == *$'\r'* \
                || "$project_path" == *$'\n'* ]]; then
                printf "Cannot update forge gate for path containing '#', CR, or LF: %q\n" \
                    "$project_path" >&2
                printf 'forge.conf cannot represent this path.\n' >&2
                return 1
            fi
            ;;
        *)
            printf 'Unknown forge.conf scope: %s\n' "$scope" >&2
            return 1
            ;;
    esac

    conf_dir="${conf%/*}"
    [ "$conf_dir" != "$conf" ] || conf_dir=.
    mkdir -p "$conf_dir" || return 1
    [ -f "$conf" ] || (umask 077 && : > "$conf")
    if [ -s "$conf" ] \
        && [ "$(tail -c 1 "$conf" | wc -l | tr -d ' ')" -gt 0 ]; then
        file_had_newline=1
    fi

    stripped="$(mktemp "${conf}.tmp.XXXXXX")" || return 1
    temp="$(mktemp "${conf}.tmp.XXXXXX")" || {
        rm -f "$stripped"
        return 1
    }
    _boxa::remove_conf_keys "$scope" "$project_path" "$conf" "$stripped" \
        "$config_key"

    while IFS= read -r line || [ -n "$line" ]; do
        parsed="${line%%#*}"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"

        if [[ "$parsed" == \[* ]]; then
            if [[ "$parsed" == \[*\] ]]; then
                value="${parsed:1:${#parsed}-2}"
            else
                value=
            fi
            if [ "$scope" = global ] && [ -z "$target_seen" ]; then
                [ -z "$output_started" ] || printf '\n' >> "$temp"
                printf '%s = %s' "$config_key" "$config_value" >> "$temp"
                output_started=1
                target_seen=1
            elif [ "$scope" = project ] && [ "$section" = "$project_path" ] \
                && [ -z "$target_seen" ]; then
                [ -z "$output_started" ] || printf '\n' >> "$temp"
                printf '%s = %s' "$config_key" "$config_value" >> "$temp"
                output_started=1
                target_seen=1
            fi
            if [[ "$parsed" == \[*\] && "$value" == /* ]]; then
                section="$value"
            else
                section=INVALID
            fi
        fi

        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf '%s' "$line" >> "$temp"
        output_started=1
    done < "$stripped"

    if [ "$scope" = project ] && [ "$section" = "$project_path" ] \
        && [ -z "$target_seen" ]; then
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf '%s = %s' "$config_key" "$config_value" >> "$temp"
        output_started=1
        target_seen=1
    fi
    if [ "$scope" = global ] && [ -z "$target_seen" ]; then
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf '%s = %s' "$config_key" "$config_value" >> "$temp"
        output_started=1
    elif [ "$scope" = project ] && [ -z "$target_seen" ]; then
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf '[%s]\n%s = %s' "$project_path" "$config_key" \
            "$config_value" >> "$temp"
        output_started=1
    fi
    if [ -n "$file_had_newline" ] && [ -n "$output_started" ]; then
        printf '\n' >> "$temp"
    fi

    chmod "$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf")" \
        "$temp" || {
        rm -f "$stripped" "$temp"
        return 1
    }
    mv "$temp" "$conf" || {
        rm -f "$stripped" "$temp"
        return 1
    }
    rm -f "$stripped"
}

_boxa::write_forge_conf() {
    local scope="$1" project_path="$2" config_value="$3"
    local config_key="${4:-forge}"

    _boxa::forge_with_catalog_lock _boxa::write_forge_conf_locked \
        "$scope" "$project_path" "$config_value" "$config_key"
}

_boxa::forge_run_catalog_locked() {
    local callback="$1"
    shift

    _BOXA_FORGE_CATALOG_LOCK_HELD=1
    "$callback" "$@"
}

_boxa::forge_with_catalog_lock() {
    local callback="$1"
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local conf_dir lock status
    shift

    if [ -n "${_BOXA_FORGE_CATALOG_LOCK_HELD:-}" ]; then
        "$callback" "$@"
        return
    fi
    conf_dir="${conf%/*}"
    [ "$conf_dir" != "$conf" ] || conf_dir=.
    mkdir -p "$conf_dir" || return 1
    lock="${conf}.lock"
    if _boxa::with_pid_lock "$lock" _boxa::forge_run_catalog_locked \
            "$callback" "$@"; then
        return 0
    else
        status=$?
    fi
    if [ "$status" -eq 75 ]; then
        printf 'Timed out waiting for forge catalog lock: %s\n' "$lock" >&2
    fi
    return "$status"
}

_boxa::forge_with_catalog_read_lock() {
    local callback="$1"
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local conf_dir lock status
    local _BOXA_FORGE_CATALOG_LOCK_HELD=1
    shift

    conf_dir="${conf%/*}"
    [ "$conf_dir" != "$conf" ] || conf_dir=.
    mkdir -p "$conf_dir" || return 1
    lock="${conf}.lock"
    if ! _boxa::acquire_pid_lock "$lock"; then
        printf 'Timed out waiting for forge catalog lock: %s\n' "$lock" >&2
        return 75
    fi
    if "$callback" "$@"; then
        status=0
    else
        status=$?
    fi
    rm -rf -- "$lock"
    return "$status"
}

_boxa::forge_write_default_identity() {
    local forge="$1" identity_id="$2"

    case "$forge" in github|gitlab) ;; *) return 1 ;; esac
    _boxa::write_forge_conf global '' "$identity_id" identity
}

_boxa::forge_write_credential() {
    local forge="$1" token="$2" username="$3" host="$4" created_at="$5"
    local store path temp

    store="$(_boxa::forge_store_dir)"
    path="$(_boxa::forge_credential_path "$forge")" || return 1
    mkdir -p "$store" || return 1
    chmod 700 "$store" || return 1
    temp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
    if ! (umask 077 && printf 'version=1\ncreated_at=%s\nusername=%s\nhost=%s\ntoken=%s\n' \
            "$created_at" "$username" "$host" "$token" > "$temp") \
            || ! chmod 600 "$temp" || ! mv "$temp" "$path"; then
        rm -f "$temp"
        return 1
    fi
}

_boxa::forge_load_credential() {
    local forge="$1" path line key value
    local version='' seen_version='' seen_created='' seen_username=''
    local seen_host='' seen_token=''

    _BOXA_FORGE_TOKEN=
    _BOXA_FORGE_USERNAME=
    _BOXA_FORGE_HOST=
    _BOXA_FORGE_CREATED_AT=
    path="$(_boxa::forge_credential_path "$forge")" || return 1
    [ -f "$path" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" != "$line" ] || return 1
        case "$key" in
            version)
                [ -z "$seen_version" ] || return 1
                version="$value"
                seen_version=1
                ;;
            created_at)
                [ -z "$seen_created" ] || return 1
                _BOXA_FORGE_CREATED_AT="$value"
                seen_created=1
                ;;
            username)
                [ -z "$seen_username" ] || return 1
                _BOXA_FORGE_USERNAME="$value"
                seen_username=1
                ;;
            host)
                [ -z "$seen_host" ] || return 1
                _BOXA_FORGE_HOST="$value"
                seen_host=1
                ;;
            token)
                [ -z "$seen_token" ] || return 1
                _BOXA_FORGE_TOKEN="$value"
                seen_token=1
                ;;
            *) return 1 ;;
        esac
    done < "$path"

    [ "$version" = 1 ] && [ -n "$seen_created" ] \
        && [ -n "$seen_username" ] && [ -n "$seen_host" ] \
        && [ -n "$seen_token" ] && [ -n "$_BOXA_FORGE_TOKEN" ] \
        && [[ "$_BOXA_FORGE_CREATED_AT" =~ ^[0-9]+$ ]]
}

_boxa::forge_probe() {
    local forge="$1" token="$2" host="$3" response login

    case "$forge" in
        github)
            command -v gh >/dev/null 2>&1 || return 1
            response="$(GH_TOKEN="$token" gh api user 2>/dev/null)" || return 1
            login="$(printf '%s' "$response" \
                | jq -er '.login | strings | select(length > 0)' 2>/dev/null)" \
                || return 1
            ;;
        gitlab)
            command -v glab >/dev/null 2>&1 || return 1
            response="$(GITLAB_TOKEN="$token" GITLAB_HOST="$host" \
                glab api user 2>/dev/null)" || return 1
            login="$(printf '%s' "$response" \
                | jq -er '(.username // .login) | strings | select(length > 0)' \
                    2>/dev/null)" || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "$login" != *$'\r'* && "$login" != *$'\n'* ]] || return 1
    printf '%s\n' "$login"
}

_boxa::forge_require_probe_cli() {
    case "$1" in
        github)
            command -v gh >/dev/null 2>&1 && return 0
            printf "Token verification needs the gh CLI on this host. Install it (see https://cli.github.com/) and retry.\n" >&2
            ;;
        gitlab)
            command -v glab >/dev/null 2>&1 && return 0
            printf "Token verification needs the glab CLI on this host. Install it (e.g. 'sudo apt install glab' or the .deb from https://gitlab.com/gitlab-org/cli/-/releases) and retry.\n" >&2
            ;;
        *) return 1 ;;
    esac
    return 1
}

_boxa::forge_validate_host() {
    local host="$1" hostname port=''

    [ -n "$host" ] && [[ "$host" != *[!A-Za-z0-9._:-]* ]] \
        && [[ "$host" != *$'\r'* && "$host" != *$'\n'* ]] || return 1
    hostname="$host"
    if [[ "$host" == *:* ]]; then
        hostname="${host%:*}"
        port="${host##*:}"
        [[ "$hostname" != *:* ]] && [[ "$port" =~ ^[0-9]+$ ]] \
            && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    fi
    [ -n "$hostname" ] && [[ "$hostname" != *[!A-Za-z0-9._-]* ]] || return 1
    case "$hostname" in
        .|..) return 1 ;;
    esac
}

_boxa::forge_legacy_identity_id() {
    local forge="$1" host="$2" username="$3"

    [ -n "$username" ] && [[ "$username" != *[!A-Za-z0-9._-]* ]] \
        || return 1
    case "$username" in
        .|..) return 1 ;;
    esac
    case "$forge" in
        github)
            [ -z "$host" ] || return 1
            printf 'github:%s\n' "$username"
            ;;
        gitlab)
            _boxa::forge_validate_host "$host" || return 1
            printf 'gitlab:%s:%s\n' "$host" "$username"
            ;;
        *) return 1 ;;
    esac
}

_boxa::forge_validate_legacy_identity_id() {
    local identity_id="$1" forge host username rest expected

    case "$identity_id" in
        github:*)
            forge=github
            host=
            username="${identity_id#github:}"
            ;;
        gitlab:*)
            forge=gitlab
            rest="${identity_id#gitlab:}"
            [[ "$rest" == *:* ]] || return 1
            host="${rest%:*}"
            username="${rest##*:}"
            [[ "$username" != *:* ]] || return 1
            ;;
        *) return 1 ;;
    esac
    expected="$(_boxa::forge_legacy_identity_id "$forge" "$host" "$username")" \
        || return 1
    [ "$identity_id" = "$expected" ]
}

# Kept as an internal compatibility seam for uncataloged credentials. Token
# rotation and legacy helpers may use the verified forge username as a suggested
# persona name; the registration flow itself always asks for a name.
_boxa::forge_identity_id() {
    local forge="$1" host="$2" username="$3"

    _boxa::forge_legacy_identity_id "$forge" "$host" "$username" >/dev/null \
        || return 1
    printf '%s\n' "$username"
}

_boxa::forge_validate_identity_id() {
    _boxa::forge_validate_persona_name "$1"
}

_boxa::forge_identity_path() {
    local identity_id="$1"

    _boxa::forge_validate_persona_name "$identity_id" || return 1
    printf '%s/%s\n' "$(_boxa::forge_identity_store_dir)" "$identity_id"
}

_boxa::forge_validate_persona() {
    local name="$1" kind="$2" keys="$3"
    local github_token="$4" github_username="$5" github_created_at="$6"
    local gitlab_token="$7" gitlab_username="$8" gitlab_host="$9"
    local gitlab_created_at="${10}" key_path
    local -A seen_keys=()

    _boxa::forge_validate_persona_name "$name" || return 1
    case "$kind" in
        mine|agent|other) ;;
        *) return 1 ;;
    esac
    while IFS= read -r key_path; do
        [ -z "$key_path" ] && continue
        [[ "$key_path" == /* && "$key_path" != *$'\r'* \
            && "$key_path" != *$'\n'* ]] || return 1
        [ -z "${seen_keys[$key_path]:-}" ] || return 1
        seen_keys["$key_path"]=1
    done <<< "$keys"
    if [ -n "$github_token" ]; then
        [[ "$github_token" != *$'\r'* && "$github_token" != *$'\n'* \
            && "$github_created_at" =~ ^[0-9]+$ ]] \
            && _boxa::forge_legacy_identity_id github '' "$github_username" \
                >/dev/null || return 1
    elif [ -n "$github_username$github_created_at" ]; then
        return 1
    fi
    if [ -n "$gitlab_token" ]; then
        [[ "$gitlab_token" != *$'\r'* && "$gitlab_token" != *$'\n'* \
            && "$gitlab_created_at" =~ ^[0-9]+$ ]] \
            && _boxa::forge_legacy_identity_id gitlab "$gitlab_host" \
                "$gitlab_username" >/dev/null || return 1
    elif [ -n "$gitlab_username$gitlab_host$gitlab_created_at" ]; then
        return 1
    fi
    [ -z "$keys" ] || [ -n "$github_token$gitlab_token" ] || return 1
    [ -n "$github_token$gitlab_token" ]
}

_boxa::forge_abort_persona_publication() {
    local status="$1"

    trap '' HUP INT TERM
    if [ -n "${publication_committed:-}" ] || {
            [ ! -e "$temp" ] && [ -f "$path" ];
        }; then
        _boxa::forge_discard_backup "$github_backup"
        _boxa::forge_discard_backup "$gitlab_backup"
        rm -f "$temp" "${token_temps[@]}"
        exit "$status"
    fi
    _boxa::forge_restore_file "$github_path" "$github_backup" \
        "$github_existed" || true
    _boxa::forge_restore_file "$gitlab_path" "$gitlab_backup" \
        "$gitlab_existed" || true
    rm -f "$temp" "${token_temps[@]}"
    exit "$status"
}

_boxa::forge_write_persona_locked() {
    local name="$1" kind="$2" keys="$3"
    local github_token="$4" github_username="$5" github_created_at="$6"
    local gitlab_token="$7" gitlab_username="$8" gitlab_host="$9"
    local gitlab_created_at="${10}" replace="${11:-false}"
    local root store token_store path temp key_path forge token token_path
    local token_temp github_path gitlab_path github_backup='' gitlab_backup=''
    local github_existed='' gitlab_existed='' status=0
    local publication_committed=''
    local -a token_temps=() token_paths=()

    _boxa::forge_validate_persona "$name" "$kind" "$keys" \
        "$github_token" "$github_username" "$github_created_at" \
        "$gitlab_token" "$gitlab_username" "$gitlab_host" \
        "$gitlab_created_at" || return 1
    root="$(_boxa::forge_store_dir)"
    store="$(_boxa::forge_identity_store_dir)"
    token_store="$(_boxa::forge_token_store_dir)"
    path="$(_boxa::forge_identity_path "$name")" || return 1
    if [ -e "$path" ] && [ "$replace" != true ]; then
        printf "Persona '%s' already exists. Choose a different name.\n" \
            "$name" >&2
        return 1
    fi
    mkdir -p "$store" "$token_store" || return 1
    chmod 700 "$root" "$store" "$token_store" || return 1
    temp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
    if ! (umask 077 && {
            printf 'version=3\nname=%s\nkind=%s\n' "$name" "$kind"
            while IFS= read -r key_path; do
                [ -z "$key_path" ] || printf 'key=%s\n' "$key_path"
            done <<< "$keys"
            printf 'github_created_at=%s\ngithub_username=%s\n' \
                "$github_created_at" "$github_username"
            printf 'gitlab_created_at=%s\ngitlab_host=%s\ngitlab_username=%s\n' \
                "$gitlab_created_at" "$gitlab_host" "$gitlab_username"
        } > "$temp") || ! chmod 600 "$temp"; then
        rm -f "$temp"
        return 1
    fi
    for forge in github gitlab; do
        case "$forge" in
            github) token="$github_token" ;;
            gitlab) token="$gitlab_token" ;;
        esac
        [ -n "$token" ] || continue
        token_path="$(_boxa::forge_persona_token_path "$name" "$forge")" \
            || { rm -f "$temp" "${token_temps[@]}"; return 1; }
        token_temp="$(mktemp "${token_path}.tmp.XXXXXX")" \
            || { rm -f "$temp" "${token_temps[@]}"; return 1; }
        if ! (umask 077 && printf '%s\n' "$token" > "$token_temp") \
                || ! chmod 600 "$token_temp"; then
            rm -f "$temp" "$token_temp" "${token_temps[@]}"
            return 1
        fi
        token_temps+=("$token_temp")
        token_paths+=("$token_path")
    done
    github_path="$(_boxa::forge_persona_token_path "$name" github)" \
        || { rm -f "$temp" "${token_temps[@]}"; return 1; }
    gitlab_path="$(_boxa::forge_persona_token_path "$name" gitlab)" \
        || { rm -f "$temp" "${token_temps[@]}"; return 1; }
    _boxa::forge_backup_file "$github_path" github_backup github_existed \
        || { rm -f "$temp" "${token_temps[@]}"; return 1; }
    if ! _boxa::forge_backup_file "$gitlab_path" gitlab_backup \
            gitlab_existed; then
        _boxa::forge_discard_backup "$github_backup"
        rm -f "$temp" "${token_temps[@]}"
        return 1
    fi
    trap '_boxa::forge_abort_persona_publication 129' HUP
    trap '_boxa::forge_abort_persona_publication 130' INT
    trap '_boxa::forge_abort_persona_publication 143' TERM
    for ((forge = 0; forge < ${#token_temps[@]}; forge++)); do
        if ! mv "${token_temps[$forge]}" "${token_paths[$forge]}"; then
            status=1
            break
        fi
    done
    if [ "$status" -eq 0 ] && [ -z "$github_token" ]; then
        rm -f -- "$github_path" || status=1
    fi
    if [ "$status" -eq 0 ] && [ -z "$gitlab_token" ]; then
        rm -f -- "$gitlab_path" || status=1
    fi
    if [ "$status" -eq 0 ] && mv "$temp" "$path"; then
        publication_committed=1
        trap - HUP INT TERM
    else
        status=1
    fi
    if [ "$status" -ne 0 ]; then
        _boxa::forge_restore_file "$github_path" "$github_backup" \
            "$github_existed" || true
        _boxa::forge_restore_file "$gitlab_path" "$gitlab_backup" \
            "$gitlab_existed" || true
        rm -f "$temp" "${token_temps[@]}"
        trap - HUP INT TERM
        return 1
    fi
    _boxa::forge_discard_backup "$github_backup"
    _boxa::forge_discard_backup "$gitlab_backup"
}

_boxa::forge_write_persona() {
    _boxa::forge_with_catalog_lock _boxa::forge_write_persona_locked "$@"
}

_boxa::forge_load_persona_locked() {
    local name="$1" path line key value key_path
    local version='' seen_version='' seen_name='' seen_kind=''
    local seen_github_created='' seen_github_username='' seen_github_token=''
    local seen_gitlab_created='' seen_gitlab_host=''
    local seen_gitlab_username='' seen_gitlab_token=''
    local -A seen_keys=()

    _BOXA_FORGE_PERSONA_NAME=
    _BOXA_FORGE_PERSONA_KEYS=
    _BOXA_FORGE_IDENTITY_KIND=
    _BOXA_FORGE_GITHUB_TOKEN=
    _BOXA_FORGE_GITHUB_USERNAME=
    _BOXA_FORGE_GITHUB_CREATED_AT=
    _BOXA_FORGE_GITLAB_TOKEN=
    _BOXA_FORGE_GITLAB_USERNAME=
    _BOXA_FORGE_GITLAB_HOST=
    _BOXA_FORGE_GITLAB_CREATED_AT=
    path="$(_boxa::forge_identity_path "$name")" || return 1
    [ -f "$path" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" != "$line" ] || return 1
        case "$key" in
            version)
                [ -z "$seen_version" ] || return 1
                version="$value"
                seen_version=1
                ;;
            name)
                [ -z "$seen_name" ] || return 1
                _BOXA_FORGE_PERSONA_NAME="$value"
                seen_name=1
                ;;
            kind)
                [ -z "$seen_kind" ] || return 1
                _BOXA_FORGE_IDENTITY_KIND="$value"
                seen_kind=1
                ;;
            key)
                key_path="$value"
                [ -n "$key_path" ] && [ -z "${seen_keys[$key_path]:-}" ] \
                    || return 1
                seen_keys["$key_path"]=1
                _BOXA_FORGE_PERSONA_KEYS+="${_BOXA_FORGE_PERSONA_KEYS:+$'\n'}$key_path"
                ;;
            github_created_at)
                [ -z "$seen_github_created" ] || return 1
                _BOXA_FORGE_GITHUB_CREATED_AT="$value"
                seen_github_created=1
                ;;
            github_username)
                [ -z "$seen_github_username" ] || return 1
                _BOXA_FORGE_GITHUB_USERNAME="$value"
                seen_github_username=1
                ;;
            github_token)
                [ -z "$seen_github_token" ] || return 1
                _BOXA_FORGE_GITHUB_TOKEN="$value"
                seen_github_token=1
                ;;
            gitlab_created_at)
                [ -z "$seen_gitlab_created" ] || return 1
                _BOXA_FORGE_GITLAB_CREATED_AT="$value"
                seen_gitlab_created=1
                ;;
            gitlab_host)
                [ -z "$seen_gitlab_host" ] || return 1
                _BOXA_FORGE_GITLAB_HOST="$value"
                seen_gitlab_host=1
                ;;
            gitlab_username)
                [ -z "$seen_gitlab_username" ] || return 1
                _BOXA_FORGE_GITLAB_USERNAME="$value"
                seen_gitlab_username=1
                ;;
            gitlab_token)
                [ -z "$seen_gitlab_token" ] || return 1
                _BOXA_FORGE_GITLAB_TOKEN="$value"
                seen_gitlab_token=1
                ;;
            *) return 1 ;;
        esac
    done < "$path"

    [ -n "$seen_name" ] && [ -n "$seen_kind" ] \
        && [ -n "$seen_github_created" ] \
        && [ -n "$seen_github_username" ] \
        && [ -n "$seen_gitlab_created" ] && [ -n "$seen_gitlab_host" ] \
        && [ -n "$seen_gitlab_username" ] \
        && [ "$name" = "$_BOXA_FORGE_PERSONA_NAME" ] || return 1
    case "$version" in
        2)
            [ -n "$seen_github_token" ] && [ -n "$seen_gitlab_token" ] \
                || return 1
            ;;
        3)
            [ -z "$seen_github_token$seen_gitlab_token" ] || return 1
            if [ -n "$_BOXA_FORGE_GITHUB_USERNAME$_BOXA_FORGE_GITHUB_CREATED_AT" ]; then
                _BOXA_FORGE_GITHUB_TOKEN="$(_boxa::forge_load_persona_token \
                    "$name" github)" || return 1
            elif [ -e "$(_boxa::forge_persona_token_path "$name" github)" ]; then
                return 1
            fi
            if [ -n "$_BOXA_FORGE_GITLAB_USERNAME$_BOXA_FORGE_GITLAB_HOST$_BOXA_FORGE_GITLAB_CREATED_AT" ]; then
                _BOXA_FORGE_GITLAB_TOKEN="$(_boxa::forge_load_persona_token \
                    "$name" gitlab)" || return 1
            elif [ -e "$(_boxa::forge_persona_token_path "$name" gitlab)" ]; then
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
    _boxa::forge_validate_persona "$name" \
            "$_BOXA_FORGE_IDENTITY_KIND" "$_BOXA_FORGE_PERSONA_KEYS" \
            "$_BOXA_FORGE_GITHUB_TOKEN" "$_BOXA_FORGE_GITHUB_USERNAME" \
            "$_BOXA_FORGE_GITHUB_CREATED_AT" "$_BOXA_FORGE_GITLAB_TOKEN" \
            "$_BOXA_FORGE_GITLAB_USERNAME" "$_BOXA_FORGE_GITLAB_HOST" \
            "$_BOXA_FORGE_GITLAB_CREATED_AT"
}

_boxa::forge_load_persona() {
    if [ -n "${_BOXA_FORGE_CATALOG_LOCK_HELD:-}" ]; then
        _boxa::forge_load_persona_locked "$@"
    else
        _boxa::forge_with_catalog_read_lock \
            _boxa::forge_load_persona_locked "$@"
    fi
}

_boxa::forge_select_persona_forge() {
    local forge="$1"

    case "$forge" in
        github)
            [ -n "$_BOXA_FORGE_GITHUB_TOKEN" ] || return 1
            _BOXA_FORGE_TOKEN="$_BOXA_FORGE_GITHUB_TOKEN"
            _BOXA_FORGE_USERNAME="$_BOXA_FORGE_GITHUB_USERNAME"
            _BOXA_FORGE_HOST=
            _BOXA_FORGE_CREATED_AT="$_BOXA_FORGE_GITHUB_CREATED_AT"
            ;;
        gitlab)
            [ -n "$_BOXA_FORGE_GITLAB_TOKEN" ] || return 1
            _BOXA_FORGE_TOKEN="$_BOXA_FORGE_GITLAB_TOKEN"
            _BOXA_FORGE_USERNAME="$_BOXA_FORGE_GITLAB_USERNAME"
            _BOXA_FORGE_HOST="$_BOXA_FORGE_GITLAB_HOST"
            _BOXA_FORGE_CREATED_AT="$_BOXA_FORGE_GITLAB_CREATED_AT"
            ;;
        *) return 1 ;;
    esac
    if [ -n "$_BOXA_FORGE_PERSONA_KEYS" ]; then
        _BOXA_FORGE_IDENTITY_AUTH=ssh
    else
        _BOXA_FORGE_IDENTITY_AUTH=token
    fi
}

_boxa::forge_load_identity() {
    local name="$1" forge="${2:-}"

    _boxa::forge_load_persona "$name" || return 1
    if [ -z "$forge" ]; then
        if [ -n "$_BOXA_FORGE_GITHUB_TOKEN" ]; then
            forge=github
        elif [ -n "$_BOXA_FORGE_GITLAB_TOKEN" ]; then
            forge=gitlab
        else
            return 1
        fi
    fi
    _boxa::forge_select_persona_forge "$forge"
}

_boxa::forge_load_committer_identity() {
    local name="$1" username host

    _BOXA_FORGE_COMMITTER_NAME=
    _BOXA_FORGE_COMMITTER_EMAIL=
    _boxa::forge_load_persona "$name" || return 1
    if [ -n "$_BOXA_FORGE_GITHUB_TOKEN" ]; then
        username="$_BOXA_FORGE_GITHUB_USERNAME"
        host=users.noreply.github.com
    elif [ -n "$_BOXA_FORGE_GITLAB_TOKEN" ]; then
        username="$_BOXA_FORGE_GITLAB_USERNAME"
        host="${_BOXA_FORGE_GITLAB_HOST:-gitlab.com}"
        host="${host%%:*}"
    else
        return 1
    fi
    [ -n "$username" ] || return 1
    _BOXA_FORGE_COMMITTER_NAME="$username"
    _BOXA_FORGE_COMMITTER_EMAIL="${username}@${host}"
}

_boxa::forge_write_identity() {
    local forge="$1" kind="$2" token="$3" username="$4" host="$5"
    local created_at="$6" auth="${7:-ssh}" name="${8:-$username}"
    local attached_keys="${9:-}"
    local keys='' github_token='' github_username='' github_created_at=''
    local gitlab_token='' gitlab_username='' gitlab_host=''
    local gitlab_created_at='' replace=false

    if _boxa::forge_load_persona "$name"; then
        [ "$_BOXA_FORGE_IDENTITY_KIND" = "$kind" ] || return 1
        keys="$_BOXA_FORGE_PERSONA_KEYS"
        github_token="$_BOXA_FORGE_GITHUB_TOKEN"
        github_username="$_BOXA_FORGE_GITHUB_USERNAME"
        github_created_at="$_BOXA_FORGE_GITHUB_CREATED_AT"
        gitlab_token="$_BOXA_FORGE_GITLAB_TOKEN"
        gitlab_username="$_BOXA_FORGE_GITLAB_USERNAME"
        gitlab_host="$_BOXA_FORGE_GITLAB_HOST"
        gitlab_created_at="$_BOXA_FORGE_GITLAB_CREATED_AT"
        replace=true
    fi
    if [ "$auth" = ssh ]; then
        [ -z "$attached_keys" ] || keys="$attached_keys"
    elif [ "$auth" != token ]; then
        return 1
    fi
    case "$forge" in
        github)
            github_token="$token"
            github_username="$username"
            github_created_at="$created_at"
            ;;
        gitlab)
            gitlab_token="$token"
            gitlab_username="$username"
            gitlab_host="$host"
            gitlab_created_at="$created_at"
            ;;
        *) return 1 ;;
    esac
    _boxa::forge_write_persona "$name" "$kind" "$keys" \
        "$github_token" "$github_username" "$github_created_at" \
        "$gitlab_token" "$gitlab_username" "$gitlab_host" \
        "$gitlab_created_at" "$replace"
}

_boxa::forge_migration_kind() {
    local forge="$1" display_name selected
    local agent='Machine user / service account'
    local mine='My own account'
    local other='Other account'

    case "$forge" in
        github) display_name=GitHub ;;
        gitlab) display_name=GitLab ;;
        *) return 1 ;;
    esac
    selected="$(printf '%s\n' "$agent" "$mine" "$other" \
        | picker::one --prompt "$display_name legacy credential kind:" \
            --header "$display_name credential migration — choose the descriptive owner label."$'\n''Question: Whose account is this?')" \
        || return 1
    case "$selected" in
        "$agent") printf 'agent\n' ;;
        "$mine") printf 'mine\n' ;;
        "$other") printf 'other\n' ;;
        *) return 1 ;;
    esac
}

_boxa::forge_load_legacy_identity() {
    local identity_id="$1" path line key value version=''
    local seen_version='' seen_kind='' seen_auth='' seen_created=''
    local seen_username='' seen_host='' seen_token='' forge expected

    _boxa::forge_validate_legacy_identity_id "$identity_id" || return 1
    path="$(_boxa::forge_identity_store_dir)/$identity_id"
    [ -f "$path" ] || return 1
    _BOXA_FORGE_IDENTITY_KIND=
    _BOXA_FORGE_IDENTITY_AUTH=
    _BOXA_FORGE_CREATED_AT=
    _BOXA_FORGE_USERNAME=
    _BOXA_FORGE_HOST=
    _BOXA_FORGE_TOKEN=
    while IFS= read -r line || [ -n "$line" ]; do
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" != "$line" ] || return 1
        case "$key" in
            version) [ -z "$seen_version" ] || return 1; version="$value"; seen_version=1 ;;
            kind) [ -z "$seen_kind" ] || return 1; _BOXA_FORGE_IDENTITY_KIND="$value"; seen_kind=1 ;;
            auth) [ -z "$seen_auth" ] || return 1; _BOXA_FORGE_IDENTITY_AUTH="$value"; seen_auth=1 ;;
            created_at) [ -z "$seen_created" ] || return 1; _BOXA_FORGE_CREATED_AT="$value"; seen_created=1 ;;
            username) [ -z "$seen_username" ] || return 1; _BOXA_FORGE_USERNAME="$value"; seen_username=1 ;;
            host) [ -z "$seen_host" ] || return 1; _BOXA_FORGE_HOST="$value"; seen_host=1 ;;
            token) [ -z "$seen_token" ] || return 1; _BOXA_FORGE_TOKEN="$value"; seen_token=1 ;;
            *) return 1 ;;
        esac
    done < "$path"
    case "$identity_id" in github:*) forge=github ;; gitlab:*) forge=gitlab ;; esac
    case "$_BOXA_FORGE_IDENTITY_KIND" in mine|agent|other) ;; *) return 1 ;; esac
    case "$_BOXA_FORGE_IDENTITY_AUTH" in ssh|token) ;; *) return 1 ;; esac
    [ "$version" = 1 ] && [ -n "$seen_kind$seen_created$seen_username$seen_host$seen_token" ] \
        && [ -n "$_BOXA_FORGE_TOKEN" ] \
        && [[ "$_BOXA_FORGE_CREATED_AT" =~ ^[0-9]+$ ]] || return 1
    expected="$(_boxa::forge_legacy_identity_id "$forge" "$_BOXA_FORGE_HOST" \
        "$_BOXA_FORGE_USERNAME")" || return 1
    [ "$expected" = "$identity_id" ]
}

_boxa::forge_migration_persona_name() {
    local source="$1" suggested="$2" result_var="$3" chosen

    while true; do
        printf 'Persona name for %s [%s]: ' "$source" "$suggested" >/dev/tty
        IFS= read -r chosen </dev/tty || return 1
        chosen="${chosen:-$suggested}"
        if ! _boxa::forge_validate_persona_name "$chosen"; then
            printf 'Invalid persona name. Use letters, digits, dot, underscore, or hyphen.\n' >/dev/tty
            continue
        fi
        if [ -n "${_BOXA_FORGE_MIGRATION_NAMES[$chosen]:-}" ] \
                || [ -e "$(_boxa::forge_identity_store_dir)/$chosen" ]; then
            printf "Persona '%s' already exists. Choose a different name.\n" \
                "$chosen" >/dev/tty
            continue
        fi
        _BOXA_FORGE_MIGRATION_NAMES["$chosen"]=1
        printf -v "$result_var" '%s' "$chosen"
        return 0
    done
}

_boxa::forge_parse_legacy_conf() {
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local line key value section='' slot

    _BOXA_FORGE_MIGRATION_SECTIONS=()
    _BOXA_FORGE_MIGRATION_CONF=()
    [ -f "$conf" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        if [[ "$line" == \[*\] ]]; then
            value="${line:1:${#line}-2}"
            [[ "$line" == \[*\] && "$value" == /* ]] || return 1
            section="$value"
            _BOXA_FORGE_MIGRATION_SECTIONS+=("$section")
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" != "$line" ] || return 1
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
            forge) case "$value" in on|off) ;; *) return 1 ;; esac ;;
            github|gitlab)
                [ "$value" = none ] \
                    || _boxa::forge_validate_legacy_identity_id "$value" \
                    || return 1
                ;;
            *) return 1 ;;
        esac
        slot="${section:-__global__}"$'\n'"$key"
        [ -z "${_BOXA_FORGE_MIGRATION_CONF[$slot]+x}" ] || return 1
        _BOXA_FORGE_MIGRATION_CONF["$slot"]="$value"
    done < "$conf"
}

_boxa::forge_migration_pick_conflict() {
    local section="$1" github_name="$2" gitlab_name="$3" picked
    local label="Project $section"

    [ "$section" != __global__ ] || label='Global default'
    picked="$(printf '%s\n' "$github_name" "$gitlab_name" \
        | picker::one --prompt 'Choose persona:' \
            --header "$label has different GitHub and GitLab personas."$'\n''Question: Which persona should win?')" \
        || return 1
    case "$picked" in "$github_name"|"$gitlab_name") printf '%s\n' "$picked" ;; *) return 1 ;; esac
}

_boxa::forge_write_migrated_conf() {
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local temp section slot github_id gitlab_id github_name gitlab_name
    local identity gate output_started='' chosen conf_dir
    local -A seen_sections=()
    local -a sections=(__global__ "${_BOXA_FORGE_MIGRATION_SECTIONS[@]}")

    conf_dir="${conf%/*}"
    [ "$conf_dir" != "$conf" ] || conf_dir=.
    mkdir -p "$conf_dir" || return 1
    temp="$(mktemp "${conf}.tmp.XXXXXX")" || return 1
    for section in "${sections[@]}"; do
        [ -z "${seen_sections[$section]:-}" ] || continue
        seen_sections["$section"]=1
        slot="$section"$'\n'
        gate="${_BOXA_FORGE_MIGRATION_CONF[${slot}forge]:-}"
        github_id="${_BOXA_FORGE_MIGRATION_CONF[${slot}github]:-}"
        gitlab_id="${_BOXA_FORGE_MIGRATION_CONF[${slot}gitlab]:-}"
        github_name=''
        gitlab_name=''
        [ -z "$github_id" ] \
            || github_name="${_BOXA_FORGE_MIGRATION_MAP[$github_id]:-}"
        [ -z "$gitlab_id" ] \
            || gitlab_name="${_BOXA_FORGE_MIGRATION_MAP[$gitlab_id]:-}"
        identity="${github_name:-$gitlab_name}"
        if [ "$github_id" = none ] || [ "$gitlab_id" = none ]; then
            identity=none
        elif [ -n "$github_name" ] && [ -n "$gitlab_name" ] \
                && [ "$github_name" != "$gitlab_name" ]; then
            chosen="$(_boxa::forge_migration_pick_conflict "$section" \
                "$github_name" "$gitlab_name")" || { rm -f "$temp"; return 1; }
            identity="$chosen"
        fi
        [ -n "$gate$identity" ] || continue
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        [ "$section" = __global__ ] || printf '[%s]\n' "$section" >> "$temp"
        [ -z "$gate" ] || printf 'forge = %s\n' "$gate" >> "$temp"
        [ -z "$identity" ] || printf 'identity = %s\n' "$identity" >> "$temp"
        output_started=1
    done
    if ! chmod 600 "$temp" || ! mv "$temp" "$conf"; then
        rm -f "$temp"
        return 1
    fi
}

_boxa::forge_migrate_legacy_credentials_locked() {
    local store path identity_id forge pair i j answer name keys source slot
    local github_token github_username github_created gitlab_token
    local gitlab_username gitlab_host gitlab_created kind
    local -a ids=() forges=() kinds=() auths=() created=() usernames=()
    local -a hosts=() tokens=() used=() persona_names=()
    local -a legacy_roots=() legacy_root_ids=() legacy_root_forges=()
    local -a persona_kinds=() persona_keys=() persona_github_tokens=()
    local -a persona_github_usernames=() persona_github_created=()
    local -a persona_gitlab_tokens=() persona_gitlab_usernames=()
    local -a persona_gitlab_hosts=() persona_gitlab_created=()

    _boxa::forge_has_tty || {
        printf "Persona migration needs an interactive terminal. Run 'boxa forge'.\n" >&2
        return 1
    }
    store="$(_boxa::forge_identity_store_dir)"
    for path in "$store"/*:*; do
        [ -e "$path" ] || continue
        identity_id="${path##*/}"
        _boxa::forge_load_legacy_identity "$identity_id" || {
            printf 'Cannot migrate invalid legacy forge identity: %s\n' \
                "$identity_id" >&2
            return 1
        }
        ids+=("$identity_id")
        case "$identity_id" in github:*) forges+=(github) ;; *) forges+=(gitlab) ;; esac
        kinds+=("$_BOXA_FORGE_IDENTITY_KIND")
        auths+=("$_BOXA_FORGE_IDENTITY_AUTH")
        created+=("$_BOXA_FORGE_CREATED_AT")
        usernames+=("$_BOXA_FORGE_USERNAME")
        hosts+=("$_BOXA_FORGE_HOST")
        tokens+=("$_BOXA_FORGE_TOKEN")
        used+=(false)
    done
    for forge in github gitlab; do
        path="$(_boxa::forge_credential_path "$forge")" || return 1
        [ -f "$path" ] || continue
        _boxa::forge_load_credential "$forge" || {
            printf 'Cannot migrate invalid legacy %s credential: %s\n' \
                "$forge" "$path" >&2
            return 1
        }
        if [ -z "$_BOXA_FORGE_USERNAME" ]; then
            _boxa::forge_require_probe_cli "$forge" || return 1
            _BOXA_FORGE_USERNAME="$(_boxa::forge_probe "$forge" \
                "$_BOXA_FORGE_TOKEN" "$_BOXA_FORGE_HOST")" || {
                printf 'Cannot identify the legacy %s credential; leaving it in place.\n' \
                    "$forge" >&2
                return 1
            }
        fi
        identity_id="$(_boxa::forge_legacy_identity_id "$forge" \
            "$_BOXA_FORGE_HOST" "$_BOXA_FORGE_USERNAME")" || return 1
        kind="$(_boxa::forge_migration_kind "$forge")" || return 1
        ids+=("$identity_id"); forges+=("$forge"); kinds+=("$kind")
        auths+=(token); created+=("$_BOXA_FORGE_CREATED_AT")
        usernames+=("$_BOXA_FORGE_USERNAME"); hosts+=("$_BOXA_FORGE_HOST")
        tokens+=("$_BOXA_FORGE_TOKEN"); used+=(false); legacy_roots+=("$path")
        legacy_root_ids+=("$identity_id"); legacy_root_forges+=("$forge")
    done
    [ "${#ids[@]}" -gt 0 ] || return 0
    declare -gA _BOXA_FORGE_MIGRATION_NAMES=()
    declare -gA _BOXA_FORGE_MIGRATION_MAP=()
    declare -gA _BOXA_FORGE_MIGRATION_CONF=()
    declare -ga _BOXA_FORGE_MIGRATION_SECTIONS=()
    _boxa::forge_parse_legacy_conf || {
        printf 'Cannot migrate personas: invalid legacy config: %s\n' \
            "${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}" >&2
        return 1
    }
    for ((i = 0; i < ${#legacy_root_ids[@]}; i++)); do
        slot=__global__$'\n'"${legacy_root_forges[$i]}"
        [ -n "${_BOXA_FORGE_MIGRATION_CONF[$slot]+x}" ] \
            || _BOXA_FORGE_MIGRATION_CONF["$slot"]="${legacy_root_ids[$i]}"
    done
    for ((i = 0; i < ${#ids[@]}; i++)); do
        [ "${used[$i]}" = false ] || continue
        pair=-1
        for ((j = i + 1; j < ${#ids[@]}; j++)); do
            if [ "${used[$j]}" = false ] && [ "${kinds[$j]}" = "${kinds[$i]}" ] \
                    && [ "${forges[$j]}" != "${forges[$i]}" ]; then
                pair=$j
                break
            fi
        done
        if [ "$pair" -ge 0 ]; then
            printf "Merge legacy identities '%s' and '%s' into one persona? [y/N] " \
                "${ids[$i]}" "${ids[$pair]}" >/dev/tty
            IFS= read -r answer </dev/tty || return 1
            case "$answer" in y|Y|yes|YES) ;; *) pair=-1 ;; esac
        fi
        source="${ids[$i]}"
        [ "$pair" -lt 0 ] || source+=" + ${ids[$pair]}"
        _boxa::forge_migration_persona_name "$source" \
            "${usernames[$i]}" name || return 1
        kind="${kinds[$i]}"
        keys=''
        github_token=''; github_username=''; github_created=''
        gitlab_token=''; gitlab_username=''; gitlab_host=''; gitlab_created=''
        for j in "$i" "$pair"; do
            [ "$j" -ge 0 ] || continue
            if [ "${auths[$j]}" = ssh ]; then
                keys="$(_boxa::ssh_agent_key_path)"
            fi
            if [ "${forges[$j]}" = github ]; then
                github_token="${tokens[$j]}"
                github_username="${usernames[$j]}"
                github_created="${created[$j]}"
            else
                gitlab_token="${tokens[$j]}"
                gitlab_username="${usernames[$j]}"
                gitlab_host="${hosts[$j]}"
                gitlab_created="${created[$j]}"
            fi
            used[j]=true
            _BOXA_FORGE_MIGRATION_MAP["${ids[$j]}"]="$name"
        done
        persona_names+=("$name"); persona_kinds+=("$kind"); persona_keys+=("$keys")
        persona_github_tokens+=("$github_token")
        persona_github_usernames+=("$github_username")
        persona_github_created+=("$github_created")
        persona_gitlab_tokens+=("$gitlab_token")
        persona_gitlab_usernames+=("$gitlab_username")
        persona_gitlab_hosts+=("$gitlab_host")
        persona_gitlab_created+=("$gitlab_created")
    done
    for ((i = 0; i < ${#persona_names[@]}; i++)); do
        if ! _boxa::forge_write_persona "${persona_names[$i]}" \
            "${persona_kinds[$i]}" "${persona_keys[$i]}" \
            "${persona_github_tokens[$i]}" "${persona_github_usernames[$i]}" \
            "${persona_github_created[$i]}" "${persona_gitlab_tokens[$i]}" \
            "${persona_gitlab_usernames[$i]}" "${persona_gitlab_hosts[$i]}" \
            "${persona_gitlab_created[$i]}"; then
            for ((j = 0; j < i; j++)); do
                _boxa::forge_remove_persona_files "${persona_names[$j]}"
            done
            return 1
        fi
    done
    if ! _boxa::forge_write_migrated_conf; then
        for name in "${persona_names[@]}"; do
            _boxa::forge_remove_persona_files "$name"
        done
        return 1
    fi
    for identity_id in "${ids[@]}"; do rm -f -- "$store/$identity_id"; done
    for path in "${legacy_roots[@]}"; do rm -f -- "$path"; done
    printf 'Migrated %s legacy forge identity file(s) into %s persona(s).\n' \
        "${#ids[@]}" "${#persona_names[@]}"
}

_boxa::forge_migrate_legacy_credentials() {
    local store path forge

    store="$(_boxa::forge_identity_store_dir)"
    for path in "$store"/*:*; do
        [ -e "$path" ] || continue
        _boxa::forge_with_catalog_lock \
            _boxa::forge_migrate_legacy_credentials_locked
        return
    done
    for forge in github gitlab; do
        path="$(_boxa::forge_credential_path "$forge")" || return 1
        [ -e "$path" ] || continue
        _boxa::forge_with_catalog_lock \
            _boxa::forge_migrate_legacy_credentials_locked
        return
    done
}

_boxa::forge_has_tty() {
    { [ -r /dev/tty ] && : </dev/tty; } 2>/dev/null
}

_boxa::forge_offer_allowlist() {
    local forge="$1" host="$2" entry suggested answer='' domain

    [ "$forge" = github ] && host=github.com
    host="${host%:*}"
    while IFS= read -r entry; do
        entry="${entry#\*.}"
        case "$host" in
            "$entry"|*."$entry") return 0 ;;
        esac
    done < <(allowlist::read "$ALLOWLIST_HOST_FILE")

    if ! _boxa::forge_has_tty; then
        printf 'Forge host is not allowed. Add it manually with: boxa allow %s\n' \
            "$host" >&2
        return 0
    fi

    suggested="$host"
    case "$host" in
        *.*.*) suggested="${host#*.}" ;;
    esac
    printf 'Add %s (and all subdomains) to the durable Allowlist? [y/N] ' \
        "$suggested" >/dev/tty
    IFS= read -r answer </dev/tty || answer=
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            printf 'Allowlist unchanged. Add the forge host manually with: boxa allow %s\n' \
                "$host"
            return 0
            ;;
    esac

    printf 'Confirm or edit the durable domain suffix that should cover this forge host.\n' \
        >/dev/tty
    printf 'Allowlist domain [%s]: ' "$suggested" >/dev/tty
    IFS= read -r domain </dev/tty || domain=
    domain="${domain:-$suggested}"
    if ! _boxa::forge_validate_host "$domain"; then
        printf 'Invalid Allowlist domain. Add the forge host manually with: boxa allow %s\n' \
            "$host" >&2
        return 0
    fi

    if allowlist::add "$ALLOWLIST_HOST_FILE" "$domain"; then
        printf 'Allowed: %s (and all subdomains)\n' "$domain"
    else
        printf 'Already allowed: %s\n' "$domain"
    fi
    if declare -F warn_if_allow_for_active >/dev/null; then
        warn_if_allow_for_active "$domain" allow
    fi
    if declare -F reload_firewall_in_containers >/dev/null; then
        reload_firewall_in_containers allow "$domain"
    fi
}

# Read one simple YAML scalar from the first matching host block. Native forge
# CLIs are preferred; this deliberately narrow fallback rejects YAML features
# it cannot parse safely instead of guessing at credential bytes.
_boxa::forge_yaml_host_value() {
    local path="$1" wanted_host="$2" wanted_key="$3"
    local line indent text host='' key value in_hosts=''

    [ -r "$path" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" != *$'\t'* && "$line" != *$'\r'* ]] || return 1
        indent="${line%%[! ]*}"
        text="${line#"$indent"}"
        [ -n "$text" ] || continue
        [[ "$text" != \#* ]] || continue
        if [ "${#indent}" -eq 0 ]; then
            if [ "$text" = 'hosts:' ]; then
                in_hosts=nested
                host=
            elif [[ "$text" == *: ]]; then
                in_hosts=direct
                host="${text%:}"
                if [[ "$host" == \"*\" ]]; then
                    host="${host#\"}"
                    host="${host%\"}"
                elif [[ "$host" == \'*\' ]]; then
                    host="${host#\'}"
                    host="${host%\'}"
                fi
            else
                in_hosts=
                host=
            fi
            continue
        fi
        [ -n "$in_hosts" ] || continue
        if [ "$in_hosts" = nested ] && [ "${#indent}" -eq 2 ] \
                && [[ "$text" == *: ]]; then
            host="${text%:}"
            if [[ "$host" == \"*\" ]]; then
                host="${host#\"}"
                host="${host%\"}"
            elif [[ "$host" == \'*\' ]]; then
                host="${host#\'}"
                host="${host%\'}"
            fi
            continue
        fi
        if [ "${#indent}" -ne 4 ] || [ -z "$host" ]; then
            continue
        fi
        key="${text%%:*}"
        [ "$key" != "$text" ] || continue
        [ "$key" = "$wanted_key" ] || continue
        [ -z "$wanted_host" ] || [ "$host" = "$wanted_host" ] || continue
        value="${text#*:}"
        value="${value#"${value%%[![:space:]]*}"}"
        case "$value" in
            \"*\")
                [[ "$value" == *\" ]] || return 1
                [[ "$value" != *\\* ]] || return 1
                value="${value#\"}"
                value="${value%\"}"
                ;;
            \'*\')
                [[ "$value" == *\' ]] || return 1
                [[ "$value" != *"''"* ]] || return 1
                value="${value#\'}"
                value="${value%\'}"
                ;;
            *[[:space:]\#]*) return 1 ;;
        esac
        [ -n "$value" ] || return 1
        printf '%s\t%s\n' "$host" "$value"
        return 0
    done < "$path"
    return 1
}

_boxa::forge_existing_credential() {
    local forge="$1" source token='' host='' pair

    _BOXA_FORGE_IMPORT_TOKEN=
    _BOXA_FORGE_IMPORT_HOST=
    _BOXA_FORGE_IMPORT_SOURCE=
    case "$forge" in
        github)
            source="${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml"
            [ -r "$source" ] || return 1
            if command -v gh >/dev/null 2>&1; then
                token="$(GH_CONFIG_DIR="${source%/*}" \
                    gh auth token --hostname github.com 2>/dev/null || true)"
            fi
            if [ -z "$token" ]; then
                pair="$(_boxa::forge_yaml_host_value \
                    "$source" github.com oauth_token 2>/dev/null || true)"
                token="${pair#*$'\t'}"
                [ "$token" != "$pair" ] || token=
            fi
            host=
            ;;
        gitlab)
            source="${GLAB_CONFIG_DIR:-$HOME/.config/glab-cli}/config.yml"
            [ -r "$source" ] || return 1
            if command -v glab >/dev/null 2>&1; then
                host="$(GLAB_CONFIG_DIR="${source%/*}" \
                    glab config get host 2>/dev/null || true)"
                _boxa::forge_validate_host "$host" || host=
                if [ -n "$host" ]; then
                    token="$(GLAB_CONFIG_DIR="${source%/*}" \
                        glab auth token --hostname "$host" 2>/dev/null || true)"
                fi
            fi
            if [ -z "$token" ]; then
                pair="$(_boxa::forge_yaml_host_value \
                    "$source" "$host" token 2>/dev/null || true)"
                if [ "$pair" != "${pair#*$'\t'}" ]; then
                    host="${pair%%$'\t'*}"
                    token="${pair#*$'\t'}"
                fi
            fi
            _boxa::forge_validate_host "$host" || return 1
            ;;
        *) return 1 ;;
    esac
    [ -n "$token" ] && [[ "$token" != *$'\r'* && "$token" != *$'\n'* ]] \
        || return 1
    _BOXA_FORGE_IMPORT_TOKEN="$token"
    _BOXA_FORGE_IMPORT_HOST="$host"
    _BOXA_FORGE_IMPORT_SOURCE="$source"
}

_boxa::forge_adopt_existing_locked() {
    local forge="$1" expected_host="${2:-}" display_name token host source
    local defer_catalog_write="${3:-}"
    local rotation='' answer=''
    local username='' stored_token='' created_at

    case "$forge" in
        github) display_name=GitHub ;;
        gitlab) display_name=GitLab ;;
        *) printf 'Unknown forge: %s (expected github or gitlab)\n' "$forge" >&2; return 1 ;;
    esac
    if ! _boxa::forge_existing_credential "$forge"; then
        printf 'No %s token found in the host CLI config. Use: boxa forge set %s\n' \
            "$display_name" "$forge" >&2
        return 1
    fi
    token="$_BOXA_FORGE_IMPORT_TOKEN"
    host="$_BOXA_FORGE_IMPORT_HOST"
    source="$_BOXA_FORGE_IMPORT_SOURCE"
    if [ -n "$expected_host" ] && [ "$host" != "$expected_host" ]; then
        printf 'Cannot import the GitLab token for %s: this persona setup selected %s. Paste a token for %s instead.\n' \
            "$host" "$expected_host" "$expected_host" >&2
        return 1
    fi
    if _boxa::forge_load_credential "$forge"; then
        stored_token="$_BOXA_FORGE_TOKEN"
    fi
    if [ "$stored_token" = "$token" ]; then
        return 0
    fi
    [ -z "$stored_token" ] || rotation=1

    if ! _boxa::forge_has_tty; then
        printf 'Skipped %s token from %s: no interactive terminal.\n' \
            "$display_name" "$source" >&2
        printf 'Set it safely with: boxa forge set %s\n' "$forge" >&2
        return 0
    fi
    _boxa::forge_require_probe_cli "$forge" || return 1
    if [ -n "$rotation" ]; then
        printf 'Stored %s token differs — update from %s? [y/N] ' \
            "$display_name" "$source" >/dev/tty
    else
        printf 'Take over the %s token from %s into the host-only forge store? [y/N] ' \
            "$display_name" "$source" >/dev/tty
    fi
    IFS= read -r answer </dev/tty || answer=
    case "$answer" in
        y|Y|yes|YES) ;;
        *) printf '%s token import skipped.\n' "$display_name"; return 1 ;;
    esac

    created_at="$(date +%s)"
    username="$(_boxa::forge_probe "$forge" "$token" "$host" || true)"
    _boxa::forge_write_credential "$forge" "$token" "$username" "$host" \
        "$created_at" || return 1
    printf '%s token imported from %s.\n' "$display_name" "$source"
    if [ -n "$username" ]; then
        printf 'Authenticated as: %s\n' "$username"
        if [ -z "$defer_catalog_write" ]; then
            _boxa::forge_migrate_legacy_credentials_locked || return 1
        fi
    else
        printf 'WARNING: Could not verify the imported %s token; the stored credential was kept.\n' \
            "$display_name" >&2
    fi
}

_boxa::forge_adopt_existing() {
    _boxa::forge_with_catalog_lock _boxa::forge_adopt_existing_locked "$@"
}

_boxa::forge_step() {
    local title="$1" url="$2" guidance="$3" context="${4:-Forge checklist}"
    local selected
    local done='Done — continue' skip='Skip this step'

    printf '\n%s\nURL: %s\n%s\n' "$title" "$url" "$guidance"
    selected="$(printf '%s\n' "$done" "$skip" \
        | picker::one --prompt 'Checklist step:' \
            --header "$context: $title"$'\n'"$guidance"$'\n''Question: Is this step complete?')" \
        || return 1
    if [ "$selected" = "$skip" ]; then
        _boxa::forge_checklist_add_skipped "$title"
    fi
    [ "$selected" = "$done" ]
}

_boxa::forge_checklist_add_skipped() {
    local item="$1"

    case ";${_BOXA_FORGE_CHECKLIST_SKIPPED:-};" in
        *";$item;"*) return 0 ;;
    esac
    if [ -n "${_BOXA_FORGE_CHECKLIST_SKIPPED:-}" ]; then
        _BOXA_FORGE_CHECKLIST_SKIPPED+="; $item"
    else
        _BOXA_FORGE_CHECKLIST_SKIPPED="$item"
    fi
}

_boxa::forge_checklist_intro() {
    local display_name="$1" account="$2" cli="$3" auth="${4:-ssh}"
    local review

    printf '\n%s %s checklist\n' "$display_name" "$account"
    case "$display_name" in
        GitHub) review='pull requests' ;;
        GitLab) review='merge requests' ;;
    esac
    if [ "$auth" = token ]; then
        printf 'This checklist configures a token for %s CLI, API access, %s, and committer identity; no SSH git transport is attached.\n' \
            "$cli" "$review"
    else
        printf 'This checklist configures SSH for git push/pull and a token for %s CLI, API access, %s, and committer identity.\n' \
            "$cli" "$review"
    fi
}

_boxa::forge_checklist_summary() {
    local forge="$1" host="$2" kind="$3" auth="$4"
    local ssh_username="$5" token_username="$6"
    local display_name cli review identity_id='not available'
    local works=''

    case "$forge" in
        github) display_name=GitHub; cli=gh; review='pull requests' ;;
        gitlab) display_name=GitLab; cli=glab; review='merge requests' ;;
    esac
    if [ -n "$token_username" ]; then
        identity_id="$(_boxa::forge_identity_id "$forge" "$host" \
            "$token_username" || printf 'not available')"
    fi
    if [ "$auth" = ssh ]; then
        if [ -n "$ssh_username" ]; then
            works='SSH push/pull'
        else
            _boxa::forge_checklist_add_skipped 'SSH verification'
        fi
    fi
    if [ -n "$token_username" ]; then
        [ -z "$works" ] || works+='; '
        works+="$cli CLI, API access, $review, and committer identity"
    else
        _boxa::forge_checklist_add_skipped 'token setup or verification'
    fi
    [ -n "$works" ] || works='no forge access was verified'

    printf '\n%s checklist summary\n' "$display_name"
    printf 'Persona name: %s\nKind: %s\n' "$identity_id" "$kind"
    printf 'Works now: %s.\n' "$works"
    printf 'Skipped: %s.\n' "${_BOXA_FORGE_CHECKLIST_SKIPPED:-none}"
}

_boxa::forge_ssh_probe() {
    local host="$1" hostname="$1" port='' key_path output socket
    local -a port_args=()

    if [[ "$host" == *:* ]]; then
        hostname="${host%:*}"
        port="${host##*:}"
        port_args=(-p "$port")
    fi

    _boxa::ssh_ensure_agent_identity_agent || return 1
    socket="$(_boxa::ssh_agent_socket_path)"
    key_path="$(_boxa::ssh_agent_key_path)"
    output="$(SSH_AUTH_SOCK="$socket" ssh -T -o BatchMode=yes \
        -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes -i "$key_path.pub" \
        "${port_args[@]}" "git@$hostname" 2>&1 || true)"
    case "$host:$output" in
        github.com:*successfully\ authenticated*) ;;
        *:*[Ww]elcome*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$output"
}

_boxa::forge_ssh_probe_username() {
    local host="$1" output line pattern

    output="$(_boxa::forge_ssh_probe "$host")" || return 1
    case "$host" in
        github.com)
            pattern='^Hi[[:space:]]+([^!]+)!'
            ;;
        *)
            pattern='^Welcome[[:space:]]+to[[:space:]]+GitLab,[[:space:]]+@([^!]+)!'
            ;;
    esac
    while IFS= read -r line; do
        if [[ "$line" =~ $pattern ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <<< "$output"
    return 1
}

_boxa::forge_ssh_probe_key() {
    local host="$1" key_path="$2" hostname="$1" port='' output
    local -a port_args=()

    if [[ "$host" == *:* ]]; then
        hostname="${host%:*}"
        port="${host##*:}"
        port_args=(-p "$port")
    fi
    [ -f "$key_path" ] && [ -f "$key_path.pub" ] || return 1
    output="$(SSH_AUTH_SOCK=none ssh -T -o BatchMode=yes \
        -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes -o IdentityAgent=none -i "$key_path" \
        "${port_args[@]}" "git@$hostname" 2>&1 || true)"
    case "$host:$output" in
        github.com:*successfully\ authenticated*) ;;
        *:*[Ww]elcome*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$output"
}

_boxa::forge_ssh_probe_key_username() {
    local host="$1" key_path="$2" output line pattern

    output="$(_boxa::forge_ssh_probe_key "$host" "$key_path")" || return 1
    case "$host" in
        github.com) pattern='^Hi[[:space:]]+([^!]+)!' ;;
        *)
            pattern='^Welcome[[:space:]]+to[[:space:]]+GitLab,[[:space:]]+@([^!]+)!'
            ;;
    esac
    while IFS= read -r line; do
        if [[ "$line" =~ $pattern ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <<< "$output"
    return 1
}

_boxa::forge_verify_ssh_loop() {
    local host="$1" result_var="${2:-}" key_path="${3:-}"
    local selected verified_username verification_key
    local retry='Retry verification' skip='Skip verification'

    _BOXA_FORGE_SSH_VERIFICATION_SKIPPED=
    [ -z "$result_var" ] || printf -v "$result_var" '%s' ''
    while :; do
        verification_key="$key_path"
        [ -n "$verification_key" ] \
            || verification_key="$(_boxa::ssh_agent_key_path)"
        if [ ! -f "$verification_key.pub" ]; then
            printf 'SSH verification cannot identify this key because its public key is missing: %s.pub\n' \
                "$verification_key" >&2
            _boxa::forge_missing_public_key_guidance "$verification_key" >&2
            verified_username=''
        elif [ -n "$key_path" ]; then
            verified_username="$(_boxa::forge_ssh_probe_key_username \
                "$host" "$key_path")" || verified_username=''
        else
            verified_username="$(_boxa::forge_ssh_probe_username "$host")" \
                || verified_username=''
        fi
        if [ -n "$verified_username" ]; then
            [ -z "$result_var" ] \
                || printf -v "$result_var" '%s' "$verified_username"
            printf 'Authenticated via SSH as: %s\n' "$verified_username"
            return 0
        fi
        printf 'SSH verification failed. Confirm the Agent public key is attached, the host key is trusted, and the host is reachable.\n' >&2
        selected="$(printf '%s\n' "$retry" "$skip" \
            | picker::one --prompt 'SSH verification:' \
                --header "Forge persona setup — SSH authentication to $host failed."$'\n''Question: Retry or skip SSH verification?')" \
            || return 0
        if [ "$selected" != "$retry" ]; then
            _boxa::forge_checklist_add_skipped 'SSH verification'
            _BOXA_FORGE_SSH_VERIFICATION_SKIPPED=1
            return 0
        fi
    done
}

_boxa::forge_verify_token_loop() {
    local forge="$1" host="$2" result_var="${3:-}" required="${4:-}"
    local display_name selected
    local username created_at token
    local retry='Retry verification' replace='Paste another token' skip='Skip verification'

    case "$forge" in github) display_name=GitHub ;; gitlab) display_name=GitLab ;; esac
    [ -z "$result_var" ] || printf -v "$result_var" '%s' ''
    _boxa::forge_require_probe_cli "$forge" || return 1
    while :; do
        if _boxa::forge_load_credential "$forge"; then
            token="$_BOXA_FORGE_TOKEN"
            created_at="$_BOXA_FORGE_CREATED_AT"
            [ "$forge" != gitlab ] || host="$_BOXA_FORGE_HOST"
            if username="$(_boxa::forge_probe "$forge" "$token" "$host")"; then
                _boxa::forge_write_credential "$forge" "$token" "$username" \
                    "$host" "$created_at" || return 1
                [ -z "$result_var" ] \
                    || printf -v "$result_var" '%s' "$username"
                printf 'Authenticated as: %s\n' "$username"
                _boxa::forge_offer_allowlist "$forge" "$host"
                return 0
            fi
        fi
        printf '%s token verification failed. Check the token scope, expiry, host, and network access.\n' \
            "$display_name" >&2
        if [ "$required" = required ]; then
            selected="$(printf '%s\n' "$retry" "$replace" \
                | picker::one --prompt 'Token verification:' \
                    --header "$display_name persona setup — a verified token is mandatory for CLI and API operations."$'\n''Question: Retry verification or paste another token?')" \
                || return 1
        else
            selected="$(printf '%s\n' "$retry" "$replace" "$skip" \
                | picker::one --prompt 'Token verification:' \
                    --header "$display_name checklist — token verification failed."$'\n''Question: Retry, replace, or skip token verification?')" \
                || return 0
        fi
        case "$selected" in
            "$retry") ;;
            "$replace")
                if ! _boxa::forge_set "$forge" skip "$host"; then
                    [ "$required" != required ] || return 1
                fi
                ;;
            *) _boxa::forge_checklist_add_skipped 'token verification'; return 0 ;;
        esac
    done
}

_boxa::forge_token_choice() {
    local forge="$1" host="$2" preference="${3:-paste}"
    local result_var="${4:-}" display_name selected verified_username=''
    local context="${5:-}" required="${6:-}" guidance="${7:-}" header
    local paste adopt skip='Skip token setup'

    if [ "$preference" = adopt ]; then
        paste='Paste a new token'
        adopt='Import the host CLI token (recommended)'
    else
        paste='Paste a new token (recommended)'
        adopt='Import the host CLI token'
    fi

    [ -z "$result_var" ] || printf -v "$result_var" '%s' ''
    case "$forge" in github) display_name=GitHub ;; gitlab) display_name=GitLab ;; esac
    context="${context:-$display_name checklist — token setup}"
    if [ "$required" = required ]; then
        header="$context — the token is mandatory for the CLI, API, review requests, and committer identity; SSH keys only provide git transport."$'\n''Question: How should Boxa obtain the required token?'
        [ -z "$guidance" ] || header="$guidance"$'\n'"$header"
        selected="$(printf '%s\n' "$paste" "$adopt" \
            | picker::one --prompt "$display_name token:" \
                --header "$header")" \
            || return 1
    else
        header="$context — the SSH key only covers git push/pull; the token enables the CLI, API, review requests, and committer identity."$'\n''Question: How should Boxa obtain the token?'
        [ -z "$guidance" ] || header="$guidance"$'\n'"$header"
        selected="$(printf '%s\n' "$paste" "$adopt" "$skip" \
            | picker::one --prompt "$display_name token:" \
                --header "$header")" \
            || return 0
    fi
    case "$selected" in
        "$paste")
            if ! _boxa::forge_set "$forge" skip "$host"; then
                printf '%s token entry failed or was cancelled; existing credential was not verified.\n' \
                    "$display_name" >&2
                [ "$required" != required ] || return 1
                return 0
            fi
            ;;
        "$adopt")
            _boxa::forge_adopt_existing "$forge" "$host" defer-catalog \
                || { [ "$required" != required ] || return 1; return 0; }
            ;;
        *)
            _boxa::forge_checklist_add_skipped 'token setup'
            [ "$required" != required ] || return 1
            return 0
            ;;
    esac
    if ! _boxa::forge_load_credential "$forge" >/dev/null 2>&1; then
        [ "$required" != required ] || return 1
        return 0
    fi
    _boxa::forge_verify_token_loop "$forge" "$host" verified_username \
        "$required" || return 1
    [ -z "$result_var" ] \
        || printf -v "$result_var" '%s' "$verified_username"
}

_boxa::forge_warn_identity_mismatch() {
    local ssh_username="$1" token_username="$2"

    [ -n "$ssh_username" ] && [ -n "$token_username" ] \
        && [ "$ssh_username" != "$token_username" ] || return 0
    printf 'WARNING: SSH authenticates as %s, but the API token authenticates as %s. SSH pushes and API operations will act as different accounts.\n' \
        "$ssh_username" "$token_username" >&2
}

_boxa::forge_warn_entered_username_mismatch() {
    local entered_username="$1" verified_username="$2"

    [ -n "$entered_username" ] && [ -n "$verified_username" ] \
        && [ "$entered_username" != "$verified_username" ] || return 0
    printf 'WARNING: Entered username %s, but verification authenticated as %s. The verified account username will be stored for this persona.\n' \
        "$entered_username" "$verified_username" >&2
}

_boxa::forge_github_private_repository_guidance() {
    printf '\nGitHub machine-user guidance (information only; Boxa changes no forge-side state):\n'
    printf '%s\n' \
        '- Keep private repositories out of the machine user collaborator list unless they are required.' \
        '- For private repositories, use GitHub Pro and protect the default branch before inviting the machine user.' \
        '- A read-only deploy key can provide git-only access to one repository; API and pull-request access still require the token.'
}

_boxa::forge_agent_account_url() {
    case "$1" in
        github) printf 'https://github.com/signup\n' ;;
        gitlab) printf 'https://docs.gitlab.com/user/profile/service_accounts/\n' ;;
    esac
}

_boxa::forge_token_mint_url() {
    case "$1" in
        github)
            printf 'https://github.com/settings/tokens/new?scopes=repo&description=Boxa%%20Agent\n'
            ;;
        gitlab)
            printf 'https://%s/-/user_settings/personal_access_tokens\n' "$2"
            ;;
    esac
}

_boxa::forge_token_mint_instructions() {
    case "$1" in
        github)
            printf '%s\n' 'The SSH key only covers git push/pull; select the repo scope and a 1-year expiration so gh CLI, API access, pull requests, and committer identity work.'
            ;;
        gitlab)
            printf '%s\n' 'The SSH key only covers git push/pull; select the api scope and a 1-year expiration so glab CLI, API access, merge requests, and committer identity work.'
            ;;
    esac
}

_boxa::forge_token_mint_guidance() {
    local forge="$1" host="$2" kind="$3" display_name token_name

    case "$forge" in
        github) display_name=GitHub; token_name='classic personal access token' ;;
        gitlab) display_name=GitLab; token_name='personal access token' ;;
    esac
    printf 'Mint the %s %s here: %s\n' "$display_name" "$token_name" \
        "$(_boxa::forge_token_mint_url "$forge" "$host")"
    _boxa::forge_token_mint_instructions "$forge"
    if [ "$kind" = agent ]; then
        printf 'For an agent persona, the token must belong to the separate automation account: %s\n' \
            "$(_boxa::forge_agent_account_url "$forge")"
        printf 'Import the host CLI token only when the host CLI is logged in as that account.\n'
    fi
}

_boxa::forge_read_paths() {
    local prompt="$1" value

    printf 'List only repositories or projects where this forge account should receive access; leave blank to skip grants.\n' \
        >/dev/tty
    printf '%s (space-separated OWNER/REPO or GROUP/PROJECT; blank skips): ' \
        "$prompt" >/dev/tty
    IFS= read -r value </dev/tty || value=
    printf '%s\n' "$value"
}

_boxa::forge_checklist_github_own_account() {
    local ssh_result_var="${1:-}" token_result_var="${2:-}" kind="${3:-mine}"
    local verified_ssh_username='' verified_token_username=''
    local _BOXA_FORGE_CHECKLIST_SKIPPED=''

    _boxa::forge_checklist_intro GitHub own-account gh
    _boxa::forge_step '1. Add the Boxa Agent public key to your GitHub account.' \
        'https://github.com/settings/ssh/new' \
        "Select Authentication Key and paste $(_boxa::ssh_agent_key_path).pub." \
        'GitHub own-account checklist — step 1/2' || true
    _boxa::forge_verify_ssh_loop github.com verified_ssh_username
    _boxa::forge_token_choice github '' adopt verified_token_username \
        'GitHub own-account checklist — step 2/2: configure API token'
    _boxa::forge_warn_identity_mismatch "$verified_ssh_username" \
        "$verified_token_username"
    [ -z "$ssh_result_var" ] \
        || printf -v "$ssh_result_var" '%s' "$verified_ssh_username"
    [ -z "$token_result_var" ] \
        || printf -v "$token_result_var" '%s' "$verified_token_username"
    _boxa::forge_checklist_summary github '' "$kind" ssh \
        "$verified_ssh_username" "$verified_token_username"
}

_boxa::forge_checklist_github_machine_user() {
    local account_action="${1:-create}" ssh_result_var="${2:-}"
    local token_result_var="${3:-}" kind="${4:-agent}" repos repo
    local verified_ssh_username='' verified_token_username=''
    local _BOXA_FORGE_CHECKLIST_SKIPPED=''

    _boxa::forge_checklist_intro GitHub machine-user gh
    if [ "$account_action" != existing ]; then
        _boxa::forge_step '1. Create a GitHub machine user.' \
            "$(_boxa::forge_agent_account_url github)" \
            'Use a separate automation-only account with its own valid email.' \
            'GitHub machine-user checklist — step 1/5' || true
    fi
    _boxa::forge_step '2. Add the Boxa Agent public key to the machine user.' \
        'https://github.com/settings/ssh/new' \
        "Select Authentication Key and paste $(_boxa::ssh_agent_key_path).pub." \
        'GitHub machine-user checklist — step 2/5' || true
    _boxa::forge_verify_ssh_loop github.com verified_ssh_username

    printf '\nPublic-repository nudge: add a branch ruleset that protects the default branch from direct collaborator pushes.\n'
    repos="$(_boxa::forge_read_paths 'Repositories to invite')"
    for repo in $repos; do
        if [[ "$repo" != */* || "$repo" == *[!A-Za-z0-9._/-]* ]]; then
            printf 'Skipping invalid GitHub repository path: %s\n' "$repo" >&2
            continue
        fi
        _boxa::forge_step "3. Invite the machine user to $repo." \
            "https://github.com/$repo/settings/access" \
            'Add the machine user as a collaborator.' \
            'GitHub machine-user checklist — step 3/5' || true
        _boxa::forge_step "4. Add a public-repository branch ruleset for $repo if applicable." \
            "https://github.com/$repo/settings/rules/new?target=branch" \
            'Protect the default branch from direct pushes by collaborators.' \
            'GitHub machine-user checklist — step 4/5' || true
    done
    _boxa::forge_github_private_repository_guidance
    _boxa::forge_step '5. Mint a classic personal access token.' \
        "$(_boxa::forge_token_mint_url github '')" \
        "$(_boxa::forge_token_mint_instructions github)" \
        'GitHub machine-user checklist — step 5/5' || true
    _boxa::forge_token_choice github '' paste verified_token_username \
        'GitHub machine-user checklist — step 5/5: configure the minted PAT'
    _boxa::forge_warn_identity_mismatch "$verified_ssh_username" \
        "$verified_token_username"
    [ -z "$ssh_result_var" ] \
        || printf -v "$ssh_result_var" '%s' "$verified_ssh_username"
    [ -z "$token_result_var" ] \
        || printf -v "$token_result_var" '%s' "$verified_token_username"
    _boxa::forge_checklist_summary github '' "$kind" ssh \
        "$verified_ssh_username" "$verified_token_username"
}

_boxa::forge_checklist_github_pat_only() {
    local token_result_var="${1:-}" kind="${2:-mine}"
    local verified_token_username='' _BOXA_FORGE_CHECKLIST_SKIPPED=''

    _boxa::forge_checklist_intro GitHub fine-grained-PAT gh token
    _boxa::forge_step '1. Mint a fine-grained personal access token.' \
        'https://github.com/settings/personal-access-tokens/new' \
        'Select only the repositories the agent needs, grant Contents and Pull requests read/write, and set a 1-year expiration for git, gh CLI, API access, pull requests, and committer identity.' \
        'GitHub fine-grained-PAT checklist — step 1/1' || true
    if ! _boxa::forge_set github skip ''; then
        printf 'GitHub token entry failed or was cancelled; checklist not completed.\n' >&2
        return 1
    fi
    _boxa::forge_verify_token_loop github '' verified_token_username
    [ -z "$token_result_var" ] \
        || printf -v "$token_result_var" '%s' "$verified_token_username"
    printf 'HTTPS remotes are required in this mode; gh honors GH_TOKEN.\n'
    _boxa::forge_checklist_summary github '' "$kind" token '' \
        "$verified_token_username"
}

_boxa::forge_checklist_github() {
    _boxa::forge_add github
}

_boxa::forge_read_gitlab_host() {
    local host

    printf 'Choose the GitLab instance whose SSH transport and glab/API token access will be configured.\n' \
        >/dev/tty
    printf 'GitLab host [gitlab.com]: ' >/dev/tty
    IFS= read -r host </dev/tty || return 1
    host="${host:-gitlab.com}"
    _boxa::forge_validate_host "$host" || { printf 'Invalid GitLab host.\n' >&2; return 1; }
    printf '%s\n' "$host"
}

_boxa::forge_checklist_gitlab_own_account() {
    local host="$1" ssh_result_var="${2:-}" token_result_var="${3:-}"
    local base="https://$1" verified_ssh_username=''
    local verified_token_username='' kind="${4:-mine}"
    local _BOXA_FORGE_CHECKLIST_SKIPPED=''

    _boxa::forge_checklist_intro GitLab own-account glab
    _boxa::forge_step '1. Add the Boxa Agent public key to your GitLab account.' \
        "$base/-/user_settings/ssh_keys" \
        "Add $(_boxa::ssh_agent_key_path).pub to your own account." \
        'GitLab own-account checklist — step 1/2' || true
    _boxa::forge_verify_ssh_loop "$host" verified_ssh_username
    _boxa::forge_token_choice gitlab "$host" adopt verified_token_username \
        'GitLab own-account checklist — step 2/2: configure API token'
    _boxa::forge_warn_identity_mismatch "$verified_ssh_username" \
        "$verified_token_username"
    [ -z "$ssh_result_var" ] \
        || printf -v "$ssh_result_var" '%s' "$verified_ssh_username"
    [ -z "$token_result_var" ] \
        || printf -v "$token_result_var" '%s' "$verified_token_username"
    _boxa::forge_checklist_summary gitlab "$host" "$kind" ssh \
        "$verified_ssh_username" "$verified_token_username"
}

_boxa::forge_checklist_gitlab_service_account() {
    local host="$1" account_action="${2:-create}"
    local ssh_result_var="${3:-}" token_result_var="${4:-}"
    local projects project base verified_ssh_username=''
    local verified_token_username='' kind="${5:-agent}"
    local _BOXA_FORGE_CHECKLIST_SKIPPED=''

    base="https://$host"
    _boxa::forge_checklist_intro GitLab service-account glab
    if [ "$account_action" != existing ]; then
        _boxa::forge_step '1. Create an instance service account.' \
            "$(_boxa::forge_agent_account_url gitlab)" \
            "On $host 18.11 or newer, an administrator creates the instance service account. On older CE, create a plain automation-only user instead." \
            'GitLab service-account checklist — step 1/5' || true
    fi
    _boxa::forge_step '2. Add the Boxa Agent public key.' \
        "$base/-/user_settings/ssh_keys" \
        "Add $(_boxa::ssh_agent_key_path).pub to the service account or fallback user." \
        'GitLab service-account checklist — step 2/5' || true
    _boxa::forge_verify_ssh_loop "$host" verified_ssh_username

    printf '\nProtection nudge: protected-branch push access should be Maintainers, and protected tag pattern v* should block Developer release tags.\n'
    projects="$(_boxa::forge_read_paths 'Projects to grant')"
    for project in $projects; do
        if [[ "$project" != */* || "$project" == *[!A-Za-z0-9._/-]* ]]; then
            printf 'Skipping invalid GitLab project path: %s\n' "$project" >&2
            continue
        fi
        _boxa::forge_step "3. Grant Developer access on $project." \
            "$base/$project/-/project_members" \
            'Add the service account with the Developer role.' \
            'GitLab service-account checklist — step 3/5' || true
        _boxa::forge_step "4. Protect branches and tags on $project." \
            "$base/$project/-/settings/repository" \
            'Set protected-branch push access to Maintainers and protect tag pattern v*.' \
            'GitLab service-account checklist — step 4/5' || true
    done
    _boxa::forge_step '5. Mint a personal access token.' \
        "$(_boxa::forge_token_mint_url gitlab "$host")" \
        "$(_boxa::forge_token_mint_instructions gitlab)" \
        'GitLab service-account checklist — step 5/5' || true
    _boxa::forge_token_choice gitlab "$host" paste verified_token_username \
        'GitLab service-account checklist — step 5/5: configure the minted PAT'
    _boxa::forge_warn_identity_mismatch "$verified_ssh_username" \
        "$verified_token_username"
    [ -z "$ssh_result_var" ] \
        || printf -v "$ssh_result_var" '%s' "$verified_ssh_username"
    [ -z "$token_result_var" ] \
        || printf -v "$token_result_var" '%s' "$verified_token_username"
    _boxa::forge_checklist_summary gitlab "$host" "$kind" ssh \
        "$verified_ssh_username" "$verified_token_username"
}

_boxa::forge_checklist_gitlab_pat_only() {
    local host="$1" token_result_var="${2:-}" base="https://$1"
    local verified_token_username='' kind="${3:-mine}"
    local _BOXA_FORGE_CHECKLIST_SKIPPED=''

    _boxa::forge_checklist_intro GitLab personal-PAT glab token
    _boxa::forge_step '1. Mint a personal access token for your GitLab account.' \
        "$base/-/user_settings/personal_access_tokens" \
        "A personal PAT acts with your account's full reach for granted scopes. For project-scoped access, use a project or group access token. Set a 1-year expiration for git, glab CLI, API access, merge requests, and committer identity." \
        'GitLab personal-PAT checklist — step 1/1' || true
    if ! _boxa::forge_set gitlab skip "$host"; then
        printf 'GitLab token entry failed or was cancelled; checklist not completed.\n' >&2
        return 1
    fi
    _boxa::forge_verify_token_loop gitlab "$host" verified_token_username
    [ -z "$token_result_var" ] \
        || printf -v "$token_result_var" '%s' "$verified_token_username"
    printf 'HTTPS remotes are required in this mode; glab honors GITLAB_TOKEN.\n'
    _boxa::forge_checklist_summary gitlab "$host" "$kind" token '' \
        "$verified_token_username"
}

_boxa::forge_checklist_gitlab() {
    _boxa::forge_add gitlab
}

_boxa::forge_checklist() {
    case "$1" in
        github) _boxa::forge_checklist_github ;;
        gitlab) _boxa::forge_checklist_gitlab ;;
        *) printf 'Unknown forge: %s (expected github or gitlab)\n' "$1" >&2; return 1 ;;
    esac
}

_boxa::forge_add_forge() {
    local selected
    local github='GitHub' gitlab='GitLab'

    selected="$(printf '%s\n' "$github" "$gitlab" \
        | picker::one --prompt 'Forge:' \
            --header 'Persona setup — choose the service to configure.'$'\n''Question: Which forge should Boxa configure?')" \
        || return 1
    case "$selected" in
        "$github") printf 'github\n' ;;
        "$gitlab") printf 'gitlab\n' ;;
        *) return 1 ;;
    esac
}

_boxa::forge_add_name() {
    local name path

    printf 'Choose a short persona name for this credential bundle (for example: agent, milos, or work).\n' \
        >/dev/tty
    printf 'Persona name: ' >/dev/tty
    IFS= read -r name </dev/tty || return 1
    if ! _boxa::forge_validate_persona_name "$name"; then
        printf 'Invalid persona name. Use letters, numbers, dots, underscores, or hyphens.\n' \
            >&2
        return 1
    fi
    path="$(_boxa::forge_identity_path "$name")" || return 1
    if [ -e "$path" ]; then
        printf "Persona '%s' already exists. Choose a different name.\n" "$name" >&2
        return 1
    fi
    printf '%s\n' "$name"
}

_boxa::forge_add_kind() {
    local selected
    local agent='Machine user / service account'
    local mine='My own account'
    local other='Other account'

    selected="$(printf '%s\n' "$agent" "$mine" "$other" \
        | picker::one --prompt 'Persona kind:' \
            --header 'Persona setup — this is a descriptive label only; every kind follows the same credential flow.'$'\n''Question: Whose account is this?')" \
        || return 1
    case "$selected" in
        "$agent") printf 'agent\n' ;;
        "$mine") printf 'mine\n' ;;
        "$other") printf 'other\n' ;;
        *) return 1 ;;
    esac
}

_boxa::forge_add_account_action() {
    local forge="$1" display_name selected
    local existing='Attach the selected SSH keys to an existing account'
    local create='Create a new machine user / service account'

    case "$forge" in github) display_name=GitHub ;; gitlab) display_name=GitLab ;; esac
    selected="$(printf '%s\n' "$existing" "$create" \
        | picker::one --prompt "$display_name account:" \
            --header "$display_name persona setup — attach the selected SSH keys to an account."$'\n''Question: Use an existing account or create one?')" \
        || return 1
    case "$selected" in
        "$existing") printf 'existing\n' ;;
        "$create") printf 'create\n' ;;
        *) return 1 ;;
    esac
}

_boxa::forge_add_expected_username() {
    local username

    printf 'This optional hint lets Boxa warn if SSH or token verification authenticates as a different account; the chosen persona name is unchanged.\n' \
        >/dev/tty
    printf 'Expected account username (optional; verification is authoritative): ' \
        >/dev/tty
    IFS= read -r username </dev/tty || return 1
    printf '%s\n' "$username"
}

_boxa::forge_add_ssh_choice() {
    local forge="$1" kind="$2" display_name selected
    local all='Attach all host SSH keys (~/.ssh)'
    local choose='Choose which host keys to attach'
    local existing='Attach existing SSH keys'
    local agent="Attach Boxa's generated agent key (agent-identity)"
    local without='Finish without an SSH key'

    case "$forge" in github) display_name=GitHub ;; gitlab) display_name=GitLab ;; esac
    if [ "$kind" = mine ]; then
        selected="$(printf '%s\n' "$all" "$choose" "$without" \
            | picker::one --prompt "$display_name SSH key:" \
                --header "$display_name persona setup — the verified token covers CLI and API operations; an SSH key adds git transport."$'\n''Question: Attach an SSH key now?')" \
            || return 1
    else
        selected="$(printf '%s\n' "$agent" "$without" "$existing" \
            | picker::one --prompt "$display_name SSH key:" \
                --header "$display_name persona setup — the verified token covers CLI and API operations; an SSH key adds git transport."$'\n''Question: Attach an SSH key now?')" \
            || return 1
    fi
    case "$selected" in
        "$all") printf 'all\n' ;;
        "$choose") printf 'existing\n' ;;
        "$existing") printf 'existing\n' ;;
        "$agent") printf 'agent\n' ;;
        "$without") printf 'without\n' ;;
        *) return 1 ;;
    esac
}

_boxa::forge_add_account_guidance() {
    local forge="$1" account_action="$2" host="$3" kind="$4" keys="$5"
    local key_path
    case "$forge:$account_action" in
        github:create)
            printf '\nCreate a separate automation-only GitHub account with its own valid email: %s\n' \
                "$(_boxa::forge_agent_account_url github)"
            ;;
        github:existing)
            printf '\nUse the existing GitHub account for this persona; each machine should attach its own key and mint its own revocable token.\n'
            ;;
        gitlab:create)
            printf '\nCreate a GitLab service account or a plain automation-only user, depending on what %s supports: %s\n' \
                "$host" "$(_boxa::forge_agent_account_url gitlab)"
            ;;
        gitlab:existing)
            printf '\nUse the existing GitLab account for this persona; each machine should attach its own key and mint its own revocable token.\n'
            ;;
    esac
    while IFS= read -r key_path; do
        [ -n "$key_path" ] || continue
        if [ -f "$key_path.pub" ]; then
            printf 'Add %s.pub as an authentication key. SSH provides git transport; the already verified token remains mandatory for CLI and API operations.\n' \
                "$key_path"
        else
            printf 'The public key to upload is missing: %s.pub\n' "$key_path"
            _boxa::forge_missing_public_key_guidance "$key_path"
        fi
    done <<< "$keys"
    [ "$forge" != github ] || [ "$kind" = mine ] \
        || _boxa::forge_github_private_repository_guidance
}

_boxa::forge_register_verified_identity() {
    local name="$1" forge="$2" kind="$3" keys="$4"
    local expected_username="$5" token_username="$6" result_var="${7:-}"
    local credential_path token username host created_at auth=token

    _boxa::forge_warn_entered_username_mismatch "$expected_username" \
        "$token_username"
    if [ -z "$token_username" ] \
            || ! _boxa::forge_load_credential "$forge" \
            || [ "$_BOXA_FORGE_USERNAME" != "$token_username" ]; then
        printf 'Persona was not registered because token verification did not complete.\n' \
            >&2
        return 1
    fi
    token="$_BOXA_FORGE_TOKEN"
    username="$_BOXA_FORGE_USERNAME"
    host="$_BOXA_FORGE_HOST"
    created_at="$_BOXA_FORGE_CREATED_AT"
    [ -z "$keys" ] || auth=ssh
    _boxa::forge_write_identity "$forge" "$kind" "$token" "$username" \
        "$host" "$created_at" "$auth" "$name" "$keys" || return 1
    credential_path="$(_boxa::forge_credential_path "$forge")" || return 1
    rm -f -- "$credential_path"
    printf 'Registered persona: %s\n' "$name"
    [ -z "$result_var" ] || printf -v "$result_var" '%s' "$name"
}

_boxa::forge_add_one_locked() {
    local forge="$1" result_var="${2:-}"
    local name kind account_action host='' keys='' key_path ssh_choice
    local expected_username ssh_username='' key_username token_username=''
    local credential_path display_name token_guidance

    name="$(_boxa::forge_add_name)" || return 1
    kind="$(_boxa::forge_add_kind)" || return 1
    if [ -z "$forge" ]; then
        forge="$(_boxa::forge_add_forge)" || return 1
    fi
    if [ "$forge" = gitlab ]; then
        host="$(_boxa::forge_read_gitlab_host)" || return 1
    fi
    expected_username="$(_boxa::forge_add_expected_username)" || return 1
    case "$forge" in github) display_name=GitHub ;; gitlab) display_name=GitLab ;; esac
    credential_path="$(_boxa::forge_credential_path "$forge")" || return 1
    token_guidance="$(_boxa::forge_token_mint_guidance "$forge" "$host" "$kind")"
    if ! _boxa::forge_token_choice "$forge" "$host" paste token_username \
            "$display_name persona setup — configure the required token" required \
            "$token_guidance"; then
        rm -f -- "$credential_path"
        printf 'Persona was not registered because a verified token is mandatory.\n' \
            >&2
        return 1
    fi
    ssh_choice="$(_boxa::forge_add_ssh_choice "$forge" "$kind")" \
        || { rm -f -- "$credential_path"; return 1; }
    case "$ssh_choice" in
    all)
        if ! keys="$(_boxa::forge_all_host_persona_keys)"; then
            keys=''
            printf 'No valid SSH key pairs found under ~/.ssh; continuing without an SSH key.\n' \
                >&2
        fi
        ;;
    existing)
        keys="$(_boxa::forge_pick_existing_persona_keys "$name")" \
            || { rm -f -- "$credential_path"; return 1; }
        ;;
    agent)
        key_path="$(_boxa::ssh_agent_key_path)"
        if [ ! -f "$key_path" ] \
                || { [ -f "$key_path.pub" ] \
                    && ! _boxa::forge_key_fingerprint "$key_path" >/dev/null; }; then
            rm -f -- "$credential_path"
            printf 'The Agent key is not available: %s\n' "$key_path" >&2
            return 1
        fi
        keys="$key_path"
        ;;
    esac
    if [ -n "$keys" ]; then
        account_action="$(_boxa::forge_add_account_action "$forge")" \
            || { rm -f -- "$credential_path"; return 1; }
        _boxa::forge_add_account_guidance "$forge" "$account_action" "$host" \
            "$kind" "$keys"
        while IFS= read -r key_path; do
            [ -n "$key_path" ] || continue
            key_username=''
            _boxa::forge_verify_ssh_loop "${host:-github.com}" \
                key_username "$key_path"
            if [ -z "$key_username" ]; then
                if [ -n "${_BOXA_FORGE_SSH_VERIFICATION_SKIPPED:-}" ]; then
                    continue
                fi
                keys=''
                ssh_username=''
                break
            fi
            if [ -n "$ssh_username" ] \
                    && [ "$ssh_username" != "$key_username" ]; then
                printf 'Selected SSH keys authenticate as different accounts; no SSH keys were attached.\n' >&2
                keys=''
                ssh_username=''
                break
            fi
            ssh_username="$key_username"
        done <<< "$keys"
    fi
    _boxa::forge_warn_identity_mismatch "$ssh_username" "$token_username"
    if _boxa::forge_register_verified_identity "$name" "$forge" "$kind" \
            "$keys" "$expected_username" "$token_username" \
            "$result_var"; then
        printf 'Kind: %s\n' "$kind"
        printf 'Token: verified as %s; used for CLI and API operations.\n' \
            "$token_username"
        if [ -n "$keys" ]; then
            if [ -n "$ssh_username" ]; then
                printf 'SSH key: attached and verified as %s; used for git transport.\n' \
                    "$ssh_username"
            else
                printf 'SSH key: attached without verification; used for git transport.\n'
            fi
        else
            printf 'SSH key: none attached; this persona has no SSH git transport.\n'
        fi
        return 0
    fi
    rm -f -- "$credential_path"
    return 1
}

_boxa::forge_add_one_capture_locked() {
    local forge="$1" result_path="$2" captured_identity=''

    _boxa::forge_add_one_locked "$forge" captured_identity || return 1
    printf '%s\n' "$captured_identity" > "$result_path"
}

_boxa::forge_add_one() {
    local forge="$1" result_var="${2:-}" result_path status

    if [ -z "$result_var" ]; then
        _boxa::forge_with_catalog_lock _boxa::forge_add_one_locked "$forge"
        return
    fi
    result_path="$(mktemp)" || return 1
    if _boxa::forge_with_catalog_lock _boxa::forge_add_one_capture_locked \
            "$forge" "$result_path"; then
        IFS= read -r status < "$result_path" || status=
        rm -f -- "$result_path"
        printf -v "$result_var" '%s' "$status"
        return 0
    else
        status=$?
    fi
    rm -f -- "$result_path"
    return "$status"
}

_boxa::forge_add() {
    local forge="${1:-}" result_var="${2:-}"

    if ! _boxa::forge_has_tty; then
        printf "Persona registration needs an interactive terminal. Run 'boxa forge add'.\n" \
            >&2
        return 1
    fi
    case "$forge" in
        ''|github|gitlab) _boxa::forge_add_one "$forge" "$result_var" ;;
        *) printf 'Unknown forge: %s (expected github or gitlab)\n' "$forge" >&2; return 1 ;;
    esac
}

_boxa::forge_guided_setup() {
    _boxa::forge_dashboard "${2:-}" "${1:-}"
}

_boxa::forge_set_locked() {
    local forge="$1" skip_allowlist_offer="${2:-}" host="${3:-}"
    local defer_catalog_write="${4:-}"
    local token username='' created_at display_name cli identity_id kind auth

    case "$forge" in
        github)
            display_name=GitHub
            cli=gh
            ;;
        gitlab)
            display_name=GitLab
            cli=glab
            if [ -z "$host" ]; then
                printf 'Choose the GitLab instance whose token access will be configured.\n' \
                    >&2
                printf 'GitLab host [gitlab.com]: ' >&2
                IFS= read -r host </dev/tty || return 1
                host="${host:-gitlab.com}"
            fi
            if ! _boxa::forge_validate_host "$host"; then
                printf 'Invalid GitLab host.\n' >&2
                return 1
            fi
            ;;
        *)
            printf 'Unknown forge: %s (expected github or gitlab)\n' "$forge" >&2
            return 1
            ;;
    esac

    _boxa::forge_require_probe_cli "$forge" || return 1
    printf 'This token enables %s CLI and API operations, review requests, and committer identity; keep it private.\n' \
        "$cli" >&2
    IFS= read -r -s -p "Paste $display_name token: " token </dev/tty || {
        printf '\n' >&2
        return 1
    }
    printf '\n' >&2
    if [ -z "$token" ]; then
        printf 'Token cannot be empty.\n' >&2
        return 1
    fi
    if [[ "$token" == *$'\r'* || "$token" == *$'\n'* ]]; then
        printf 'Token must be a single line.\n' >&2
        return 1
    fi

    created_at="$(date +%s)"
    _boxa::forge_write_credential "$forge" "$token" "" "$host" "$created_at" \
        || return 1
    printf '%s credential stored.\n' "$display_name"

    if username="$(_boxa::forge_probe "$forge" "$token" "$host")"; then
        _boxa::forge_write_credential "$forge" "$token" "$username" "$host" \
            "$created_at" || return 1
        printf 'Authenticated as: %s\n' "$username"
        identity_id="$(_boxa::forge_identity_id "$forge" "$host" "$username")" \
            || return 1
        if [ -z "$skip_allowlist_offer" ] \
                && [ -z "$defer_catalog_write" ]; then
            if _boxa::forge_load_identity "$identity_id" "$forge"; then
                kind="$_BOXA_FORGE_IDENTITY_KIND"
                auth="$_BOXA_FORGE_IDENTITY_AUTH"
                _boxa::forge_write_identity "$forge" "$kind" "$token" \
                    "$username" "$host" "$created_at" "$auth" || return 1
                rm -f -- "$(_boxa::forge_credential_path "$forge")" || return 1
                printf 'Updated persona: %s\n' "$identity_id"
            else
                _boxa::forge_migrate_legacy_credentials || return 1
            fi
        fi
    else
        printf 'WARNING: Could not verify the %s token; the stored credential was kept.\n' \
            "$display_name" >&2
    fi
    [ -n "$skip_allowlist_offer" ] || _boxa::forge_offer_allowlist "$forge" "$host"
}

_boxa::forge_set() {
    _boxa::forge_with_catalog_lock _boxa::forge_set_locked "$@"
}

_boxa::forge_load_status_credential() {
    local project_path="$1" forge="$2" identity_id

    _boxa::resolve_forge_identity "$project_path" "$forge"
    identity_id="$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
    if [ -n "$identity_id" ] \
            && _boxa::forge_load_identity "$identity_id" "$forge"; then
        return 0
    fi
    _boxa::forge_load_credential "$forge"
}

_boxa::forge_unset() {
    local forge="$1" path display_name

    case "$forge" in
        github) display_name=GitHub ;;
        gitlab) display_name=GitLab ;;
        *)
            printf 'Unknown forge: %s (expected github or gitlab)\n' "$forge" >&2
            return 1
            ;;
    esac
    path="$(_boxa::forge_credential_path "$forge")" || return 1
    if [ -e "$path" ]; then
        rm -f -- "$path" || return 1
        printf '%s credential removed.\n' "$display_name"
    else
        printf 'No %s credential is configured.\n' "$display_name"
    fi
}

_boxa::forge_token_age_days() {
    local created_at="$1" now

    now="$(date +%s)"
    if [[ ! "$created_at" =~ ^[0-9]+$ ]] || [ "$created_at" -gt "$now" ]; then
        return 1
    fi
    printf '%s\n' "$(( (now - created_at) / 86400 ))"
}

_boxa::forge_persona_key_fingerprints() {
    local keys="$1" key_path fingerprint fingerprints=''

    while IFS= read -r key_path; do
        [ -n "$key_path" ] || continue
        fingerprint="$(ssh-keygen -lf "$key_path.pub" 2>/dev/null \
            | awk 'NR == 1 { print $2 }')"
        [ -n "$fingerprint" ] || fingerprint=unavailable
        fingerprints+="${fingerprints:+, }$fingerprint"
    done <<< "$keys"
    printf '%s\n' "${fingerprints:-none}"
}

_boxa::forge_list() {
    local store path identity_id kind_label github_age gitlab_age
    local forges fingerprints valid_count=0
    local paths=()

    store="$(_boxa::forge_identity_store_dir)"
    if [ -d "$store" ]; then
        paths=("$store"/*)
    fi
    for path in "${paths[@]}"; do
        [ -e "$path" ] || continue
        identity_id="${path##*/}"
        if [ ! -f "$path" ] || ! _boxa::forge_load_persona "$identity_id"; then
            printf 'WARNING: Skipping invalid persona: %s\n' \
                "$identity_id" >&2
            continue
        fi
        case "$_BOXA_FORGE_IDENTITY_KIND" in
            mine) kind_label=Mine ;;
            agent) kind_label=Agent ;;
            other) kind_label=Other ;;
        esac
        forges=''
        github_age='not configured'
        gitlab_age='not configured'
        if [ -n "$_BOXA_FORGE_GITHUB_TOKEN" ]; then
            forges=GitHub
            github_age="$(_boxa::forge_token_age_days \
                "$_BOXA_FORGE_GITHUB_CREATED_AT" 2>/dev/null || printf unknown)"
            [ "$github_age" = unknown ] || github_age+=" day(s)"
        fi
        if [ -n "$_BOXA_FORGE_GITLAB_TOKEN" ]; then
            forges+="${forges:+, }GitLab"
            gitlab_age="$(_boxa::forge_token_age_days \
                "$_BOXA_FORGE_GITLAB_CREATED_AT" 2>/dev/null || printf unknown)"
            [ "$gitlab_age" = unknown ] || gitlab_age+=" day(s)"
        fi
        fingerprints="$(_boxa::forge_persona_key_fingerprints \
            "$_BOXA_FORGE_PERSONA_KEYS")"
        printf 'Persona: %s | Kind: %s | Forges: %s | Token age: GitHub %s, GitLab %s | Keys: %s\n' \
            "$identity_id" "$kind_label" "${forges:-none}" "$github_age" \
            "$gitlab_age" "$fingerprints"
        valid_count=$((valid_count + 1))
    done
    if [ "$valid_count" -eq 0 ]; then
        printf 'No personas configured.\n'
    fi
}

_boxa::forge_persona_projects() {
    local identity_id="$1" project_path known_projects
    local -A seen=()

    _boxa::forge_find_identity_usages "$identity_id" || return 1
    for project_path in "${_BOXA_FORGE_IDENTITY_PROJECTS[@]}"; do
        [ -z "${seen[$project_path]:-}" ] || continue
        seen["$project_path"]=1
        printf '%s\n' "$project_path"
    done
    if [ -n "$_BOXA_FORGE_IDENTITY_DEFAULT" ]; then
        known_projects="$(_boxa::forge_known_project_paths)" || return 1
        while IFS= read -r project_path; do
            [ -n "$project_path" ] || continue
            [ -z "${seen[$project_path]:-}" ] || continue
            _boxa::resolve_forge_identity "$project_path" || return 1
            [ "$_BOXA_FORGE_RESOLVED_IDENTITY_ID" = "$identity_id" ] || continue
            seen["$project_path"]=1
            printf '%s\n' "$project_path"
        done <<< "$known_projects"
    fi
}

_boxa::forge_sync_persona_projects() {
    local identity_id="$1" project_path projects

    projects="$(_boxa::forge_persona_projects "$identity_id")" || return 1
    while IFS= read -r project_path; do
        [ -n "$project_path" ] || continue
        _boxa::forge_apply_project_ssh_gate "$project_path" || return 1
    done <<< "$projects"
}

_boxa::forge_replace_persona_keys_locked() {
    local identity_id="$1" keys="$2" history_key="${3:-}"
    local old_keys kind github_token github_username github_created_at
    local gitlab_token gitlab_username gitlab_host gitlab_created_at

    _boxa::forge_load_persona "$identity_id" || return 1
    old_keys="$_BOXA_FORGE_PERSONA_KEYS"
    kind="$_BOXA_FORGE_IDENTITY_KIND"
    github_token="$_BOXA_FORGE_GITHUB_TOKEN"
    github_username="$_BOXA_FORGE_GITHUB_USERNAME"
    github_created_at="$_BOXA_FORGE_GITHUB_CREATED_AT"
    gitlab_token="$_BOXA_FORGE_GITLAB_TOKEN"
    gitlab_username="$_BOXA_FORGE_GITLAB_USERNAME"
    gitlab_host="$_BOXA_FORGE_GITLAB_HOST"
    gitlab_created_at="$_BOXA_FORGE_GITLAB_CREATED_AT"
    [ -z "$history_key" ] \
        || _boxa::ssh_registry_record_history_key "$history_key" || return 1
    _boxa::forge_write_persona "$identity_id" "$kind" "$keys" \
        "$github_token" "$github_username" "$github_created_at" \
        "$gitlab_token" "$gitlab_username" "$gitlab_host" \
        "$gitlab_created_at" true || return 1
    if _boxa::forge_sync_persona_projects "$identity_id"; then
        return 0
    fi
    _boxa::forge_write_persona "$identity_id" "$kind" "$old_keys" \
        "$github_token" "$github_username" "$github_created_at" \
        "$gitlab_token" "$gitlab_username" "$gitlab_host" \
        "$gitlab_created_at" true || true
    _boxa::forge_sync_persona_projects "$identity_id" || true
    return 1
}

_boxa::forge_attach_persona_key_locked() {
    local identity_id="$1" key_path="$2" keys existing

    _boxa::forge_load_persona "$identity_id" || return 1
    keys="$_BOXA_FORGE_PERSONA_KEYS"
    while IFS= read -r existing; do
        [ "$existing" != "$key_path" ] || {
            printf 'This key is already attached to persona %s: %s\n' \
                "$identity_id" "$key_path" >&2
            return 1
        }
    done <<< "$keys"
    keys+="${keys:+$'\n'}$key_path"
    _boxa::forge_replace_persona_keys_locked "$identity_id" "$keys" \
        "$key_path"
}

_boxa::forge_detach_persona_key_locked() {
    local identity_id="$1" detached="$2" keys='' key_path found=''

    _boxa::forge_load_persona "$identity_id" || return 1
    while IFS= read -r key_path; do
        [ -n "$key_path" ] || continue
        if [ "$key_path" = "$detached" ]; then
            found=1
            continue
        fi
        keys+="${keys:+$'\n'}$key_path"
    done <<< "$_BOXA_FORGE_PERSONA_KEYS"
    [ -n "$found" ] || return 1
    _boxa::forge_replace_persona_keys_locked "$identity_id" "$keys" \
        "$detached"
}

_boxa::forge_github_key_caveat() {
    printf 'GitHub caveat: one SSH key authenticates exactly one GitHub account; if this key is already used for another GitHub account, GitHub will reject it or authenticate pushes as that account.\n'
}

_boxa::forge_missing_public_key_guidance() {
    local key_path="$1"

    printf 'Create it yourself with: ssh-keygen -y -f %q > %q\n' \
        "$key_path" "$key_path.pub"
    printf 'This command prompts for the key passphrase if it has one; Boxa will not run it.\n'
}

_boxa::forge_key_fingerprint() {
    local key_path="$1" key_info fingerprint

    key_info="$(ssh-keygen -lf "$key_path.pub" 2>/dev/null)" || return 1
    fingerprint="${key_info#* }"
    fingerprint="${fingerprint%% *}"
    [ -n "$fingerprint" ] || return 1
    printf '%s\n' "$fingerprint"
}

_boxa::forge_next_agent_key_path() {
    local identity_id="$1" identity_dir base candidate suffix=2

    identity_dir="$(_boxa::ssh_agent_identity_dir)"
    base="$identity_dir/id_ed25519_$identity_id"
    candidate="$base"
    while [ -e "$candidate" ] || [ -e "$candidate.pub" ]; do
        candidate="${base}_$suffix"
        suffix=$((suffix + 1))
    done
    printf '%s\n' "$candidate"
}

_boxa::forge_generate_persona_key() {
    local identity_id="$1" key_path result_path status

    _boxa::forge_github_key_caveat
    result_path="$(mktemp)" || return 1
    if _boxa::forge_with_catalog_lock \
            _boxa::forge_generate_persona_key_locked "$identity_id" \
            "$result_path"; then
        IFS= read -r key_path < "$result_path" || key_path=
        rm -f -- "$result_path"
    else
        status=$?
        rm -f -- "$result_path"
        return "$status"
    fi
    [ -n "$key_path" ] || return 1
    printf 'Generated and attached SSH key for persona %s: %s\n' \
        "$identity_id" "$key_path"
    _boxa::forge_offer_key_verification "$identity_id" "$key_path"
}

_boxa::forge_generate_persona_key_locked() {
    local identity_id="$1" result_path="$2" key_path

    key_path="$(_boxa::forge_next_agent_key_path "$identity_id")" || return 1
    BOXA_AGENT_KEY="$key_path" _boxa::ssh_generate_agent_key || return 1
    _boxa::forge_attach_persona_key_locked "$identity_id" "$key_path" \
        || return 1
    printf '%s\n' "$key_path" > "$result_path"
}

_boxa::forge_all_host_persona_keys() {
    local discovered path fingerprint keys=''

    discovered="$(_boxa::ssh_discover_keys "$HOME/.ssh")" || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -f "$path.pub" ]; then
            if ! fingerprint="$(_boxa::forge_key_fingerprint "$path")" \
                    || [ -z "$fingerprint" ]; then
                printf 'Skipping SSH key with an unreadable or invalid public key: %s.pub\n' \
                    "$path" >&2
                continue
            fi
        fi
        keys+="${keys:+$'\n'}$path"
    done <<< "$discovered"
    [ -n "$keys" ] || return 1
    printf '%s\n' "$keys"
}

_boxa::forge_pick_existing_persona_keys() {
    local identity_id="$1" manual='Enter a key path manually'
    local path comment fingerprint label selected key_path discovered i found
    local keys=''
    local -a key_paths=() key_labels=()

    _boxa::forge_github_key_caveat >/dev/tty
    if _boxa::ssh_confirm_discovery; then
        discovered="$(_boxa::ssh_discover_keys "$HOME/.ssh")" || return 1
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            if [ -f "$path.pub" ]; then
                if ! fingerprint="$(_boxa::forge_key_fingerprint "$path")" \
                        || [ -z "$fingerprint" ]; then
                    printf 'Skipping SSH key with an unreadable or invalid public key: %s.pub\n' \
                        "$path" >&2
                    continue
                fi
                comment="$(_boxa::ssh_public_comment "$path")"
                label="$fingerprint — $path"
                [ -z "$comment" ] || label+=" — $comment"
            else
                label="$path (no .pub — fingerprint unavailable)"
            fi
            key_paths+=("$path")
            key_labels+=("$label")
        done <<< "$discovered"
    fi
    selected="$(printf '%s\n' ${key_labels[@]+"${key_labels[@]}"} \
        | picker::many --prompt 'Adopt SSH keys:' \
            --header "Persona '$identity_id' — attach existing keys by path; Boxa never reads or copies private key material."$'\n''Question: Which keys should be attached?' \
            --first-option "$manual")" || return 1
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        key_path=''
        if [ "$label" = "$manual" ]; then
            key_path="$(_boxa::ssh_read_manual_path)" || return 1
        else
            found=''
            for ((i = 0; i < ${#key_labels[@]}; i++)); do
                if [ "$label" = "${key_labels[$i]}" ]; then
                    key_path="${key_paths[$i]}"
                    found=1
                    break
                fi
            done
            [ -n "$found" ] || return 1
        fi
        if [ ! -f "$key_path" ] \
                || { [ -f "$key_path.pub" ] \
                    && ! _boxa::forge_key_fingerprint "$key_path" >/dev/null; }; then
            printf 'Existing private key is unavailable, or its public key is invalid: %s\n' \
                "$key_path" >&2
            return 1
        fi
        keys+="${keys:+$'\n'}$key_path"
    done <<< "$selected"
    [ -n "$keys" ] || return 1
    printf '%s\n' "$keys"
}

_boxa::forge_adopt_persona_key() {
    local identity_id="$1" keys key_path

    keys="$(_boxa::forge_pick_existing_persona_keys "$identity_id")" \
        || return 1
    while IFS= read -r key_path; do
        [ -n "$key_path" ] || continue
        _boxa::forge_with_catalog_lock _boxa::forge_attach_persona_key_locked \
            "$identity_id" "$key_path" || return 1
        printf 'Adopted and attached SSH key: %s\n' "$key_path"
        _boxa::forge_offer_key_verification "$identity_id" "$key_path"
    done <<< "$keys"
}

_boxa::forge_select_persona_key() {
    local identity_id="$1" prompt="$2" selected path fingerprint label i
    local -a key_paths=() key_labels=()

    _boxa::forge_load_persona "$identity_id" || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        fingerprint="$(_boxa::forge_key_fingerprint "$path")" \
            || fingerprint=unavailable
        key_paths+=("$path")
        key_labels+=("$fingerprint — $path")
    done <<< "$_BOXA_FORGE_PERSONA_KEYS"
    [ "${#key_paths[@]}" -gt 0 ] || return 1
    selected="$(printf '%s\n' "${key_labels[@]}" \
        | picker::one --prompt "$prompt" \
            --header "Persona '$identity_id' SSH keys."$'\n''Question: Which key?')" \
        || return 1
    for ((i = 0; i < ${#key_labels[@]}; i++)); do
        if [ "$selected" = "${key_labels[$i]}" ]; then
            printf '%s\n' "${key_paths[$i]}"
            return 0
        fi
    done
    return 1
}

_boxa::forge_detach_persona_key() {
    local identity_id="$1" key_path

    key_path="$(_boxa::forge_select_persona_key "$identity_id" \
        'Detach an SSH key:')" || return 1
    _boxa::forge_with_catalog_lock _boxa::forge_detach_persona_key_locked \
        "$identity_id" "$key_path" || return 1
    printf 'Detached SSH key from persona %s: %s\n' "$identity_id" "$key_path"
    printf 'The key file was not deleted, and its Key registry history was preserved.\n'
}

_boxa::forge_key_verification_host() {
    local identity_id="$1" selected
    local github='GitHub (github.com)' gitlab='' host=''
    local -a choices=()

    _boxa::forge_load_persona "$identity_id" || return 1
    if [ -n "$_BOXA_FORGE_GITHUB_TOKEN" ]; then
        choices+=("$github")
    fi
    if [ -n "$_BOXA_FORGE_GITLAB_TOKEN" ]; then
        host="$_BOXA_FORGE_GITLAB_HOST"
        gitlab="GitLab ($host)"
        choices+=("$gitlab")
    fi
    [ "${#choices[@]}" -gt 0 ] || return 1
    selected="$(printf '%s\n' "${choices[@]}" \
        | picker::one --prompt 'Key verification host:' \
            --header 'Per-key SSH verification uses only the selected identity.'$'\n''Question: Which forge should identify this key?')" \
        || return 1
    case "$selected" in
        "$github") printf 'github.com\n' ;;
        "$gitlab") printf '%s\n' "$host" ;;
        *) return 1 ;;
    esac
}

_boxa::forge_verify_persona_key_path() {
    local identity_id="$1" key_path="$2" host username fingerprint

    if [ ! -f "$key_path.pub" ]; then
        printf 'Key fingerprint and per-key verification are unavailable because the public key is missing: %s.pub\n' \
            "$key_path" >&2
        _boxa::forge_missing_public_key_guidance "$key_path" >&2
        return 1
    fi
    host="$(_boxa::forge_key_verification_host "$identity_id")" || return 1
    fingerprint="$(_boxa::forge_key_fingerprint "$key_path")" \
        || fingerprint=unavailable
    if username="$(_boxa::forge_ssh_probe_key_username "$host" "$key_path")"; then
        printf 'Key %s authenticates as: %s\n' \
            "${fingerprint:-unavailable}" "$username"
    else
        printf 'Key %s could not be verified with %s (key rejected, passphrase required, or host unreachable).\n' \
            "${fingerprint:-unavailable}" "$host" >&2
    fi
}

_boxa::forge_verify_persona_key() {
    local identity_id="$1" key_path

    key_path="$(_boxa::forge_select_persona_key "$identity_id" \
        'Verify an SSH key:')" || return 1
    _boxa::forge_verify_persona_key_path "$identity_id" "$key_path"
}

_boxa::forge_offer_key_verification() {
    local identity_id="$1" key_path="$2" verify='Verify this key now'
    local skip='Skip verification' selected caveat

    caveat="$(_boxa::forge_github_key_caveat)" || return 1
    selected="$(printf '%s\n' "$verify" "$skip" \
        | picker::one --prompt 'Key verification:' \
            --header "$caveat"$'\n''Question: Verify which account this key authenticates as now?')" \
        || return 0
    [ "$selected" = "$verify" ] || return 0
    _boxa::forge_verify_persona_key_path "$identity_id" "$key_path"
}

_boxa::forge_keys() {
    local identity_id="$1" generate
    local adopt='Adopt an existing key' detach='Detach a key'
    local verify='Verify a key' selected
    local -a actions

    if ! _boxa::forge_has_tty; then
        printf "Persona key management needs an interactive terminal. Run 'boxa forge keys %s'.\n" \
            "$identity_id" >&2
        return 1
    fi
    if ! _boxa::forge_validate_persona_name "$identity_id" \
            || ! _boxa::forge_load_persona "$identity_id"; then
        printf "Unknown persona '%s'. Run 'boxa forge list' to see configured personas.\n" \
            "$identity_id" >&2
        return 1
    fi
    generate='Generate a new SSH key for this persona'
    if [ "$_BOXA_FORGE_IDENTITY_KIND" = agent ]; then
        generate='Generate a new SSH key for this agent persona'
    fi
    actions=("$generate" "$adopt")
    if [ -n "$_BOXA_FORGE_PERSONA_KEYS" ]; then
        actions+=("$detach" "$verify")
    fi
    selected="$(printf '%s\n' "${actions[@]}" \
        | picker::one --prompt 'Persona key action:' \
            --header "Persona '$identity_id' — manage the SSH keys forwarded through every assigned Project's per-project ssh-agent."$'\n''Question: What should change?')" \
        || return 1
    case "$selected" in
        "$generate") _boxa::forge_generate_persona_key "$identity_id" ;;
        "$adopt") _boxa::forge_adopt_persona_key "$identity_id" ;;
        "$detach") _boxa::forge_detach_persona_key "$identity_id" ;;
        "$verify") _boxa::forge_verify_persona_key "$identity_id" ;;
        *) return 1 ;;
    esac
}

_boxa::forge_require_identity() {
    local identity_id="$1"

    if ! _boxa::forge_validate_identity_id "$identity_id" \
            || ! _boxa::forge_load_identity "$identity_id"; then
        printf "Unknown persona '%s'. Run 'boxa forge list' to see configured personas, or 'boxa forge setup' to configure one.\n" \
            "$identity_id" >&2
        return 1
    fi
}

_boxa::forge_identity_forge() {
    _boxa::forge_load_persona "$1" || return 1
    if [ -n "$_BOXA_FORGE_GITHUB_TOKEN" ]; then
        printf 'github\n'
    elif [ -n "$_BOXA_FORGE_GITLAB_TOKEN" ]; then
        printf 'gitlab\n'
    else
        return 1
    fi
}

_boxa::forge_row_key() {
    printf '%s' "${1##*$'\t'}"
}

_boxa::forge_identity_picker() {
    local store path identity_id kind_label row picked
    local add='Add a persona'
    local -a paths=() menu=()

    store="$(_boxa::forge_identity_store_dir)"
    if [ -d "$store" ]; then
        paths=("$store"/*)
    fi
    for path in "${paths[@]}"; do
        [ -e "$path" ] || continue
        identity_id="${path##*/}"
        if [ ! -f "$path" ] || ! _boxa::forge_load_persona "$identity_id"; then
            printf 'WARNING: Skipping invalid persona: %s\n' \
                "$identity_id" >&2
            continue
        fi
        case "$_BOXA_FORGE_IDENTITY_KIND" in
            mine) kind_label=Mine ;;
            agent) kind_label=Agent ;;
            other) kind_label=Other ;;
        esac
        row="$(printf '%-42s' "$identity_id")"$'\t'"$identity_id"
        menu+=("$kind_label | $row")
    done
    menu+=("$add")
    picked="$(printf '%s\n' "${menu[@]}" | picker::one \
        --prompt 'Use persona' \
        --header 'Forge assignment — choose the persona this Project should use.'$'\n''Question: Which persona should be assigned?')" \
        || { printf 'No persona chosen; nothing assigned.\n' >&2; return 1; }
    if [ "$picked" = "$add" ]; then
        _boxa::forge_add '' identity_id || return 1
        printf '%s\n' "$identity_id"
        return 0
    fi
    identity_id="$(_boxa::forge_row_key "$picked")"
    _boxa::forge_require_identity "$identity_id" || return 1
    printf '%s\n' "$identity_id"
}

_boxa::forge_project_picker() {
    local identity_id="$1" default_key="$2"
    local targets name key row default_row='' picked
    local -a menu=()

    targets="$(_boxa::forge_project_targets)" || return 1
    while IFS=$'\t' read -r name key; do
        [ -n "$key" ] || continue
        row="$(printf '%-20s' "$name")"$'\t'"$key"
        if [ "$key" = "$default_key" ]; then
            default_row="$row"
        else
            menu+=("$row")
        fi
    done <<< "$targets"
    if [ -z "$default_row" ] && [ -n "$default_key" ]; then
        default_row="$(printf '%-20s' 'Current Project')"$'\t'"$default_key"
    fi
    if [ -z "$default_row" ] && [ "${#menu[@]}" -eq 0 ]; then
        printf 'No boxa Projects are available for forge assignment.\n' >&2
        return 1
    fi

    if [ -n "$default_row" ]; then
        picked="$(printf '%s\n' ${menu[@]+"${menu[@]}"} | picker::many \
            --prompt "Assign '$identity_id' in Projects" \
            --header "Forge assignment for '$identity_id'."$'\n''Question: Which Projects should use this identity? Current Project is the default (a).' \
            --first-option "$default_row")" \
            || { printf 'No Project chosen; nothing assigned.\n' >&2; return 1; }
    else
        picked="$(printf '%s\n' "${menu[@]}" | picker::many \
            --prompt "Assign '$identity_id' in Projects" \
            --header "Forge assignment for '$identity_id'."$'\n''Question: Which Projects should use this identity?')" \
            || { printf 'No Project chosen; nothing assigned.\n' >&2; return 1; }
    fi

    while IFS= read -r row; do
        key="$(_boxa::forge_row_key "$row")"
        [ -n "$key" ] && printf '%s\n' "$key"
    done <<< "$picked"
}

_boxa::forge_known_project_picker() {
    local action="$1" project_path row picked
    local -a menu=()
    local -A seen=()

    while IFS= read -r project_path; do
        [[ "$project_path" == /* ]] || continue
        [ -z "${seen[$project_path]:-}" ] || continue
        seen["$project_path"]=1
        row="$(printf '%-20s' "${project_path##*/}")"$'\t'"$project_path"
        menu+=("$row")
    done < <(_boxa::forge_known_project_paths)
    if [ "${#menu[@]}" -eq 0 ]; then
        printf 'No known boxa Projects are available.\n' >&2
        return 1
    fi

    picked="$(printf '%s\n' "${menu[@]}" | picker::many \
        --prompt "Set SSH forwarding $action in Projects" \
        --header "SSH forwarding — set selected Projects to $action."$'\n''Question: Which Projects should be changed?')" \
        || { printf 'No Project chosen; SSH forwarding was not changed.\n' >&2; return 1; }
    while IFS= read -r row; do
        project_path="$(_boxa::forge_row_key "$row")"
        [ -n "$project_path" ] && printf '%s\n' "$project_path"
    done <<< "$picked"
}

_boxa::forge_compute_project_ssh_gate() {
    local project_path="$1" identity_id

    _BOXA_FORGE_SYNTHESIZED_SSH_GATE=off
    _boxa::resolve_forge_identity "$project_path" || return 1
    [ "$_BOXA_FORGE_GATE" = on ] || return 0
    identity_id="$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
    [ -n "$identity_id" ] || return 0
    if ! _boxa::forge_load_persona "$identity_id"; then
        printf "Cannot compute SSH forwarding: assigned persona '%s' is invalid.\n" \
            "$identity_id" >&2
        return 1
    fi
    [ -z "$_BOXA_FORGE_PERSONA_KEYS" ] \
        || _BOXA_FORGE_SYNTHESIZED_SSH_GATE=on
}

_boxa::forge_reconcile_project_ssh_gate() {
    local project_path="$1"

    if [ "$_BOXA_FORGE_SYNTHESIZED_SSH_GATE" = on ]; then
        _boxa::ssh_reconcile_running_project_agent "$project_path"
        return
    fi
    _boxa::ssh_resolve_project_agent "$project_path" || return 0
    ssh-add -D >/dev/null 2>&1 || return 1
}

_boxa::forge_apply_project_ssh_gate_locked() {
    local project_path="$1" report_change="$2" old_gate="$3" keys="$4"
    local registry registry_backup='' registry_existed=''

    registry="$(_boxa::ssh_key_registry_path)"
    _boxa::forge_backup_file "$registry" registry_backup registry_existed \
        || return 1
    if ! _boxa::ssh_registry_replace_project "$project_path" "$keys" \
            || ! _boxa::write_ssh_conf project "$project_path" \
                "$_BOXA_FORGE_SYNTHESIZED_SSH_GATE" \
            || ! _boxa::forge_reconcile_project_ssh_gate "$project_path"; then
        _boxa::forge_restore_file "$registry" "$registry_backup" \
            "$registry_existed" || true
        return 1
    fi
    _boxa::forge_discard_backup "$registry_backup"
    if [ "$report_change" = true ] \
            && [ "$old_gate" != "$_BOXA_FORGE_SYNTHESIZED_SSH_GATE" ]; then
        printf 'Project %s SSH forwarding changed from %s to %s.\n' \
            "$project_path" "$old_gate" "$_BOXA_FORGE_SYNTHESIZED_SSH_GATE"
    fi
}

_boxa::forge_disable_project_ssh_gate_locked() {
    local project_path="$1" report_change="$2" old_gate="$3"

    # The forge kill switch empties a live agent but keeps its registry bundle
    # so forge on can restore the assigned persona without reassignment.
    _BOXA_FORGE_SYNTHESIZED_SSH_GATE=off
    _boxa::write_ssh_conf project "$project_path" off \
        && _boxa::forge_reconcile_project_ssh_gate "$project_path" || return 1
    if [ "$report_change" = true ] && [ "$old_gate" != off ]; then
        printf 'Project %s SSH forwarding changed from %s to off.\n' \
            "$project_path" "$old_gate"
    fi
}

_boxa::forge_disable_project_ssh_gate() {
    local project_path="$1" report_change="${2:-false}" old_gate

    _boxa::resolve_ssh_gate "$project_path"
    old_gate="$_BOXA_SSH_GATE"
    _boxa::ssh_with_registry_lock \
        _boxa::forge_disable_project_ssh_gate_locked \
        "$project_path" "$report_change" "$old_gate"
}

_boxa::forge_apply_project_ssh_gate() {
    local project_path="$1" report_change="${2:-false}" old_gate
    local identity_id keys=''

    _boxa::resolve_ssh_gate "$project_path"
    old_gate="$_BOXA_SSH_GATE"
    _boxa::forge_compute_project_ssh_gate "$project_path" || return 1
    _boxa::resolve_forge_identity "$project_path" || return 1
    identity_id="$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
    if [ -n "$identity_id" ]; then
        _boxa::forge_load_persona "$identity_id" || return 1
        keys="$_BOXA_FORGE_PERSONA_KEYS"
    fi
    _boxa::ssh_with_registry_lock _boxa::forge_apply_project_ssh_gate_locked \
        "$project_path" "$report_change" "$old_gate" "$keys"
}

_boxa::forge_set_gate_locked() {
    local scope="$1" project_path="$2" action="$3" known_projects
    local forge_conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local ssh_conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local forge_backup='' ssh_backup='' forge_existed='' ssh_existed=''
    local retry_command status=0 rollback_status=0 failed_project
    local -a affected_projects=() failed_projects=()
    local -A seen=()

    _boxa::forge_backup_file "$forge_conf" forge_backup forge_existed \
        || return 1
    if ! _boxa::forge_backup_file "$ssh_conf" ssh_backup ssh_existed; then
        _boxa::forge_restore_file "$forge_conf" "$forge_backup" \
            "$forge_existed" || true
        return 1
    fi
    if ! _boxa::write_forge_conf_locked "$scope" "$project_path" "$action"; then
        status=1
    fi
    if [ "$scope" = project ]; then
        affected_projects+=("$project_path")
        if [ "$status" -eq 0 ]; then
            if [ "$action" = off ]; then
                _boxa::forge_disable_project_ssh_gate "$project_path" true \
                    || status=1
            else
                _boxa::forge_apply_project_ssh_gate "$project_path" true \
                    || status=1
            fi
            if [ "$status" -ne 0 ]; then
                failed_projects+=("$project_path")
            fi
        fi
    elif [ "$status" -eq 0 ]; then
        if ! known_projects="$(_boxa::forge_known_project_paths)"; then
            status=1
        else
            while IFS= read -r project_path; do
                [[ "$project_path" == /* ]] || continue
                [ -z "${seen[$project_path]:-}" ] || continue
                seen["$project_path"]=1
                _boxa::resolve_forge_gate "$project_path"
                [ "$_BOXA_FORGE_SOURCE" = global ] || continue
                affected_projects+=("$project_path")
                if [ "$action" = off ]; then
                    _boxa::forge_disable_project_ssh_gate \
                        "$project_path" true || {
                        failed_projects+=("$project_path")
                        status=1
                    }
                else
                    _boxa::forge_apply_project_ssh_gate \
                        "$project_path" true || {
                        failed_projects+=("$project_path")
                        status=1
                    }
                fi
            done <<< "$known_projects"
        fi
    fi

    if [ "$status" -eq 0 ]; then
        _boxa::forge_discard_backup "$forge_backup"
        _boxa::forge_discard_backup "$ssh_backup"
        return 0
    fi

    for failed_project in "${failed_projects[@]}"; do
        printf 'Could not apply the SSH forwarding change for Project %s.\n' \
            "$failed_project" >&2
    done
    if [ "$action" = off ]; then
        _boxa::forge_discard_backup "$forge_backup"
        _boxa::forge_discard_backup "$ssh_backup"
        return 1
    fi
    _boxa::forge_restore_file "$forge_conf" "$forge_backup" \
        "$forge_existed" || rollback_status=1
    _boxa::forge_restore_file "$ssh_conf" "$ssh_backup" \
        "$ssh_existed" || rollback_status=1
    for project_path in "${affected_projects[@]}"; do
        if ! _boxa::forge_compute_project_ssh_gate "$project_path" \
                || ! _boxa::ssh_with_registry_lock \
                    _boxa::forge_reconcile_project_ssh_gate "$project_path"; then
            printf 'Could not restore SSH forwarding for Project %s after the failed forge access change.\n' \
                "$project_path" >&2
            rollback_status=1
        fi
    done
    if [ "$scope" = global ]; then
        retry_command="boxa forge $action --global"
    else
        retry_command="boxa forge $action $project_path"
    fi
    printf "Forge access change was not applied; forge access and SSH forwarding were not changed. Re-run '%s'.\n" \
        "$retry_command" >&2
    [ "$rollback_status" -eq 0 ] || return 1
    return 1
}

_boxa::forge_missing_persona_note() {
    local project_path="$1" gate="$2"

    if [ "$gate" = on ]; then
        printf "Gate is on, but no persona is assigned to %s, so nothing will be forwarded until a persona with SSH keys is assigned.\n" \
            "$project_path"
    else
        printf "Forge access is on, but no persona is assigned to %s, so SSH forwarding stays off. Run 'boxa forge use' to assign one.\n" \
            "$project_path"
    fi
}

_boxa::forge_keyless_persona_note() {
    local identity_id="$1" gate="$2"

    if [ "$gate" = on ]; then
        printf "Gate is on, but persona '%s' has no attached SSH keys, so nothing will be forwarded. Attach keys in 'boxa forge' (Attach an SSH key).\n" \
            "$identity_id"
    else
        printf "Forge access is on, but persona '%s' has no attached SSH keys, so SSH forwarding stays off. Attach keys in 'boxa forge' (Attach an SSH key).\n" \
            "$identity_id"
    fi
}

_boxa::forge_offer_missing_persona_assignment() {
    local project_path="$1"

    _boxa::forge_has_tty || return 2
    _boxa::forge_use '' "$project_path"
}

_boxa::forge_report_project_ssh_outcome() {
    local project_path="$1" identity_id key_path key_label
    local key_count=0

    _boxa::resolve_forge_identity "$project_path" || return 1
    identity_id="$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
    _boxa::resolve_ssh_gate "$project_path"
    if [ "$_BOXA_SSH_GATE" = on ] && [ -n "$identity_id" ]; then
        _boxa::forge_load_persona "$identity_id" || return 1
        while IFS= read -r key_path; do
            [ -z "$key_path" ] || key_count=$((key_count + 1))
        done <<< "$_BOXA_FORGE_PERSONA_KEYS"
        key_label=keys
        [ "$key_count" -ne 1 ] || key_label=key
        printf "Project %s SSH forwarding: on (persona '%s', %s attached %s).\n" \
            "$project_path" "$identity_id" "$key_count" "$key_label"
    elif [ -z "$identity_id" ]; then
        printf "Project %s SSH forwarding: still off (no persona assigned; run 'boxa forge use').\n" \
            "$project_path"
    else
        printf "Project %s SSH forwarding: still off (persona '%s' has no attached SSH keys; attach keys in 'boxa forge').\n" \
            "$project_path" "$identity_id"
    fi
}

_boxa::forge_on_project_follow_up() {
    local project_path="$1" identity_id assignment_status=0

    _boxa::resolve_forge_identity "$project_path" || return 1
    identity_id="$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
    if [ -z "$identity_id" ]; then
        _boxa::forge_offer_missing_persona_assignment "$project_path" \
            || assignment_status=$?
        case "$assignment_status" in
            0|1|2) ;;
            *) return "$assignment_status" ;;
        esac
        _boxa::resolve_forge_identity "$project_path" || return 1
        identity_id="$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
        if [ -z "$identity_id" ]; then
            _boxa::forge_missing_persona_note "$project_path" off
        fi
    fi
    if [ -n "$identity_id" ]; then
        _boxa::forge_load_persona "$identity_id" || return 1
        [ -n "$_BOXA_FORGE_PERSONA_KEYS" ] \
            || _boxa::forge_keyless_persona_note "$identity_id" off
    fi
    _boxa::forge_report_project_ssh_outcome "$project_path"
}

_boxa::forge_report_global_still_off_projects() {
    local project_path known_projects
    local -A seen=()

    known_projects="$(_boxa::forge_known_project_paths)" || return 1
    while IFS= read -r project_path; do
        [[ "$project_path" == /* ]] || continue
        [ -z "${seen[$project_path]:-}" ] || continue
        seen["$project_path"]=1
        _boxa::resolve_forge_gate "$project_path"
        [ "$_BOXA_FORGE_SOURCE" = global ] || continue
        _boxa::resolve_ssh_gate "$project_path"
        [ "$_BOXA_SSH_GATE" != on ] \
            || continue
        _boxa::forge_report_project_ssh_outcome "$project_path" || return 1
    done <<< "$known_projects"
}

_boxa::forge_set_gate() {
    local scope="$1" project_path="$2" action="$3"

    _boxa::forge_with_catalog_lock _boxa::forge_set_gate_locked "$@" \
        || return 1
    [ "$action" = on ] || return 0
    if [ "$scope" = project ]; then
        _boxa::forge_on_project_follow_up "$project_path"
    else
        _boxa::forge_report_global_still_off_projects
    fi
}

_boxa::forge_backup_file() {
    local path="$1" backup_var="$2" existed_var="$3" dir backup

    dir="${path%/*}"
    [ "$dir" != "$path" ] || dir=.
    mkdir -p "$dir" || return 1
    backup="$(mktemp "${path}.backup.XXXXXX")" || return 1
    if [ -e "$path" ]; then
        cp -p -- "$path" "$backup" || {
            rm -f -- "$backup"
            return 1
        }
        printf -v "$existed_var" '%s' true
    else
        printf -v "$existed_var" '%s' false
    fi
    printf -v "$backup_var" '%s' "$backup"
}

_boxa::forge_restore_file() {
    local path="$1" backup="$2" existed="$3"

    if [ "$existed" = true ]; then
        mv -f -- "$backup" "$path"
    else
        rm -f -- "$path" "$backup"
    fi
}

_boxa::forge_discard_backup() {
    [ -z "$1" ] || rm -f -- "$1"
}

_boxa::forge_assign_identity_locked() {
    local identity_id="$1" project_path="$2"
    local report_assignment="${3:-true}"
    local forge_value=on
    local forge_conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local ssh_conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local forge_backup='' ssh_backup=''
    local forge_existed='' ssh_existed=''

    if [ "$identity_id" = none ]; then
        forge_value=off
    else
        _boxa::forge_require_identity "$identity_id" || return 1
    fi
    _boxa::forge_backup_file "$forge_conf" forge_backup forge_existed \
        || return 1
    if ! _boxa::forge_backup_file "$ssh_conf" ssh_backup ssh_existed; then
        _boxa::forge_restore_file "$forge_conf" "$forge_backup" \
            "$forge_existed" || true
        _boxa::forge_discard_backup "$ssh_backup"
        return 1
    fi
    if ! _boxa::write_forge_conf project "$project_path" "$identity_id" \
            identity; then
        _boxa::forge_restore_file "$forge_conf" "$forge_backup" \
            "$forge_existed" || true
        _boxa::forge_restore_file "$ssh_conf" "$ssh_backup" \
            "$ssh_existed" || true
        printf "Persona assignment was not applied; forge access and SSH forwarding were not changed. Re-run 'boxa forge use'.\n" >&2
        return 1
    fi
    if ! _boxa::write_forge_conf project "$project_path" "$forge_value"; then
        _boxa::forge_restore_file "$forge_conf" "$forge_backup" \
            "$forge_existed" || true
        _boxa::forge_restore_file "$ssh_conf" "$ssh_backup" \
            "$ssh_existed" || true
        printf "Persona assignment was not applied; forge access and SSH forwarding were not changed. Re-run 'boxa forge use'.\n" >&2
        return 1
    fi
    if ! _boxa::forge_apply_project_ssh_gate "$project_path"; then
        _boxa::forge_restore_file "$forge_conf" "$forge_backup" \
            "$forge_existed" || true
        _boxa::forge_restore_file "$ssh_conf" "$ssh_backup" \
            "$ssh_existed" || true
        _boxa::ssh_reconcile_running_project_agent "$project_path" || true
        printf "Persona assignment was not applied; forge access and SSH forwarding were not changed. Re-run 'boxa forge use'.\n" >&2
        return 1
    fi
    _boxa::forge_discard_backup "$forge_backup"
    _boxa::forge_discard_backup "$ssh_backup"
    if [ "$report_assignment" = true ]; then
        if [ "$identity_id" = none ]; then
            printf "Persona assignment cleared for %s; forge access is off and no persona SSH keys will be forwarded into this project's ssh-agent (gate off).\n" \
                "$project_path"
        elif [ "$_BOXA_FORGE_SYNTHESIZED_SSH_GATE" = on ]; then
            printf "Persona '%s' assigned to %s; forge access is on; its SSH keys will be forwarded into this project's ssh-agent (gate on).\n" \
                "$identity_id" "$project_path"
        else
            printf "Persona '%s' assigned to %s; forge access is on; its SSH keys will not be forwarded into this project's ssh-agent (gate off).\n" \
                "$identity_id" "$project_path"
        fi
    fi
}

_boxa::forge_assign_identity() {
    _boxa::forge_with_catalog_lock _boxa::forge_assign_identity_locked "$@"
}

_boxa::forge_use() {
    local identity_id="${1:-}" current_project="$2" project_path
    local old_identity_id new_identity_id old_forge_gate new_forge_gate
    local old_gate new_gate projects
    local recreation_hint summary_line
    local -a summary_lines=()

    if [ -n "$identity_id" ] && [ "$identity_id" != none ]; then
        _boxa::forge_require_identity "$identity_id" || return 1
    fi
    if ! _boxa::forge_has_tty; then
        printf "Forge assignment needs an interactive terminal. Run 'boxa forge use%s'.\n" \
            "${identity_id:+ $identity_id}" >&2
        return 1
    fi
    if [ -z "$identity_id" ]; then
        identity_id="$(_boxa::forge_identity_picker)" || return 1
    fi
    projects="$(_boxa::forge_project_picker "$identity_id" "$current_project")" \
        || return 1
    while IFS= read -r project_path; do
        [ -n "$project_path" ] || continue
        _boxa::resolve_forge_identity "$project_path" || return 1
        old_identity_id="${_BOXA_FORGE_RESOLVED_IDENTITY_ID:-none}"
        old_forge_gate="$_BOXA_FORGE_GATE"
        _boxa::resolve_ssh_gate "$project_path"
        old_gate="$_BOXA_SSH_GATE"
        _boxa::forge_assign_identity "$identity_id" "$project_path" false \
            || return 1
        _boxa::resolve_forge_identity "$project_path" || return 1
        new_identity_id="${_BOXA_FORGE_RESOLVED_IDENTITY_ID:-none}"
        new_forge_gate="$_BOXA_FORGE_GATE"
        _boxa::resolve_ssh_gate "$project_path"
        new_gate="$_BOXA_SSH_GATE"
        recreation_hint=
        if [ "$old_identity_id" != "$new_identity_id" ] \
                || [ "$old_forge_gate" != "$new_forge_gate" ]; then
            recreation_hint='forge environment changed'
        fi
        if [ "$old_gate" != "$new_gate" ]; then
            recreation_hint+="${recreation_hint:+; }SSH forwarding $old_gate -> $new_gate"
        fi
        printf -v summary_line '  %s: %s -> %s' "$project_path" \
            "$old_identity_id" "$new_identity_id"
        if [ "$new_identity_id" = none ]; then
            summary_line+="; no persona SSH keys will be forwarded into this project's ssh-agent (gate off)"
        elif [ "$new_gate" = on ]; then
            summary_line+="; its SSH keys will be forwarded into this project's ssh-agent (gate on)"
        else
            summary_line+="; its SSH keys will not be forwarded into this project's ssh-agent (gate off)"
        fi
        [ -z "$recreation_hint" ] \
            || summary_line+=" [container recreation needed: $recreation_hint]"
        summary_lines+=("$summary_line")
    done <<< "$projects"

    printf 'Persona assignment summary:\n'
    printf '%s\n' "${summary_lines[@]}"
}

_boxa::forge_projects_resolving_through_default() {
    local project_path
    local -A seen=()

    while IFS= read -r project_path; do
        [ -n "$project_path" ] || continue
        [ -z "${seen[$project_path]:-}" ] || continue
        seen["$project_path"]=1
        _boxa::resolve_forge_gate "$project_path"
        [ -n "$_BOXA_FORGE_CONF_VALID" ] || return 1
        [ -n "$_BOXA_FORGE_PROJECT_IDENTITY" ] || printf '%s\n' "$project_path"
    done < <(_boxa::forge_known_project_paths)
}

_boxa::forge_recompute_default_projects() {
    local project_path projects

    projects="$(_boxa::forge_projects_resolving_through_default)" \
        || return 1
    while IFS= read -r project_path; do
        [ -n "$project_path" ] || continue
        _boxa::forge_apply_project_ssh_gate "$project_path" true || return 1
    done <<< "$projects"
}

_boxa::forge_default_locked() {
    local identity_id="$1"

    _boxa::forge_require_identity "$identity_id" || return 1
    _boxa::write_forge_conf_locked global '' "$identity_id" identity \
        || return 1
    printf "Default persona set to '%s'.\n" "$identity_id"
    _boxa::forge_recompute_default_projects
}

_boxa::forge_default() {
    _boxa::forge_with_catalog_lock _boxa::forge_default_locked "$@"
}

# Materialize an existing default for a Project first seen after the default
# was selected. Explicit Project assignments and an explicit SSH off remain
# whole; an explicit on still needs the inherited persona bundle materialized.
_boxa::forge_apply_default_persona_to_project_locked() {
    local project_path="$1"
    local registered_keys='' key_path

    _boxa::resolve_forge_identity "$project_path" || return 1
    [ -n "$_BOXA_FORGE_GLOBAL_IDENTITY" ] \
        && [ -z "$_BOXA_FORGE_PROJECT_IDENTITY" ] || return 0
    _boxa::resolve_ssh_gate "$project_path"
    [ "$_BOXA_SSH_SOURCE" != project ] \
        || [ "$_BOXA_SSH_GATE" != off ] || return 0
    if [ "$_BOXA_SSH_SOURCE" = project ]; then
        _boxa::forge_compute_project_ssh_gate "$project_path" || return 1
        if [ "$_BOXA_SSH_GATE" = "$_BOXA_FORGE_SYNTHESIZED_SSH_GATE" ]; then
            _boxa::forge_load_persona "$_BOXA_FORGE_RESOLVED_IDENTITY_ID" \
                || return 1
            _boxa::ssh_registry_load_project "$project_path" || return 1
            for key_path in "${_BOXA_SSH_REGISTRY_KEYS[@]}"; do
                registered_keys+="${registered_keys:+$'\n'}$key_path"
            done
            [ "$registered_keys" != "$_BOXA_FORGE_PERSONA_KEYS" ] || return 0
        fi
    fi
    _boxa::forge_apply_project_ssh_gate "$project_path"
}

_boxa::forge_apply_default_persona_to_project() {
    _boxa::forge_with_catalog_lock \
        _boxa::forge_apply_default_persona_to_project_locked "$@"
}

_boxa::forge_find_identity_usages() {
    local identity_id="$1"
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local line parsed section
    local -A seen_sections=()

    _BOXA_FORGE_IDENTITY_DEFAULT=
    _BOXA_FORGE_IDENTITY_PROJECTS=()
    _boxa::resolve_forge_gate ""
    if [ -z "$_BOXA_FORGE_CONF_VALID" ]; then
        printf 'Cannot inspect persona usage: invalid config: %s\n' \
            "$conf" >&2
        return 1
    fi
    [ "$_BOXA_FORGE_GLOBAL_IDENTITY" != "$identity_id" ] \
        || _BOXA_FORGE_IDENTITY_DEFAULT=persona
    [ -f "$conf" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        parsed="${line%%#*}"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"
        [[ "$parsed" == \[*\] ]] || continue
        section="${parsed:1:${#parsed}-2}"
        [[ "$section" == /* ]] || continue
        [ -z "${seen_sections[$section]:-}" ] || continue
        seen_sections["$section"]=1
        _boxa::resolve_forge_gate "$section"
        [ "$_BOXA_FORGE_PROJECT_IDENTITY" = "$identity_id" ] || continue
        _BOXA_FORGE_IDENTITY_PROJECTS+=("$section")
    done < "$conf"
}

_boxa::forge_recompute_identity_projects() {
    local identity_id="$1" project_path projects default_projects
    local -A seen_projects=()

    _boxa::forge_find_identity_usages "$identity_id" || return 1
    projects="$(printf '%s\n' \
        "${_BOXA_FORGE_IDENTITY_PROJECTS[@]}")"
    if [ -n "$_BOXA_FORGE_IDENTITY_DEFAULT" ]; then
        default_projects="$(_boxa::forge_projects_resolving_through_default)" \
            || return 1
        projects+="${projects:+$'\n'}$default_projects"
    fi
    while IFS= read -r project_path; do
        [ -n "$project_path" ] || continue
        [ -z "${seen_projects[$project_path]:-}" ] || continue
        seen_projects["$project_path"]=1
        _boxa::forge_apply_project_ssh_gate "$project_path" true || return 1
    done <<< "$projects"
}

_boxa::forge_report_identity_usages() {
    local project_path

    [ -z "$_BOXA_FORGE_IDENTITY_DEFAULT" ] \
        || printf '  Default: %s\n' "$_BOXA_FORGE_IDENTITY_DEFAULT" >&2
    for project_path in "${_BOXA_FORGE_IDENTITY_PROJECTS[@]}"; do
        printf '  Project: %s\n' "$project_path" >&2
    done
}

_boxa::forge_scrub_identity_references_locked() {
    local identity_id="$1"
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local input output project_path mode file_had_newline=''

    [ -f "$conf" ] || return 0
    if [ -s "$conf" ] \
        && [ "$(tail -c 1 "$conf" | wc -l | tr -d ' ')" -gt 0 ]; then
        file_had_newline=1
    fi
    input="$conf"

    if [ -n "$_BOXA_FORGE_IDENTITY_DEFAULT" ]; then
        output="$(mktemp "${conf}.tmp.XXXXXX")" || return 1
        if ! _boxa::remove_conf_keys global '' "$input" "$output" identity; then
            rm -f "$output"
            return 1
        fi
        input="$output"
    fi
    for project_path in "${_BOXA_FORGE_IDENTITY_PROJECTS[@]}"; do
        output="$(mktemp "${conf}.tmp.XXXXXX")" || {
            [ "$input" = "$conf" ] || rm -f "$input"
            return 1
        }
        if ! _boxa::remove_conf_keys project "$project_path" "$input" \
                "$output" identity; then
            rm -f "$output"
            [ "$input" = "$conf" ] || rm -f "$input"
            return 1
        fi
        [ "$input" = "$conf" ] || rm -f "$input"
        input="$output"
    done
    [ "$input" != "$conf" ] || return 0
    [ -z "$file_had_newline" ] || printf '\n' >> "$input"
    mode="$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf")"
    if ! chmod "$mode" "$input" || ! mv "$input" "$conf"; then
        rm -f "$input"
        return 1
    fi
}

_boxa::forge_known_project_paths() {
    local conf line parsed section name project_path

    for conf in "${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}" \
            "${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"; do
        [ -f "$conf" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            parsed="${line%%#*}"
            parsed="${parsed#"${parsed%%[![:space:]]*}"}"
            parsed="${parsed%"${parsed##*[![:space:]]}"}"
            [[ "$parsed" == \[*\] ]] || continue
            section="${parsed:1:${#parsed}-2}"
            [[ "$section" == /* ]] && printf '%s\n' "$section"
        done < "$conf"
    done
    if declare -F _boxa::forge_project_targets >/dev/null; then
        while IFS=$'\t' read -r name project_path; do
            [ -n "$name" ] || continue
            [[ "$project_path" == /* ]] && printf '%s\n' "$project_path"
        done < <(_boxa::forge_project_targets)
    fi
}

_boxa::forge_remove_locked() {
    local identity_id="$1" force="$2" project_path
    local -a affected_projects=()
    local -A seen_projects=()

    _boxa::forge_require_identity "$identity_id" || return 1
    _boxa::forge_find_identity_usages "$identity_id" || return 1
    if { [ -n "$_BOXA_FORGE_IDENTITY_DEFAULT" ] \
            || [ "${#_BOXA_FORGE_IDENTITY_PROJECTS[@]}" -gt 0 ]; } \
            && [ "$force" != true ]; then
        printf "Cannot remove persona '%s'; it is in use:\n" \
            "$identity_id" >&2
        _boxa::forge_report_identity_usages
        printf "Run 'boxa forge remove %s --force' to remove it and clean these assignments.\n" \
            "$identity_id" >&2
        return 1
    fi
    if [ "$force" = true ]; then
        for project_path in "${_BOXA_FORGE_IDENTITY_PROJECTS[@]}"; do
            seen_projects["$project_path"]=1
            affected_projects+=("$project_path")
        done
        if [ -n "$_BOXA_FORGE_IDENTITY_DEFAULT" ]; then
            while IFS= read -r project_path; do
                [ -n "$project_path" ] || continue
                [ -z "${seen_projects[$project_path]:-}" ] || continue
                seen_projects["$project_path"]=1
                affected_projects+=("$project_path")
            done < <(_boxa::forge_known_project_paths)
        fi
        _boxa::forge_scrub_identity_references_locked "$identity_id" || return 1
        for project_path in "${affected_projects[@]}"; do
            if ! _boxa::forge_apply_project_ssh_gate "$project_path" true; then
                printf "Forge references were removed, but SSH forwarding was not recomputed for %s. Re-run 'boxa forge use'.\n" \
                    "$project_path" >&2
                return 1
            fi
        done
    fi
    _boxa::forge_remove_persona_files "$identity_id" || return 1
    printf "Persona '%s' removed.\n" "$identity_id"
}

_boxa::forge_remove() {
    local identity_id="$1" force="${2:-false}"

    case "$force" in
        true|false) ;;
        *) return 1 ;;
    esac
    _boxa::forge_with_catalog_lock _boxa::forge_remove_locked \
        "$identity_id" "$force"
}

_boxa::forge_token_expiry_heads_up() {
    local project_path="$1" forge display_name token_age days_remaining

    _boxa::resolve_forge_gate "$project_path"
    [ "$_BOXA_FORGE_GATE" = on ] || return 0
    for forge in github gitlab; do
        _boxa::resolve_forge_identity "$project_path" "$forge"
        [ -n "$_BOXA_FORGE_RESOLVED_IDENTITY_ID" ] || continue
        _boxa::forge_load_identity "$_BOXA_FORGE_RESOLVED_IDENTITY_ID" "$forge" \
            || continue
        case "$forge" in github) display_name=GitHub ;; gitlab) display_name=GitLab ;; esac
        if token_age="$(_boxa::forge_token_age_days \
                "$_BOXA_FORGE_CREATED_AT")"; then
            days_remaining=$((BOXA_FORGE_TOKEN_LIFETIME_DAYS - token_age))
            if [ "$days_remaining" -le 0 ]; then
                printf '\033[1;33m==> %s forge token is expired. Rotate it with '\''boxa forge set %s'\''.\033[0m\n' \
                    "$display_name" "$forge" >&2
            elif [ "$days_remaining" -le "$BOXA_FORGE_EXPIRY_WARN_DAYS" ]; then
                printf '\033[1;33m==> %s forge token expires within %s day(s). Rotate it with '\''boxa forge set %s'\''.\033[0m\n' \
                    "$display_name" "$days_remaining" "$forge" >&2
            fi
        fi
    done
}

_boxa::forge_ssh_gate_divergence_warnings() {
    local project_path="$1" forge display_name

    _boxa::resolve_ssh_gate "$project_path"
    for forge in github gitlab; do
        _boxa::resolve_forge_identity "$project_path" "$forge"
        [ -n "$_BOXA_FORGE_RESOLVED_IDENTITY_ID" ] || continue
        _boxa::forge_load_identity "$_BOXA_FORGE_RESOLVED_IDENTITY_ID" "$forge" \
            || continue
        [ "$_BOXA_FORGE_IDENTITY_AUTH" != token ] || continue
        if [ "$_BOXA_SSH_GATE" != on ]; then
            case "$forge" in
                github) display_name=GitHub ;;
                gitlab) display_name=GitLab ;;
            esac
            printf 'WARNING: The assigned persona has an SSH key for %s, but the effective SSH gate is off.\n' \
                "$display_name"
        fi
    done
}

_boxa::forge_status() {
    local project_path="$1"
    local conf="${BOXA_FORGE_CONF:-$HOME/.config/boxa/forge.conf}"
    local forge display_name age ssh_username gitlab_host='' persona
    local configured=()

    _boxa::resolve_forge_gate "$project_path"
    printf 'Forge access: %s\n' "$_BOXA_FORGE_GATE"
    case "$_BOXA_FORGE_SOURCE" in
        default) printf 'Source: default (off)\n' ;;
        invalid) printf 'Source: invalid config (off)\n' ;;
        global) printf 'Source: global config\n' ;;
        project) printf 'Source: project config [%s]\n' "$project_path" ;;
    esac
    printf 'Config: %s\n' "$conf"
    printf 'Default persona: %s\n' \
        "${_BOXA_FORGE_GLOBAL_IDENTITY:-not set}"
    printf 'Project persona assignment: %s\n' \
        "${_BOXA_FORGE_PROJECT_IDENTITY:-not set}"
    persona="${_BOXA_FORGE_PROJECT_IDENTITY:-$_BOXA_FORGE_GLOBAL_IDENTITY}"
    [ "$persona" != none ] || persona=''
    printf 'Resolved persona: %s\n' "${persona:-none}"

    if declare -F _boxa::resolve_ssh_gate >/dev/null; then
        _boxa::forge_ssh_gate_divergence_warnings "$project_path"
        _boxa::resolve_ssh_gate "$project_path"
        printf 'SSH forwarding: %s\n' "$_BOXA_SSH_GATE"
        _boxa::resolve_forge_gate "$project_path"
    fi

    for forge in github gitlab; do
        if _boxa::forge_load_status_credential "$project_path" "$forge"; then
            configured+=("$forge")
        fi
    done
    if [ "${#configured[@]}" -eq 0 ]; then
        printf 'Configured forges: none\n'
    elif [ "${#configured[@]}" -eq 2 ]; then
        printf 'Configured forges: %s, %s\n' "${configured[0]}" "${configured[1]}"
    else
        printf 'Configured forges: %s\n' "${configured[0]}"
    fi
    for forge in "${configured[@]}"; do
        _boxa::forge_load_status_credential "$project_path" "$forge" || continue
        case "$forge" in
            github) display_name=GitHub ;;
            gitlab) display_name=GitLab ;;
        esac
        if age="$(_boxa::forge_token_age_days "$_BOXA_FORGE_CREATED_AT")"; then
            printf '%s token age: %s day(s)\n' "$display_name" "$age"
        else
            printf '%s token age: unknown\n' "$display_name"
        fi
        printf '%s token: %s\n' "$display_name" \
            "$(_boxa::forge_mask_token "$_BOXA_FORGE_TOKEN")"
        [ -z "$_BOXA_FORGE_USERNAME" ] \
            || printf '%s username: %s\n' "$display_name" "$_BOXA_FORGE_USERNAME"
        [ "$forge" != gitlab ] || printf 'GitLab host: %s\n' "$_BOXA_FORGE_HOST"
    done

    if _boxa::ssh_agent_key_exists; then
        if ssh_username="$(_boxa::forge_ssh_probe_username github.com \
                2>/dev/null)"; then
            printf 'GitHub SSH key authenticates as: %s\n' "$ssh_username"
        else
            printf 'GitHub SSH key: not verified (key not attached, or host unreachable)\n'
        fi
        if _boxa::forge_load_status_credential "$project_path" gitlab; then
            gitlab_host="$_BOXA_FORGE_HOST"
        fi
        if [ -n "$gitlab_host" ]; then
            if ssh_username="$(_boxa::forge_ssh_probe_username "$gitlab_host" \
                    2>/dev/null)"; then
                printf 'GitLab SSH key authenticates as: %s\n' "$ssh_username"
            else
                printf 'GitLab SSH key: not verified (key not attached, or host unreachable)\n'
            fi
        fi
    fi
}

_boxa::forge_dashboard_persona_picker() {
    local question="$1" store path identity_id picked
    local -a paths=() personas=()

    store="$(_boxa::forge_identity_store_dir)"
    if [ -d "$store" ]; then
        paths=("$store"/*)
    fi
    for path in "${paths[@]}"; do
        [ -f "$path" ] || continue
        identity_id="${path##*/}"
        _boxa::forge_load_persona "$identity_id" || continue
        personas+=("$identity_id")
    done
    [ "${#personas[@]}" -gt 0 ] || return 1
    picked="$(printf '%s\n' "${personas[@]}" | picker::one \
        --prompt 'Persona:' \
        --header "Forge dashboard — choose the credential bundle to change."$'\n'"Question: $question")" \
        || return 1
    _boxa::forge_require_identity "$picked" || return 1
    printf '%s\n' "$picked"
}

_boxa::forge_dashboard_probe_label() {
    local forge="$1" token="$2" host="$3" username

    if _boxa::forge_has_tty && ! _boxa::forge_require_probe_cli "$forge"; then
        printf 'live probe unavailable\n'
        return
    fi
    if username="$(_boxa::forge_probe "$forge" "$token" "$host")"; then
        printf 'live as %s\n' "$username"
    else
        printf 'live probe unavailable\n'
    fi
}

_boxa::forge_dashboard_personas() {
    local store path identity_id kind_label fingerprints age probe forges
    local valid_count=0
    local -a paths=()

    store="$(_boxa::forge_identity_store_dir)"
    if [ -d "$store" ]; then
        paths=("$store"/*)
    fi
    for path in "${paths[@]}"; do
        [ -e "$path" ] || continue
        identity_id="${path##*/}"
        if [ ! -f "$path" ] || ! _boxa::forge_load_persona "$identity_id"; then
            printf '  MISSING: invalid persona file %s\n' "$identity_id"
            continue
        fi
        case "$_BOXA_FORGE_IDENTITY_KIND" in
            mine) kind_label=Mine ;;
            agent) kind_label=Agent ;;
            other) kind_label=Other ;;
        esac
        fingerprints="$(_boxa::forge_persona_key_fingerprints \
            "$_BOXA_FORGE_PERSONA_KEYS")"
        forges=
        [ -z "$_BOXA_FORGE_GITHUB_TOKEN" ] || forges=GitHub
        [ -z "$_BOXA_FORGE_GITLAB_TOKEN" ] \
            || forges+="${forges:+, }GitLab"
        printf '  %s | kind: %s | configured forges: %s | SSH fingerprints: %s\n' \
            "$identity_id" "$kind_label" "${forges:-none}" "$fingerprints"
        if [ -n "$_BOXA_FORGE_GITHUB_TOKEN" ]; then
            age="$(_boxa::forge_token_age_days \
                "$_BOXA_FORGE_GITHUB_CREATED_AT" 2>/dev/null || printf unknown)"
            probe="$(_boxa::forge_dashboard_probe_label github \
                "$_BOXA_FORGE_GITHUB_TOKEN" '')"
            printf '    GitHub | token: %s | token age: %s day(s) | %s\n' \
                "$(_boxa::forge_mask_token "$_BOXA_FORGE_GITHUB_TOKEN")" \
                "$age" "$probe"
        fi
        if [ -n "$_BOXA_FORGE_GITLAB_TOKEN" ]; then
            age="$(_boxa::forge_token_age_days \
                "$_BOXA_FORGE_GITLAB_CREATED_AT" 2>/dev/null || printf unknown)"
            probe="$(_boxa::forge_dashboard_probe_label gitlab \
                "$_BOXA_FORGE_GITLAB_TOKEN" "$_BOXA_FORGE_GITLAB_HOST")"
            printf '    GitLab (%s) | token: %s | token age: %s day(s) | %s\n' \
                "$_BOXA_FORGE_GITLAB_HOST" \
                "$(_boxa::forge_mask_token "$_BOXA_FORGE_GITLAB_TOKEN")" \
                "$age" "$probe"
        fi
        [ -n "$forges" ] \
            || printf '    MISSING: no forge token; CLI and API access are unavailable.\n'
        valid_count=$((valid_count + 1))
    done
    if [ "$valid_count" -eq 0 ]; then
        printf '  MISSING: no personas configured.\n'
    fi
    _BOXA_FORGE_DASHBOARD_PERSONA_COUNT="$valid_count"
}

_boxa::forge_dashboard_projects() {
    local current_project="$1" known_projects project_path persona gate
    local forge_gate keys gate_label missing_projects project_list=''
    local -A seen=()

    _BOXA_FORGE_DASHBOARD_PROJECTS=()
    _BOXA_FORGE_DASHBOARD_HAS_LEGACY=
    _BOXA_FORGE_DASHBOARD_MISSING_SSH_PROJECTS=()
    known_projects="$(printf '%s\n' "$current_project"; \
        _boxa::forge_known_project_paths)"
    while IFS= read -r project_path; do
        [[ "$project_path" == /* ]] || continue
        [ -z "${seen[$project_path]:-}" ] || continue
        seen["$project_path"]=1
        _BOXA_FORGE_DASHBOARD_PROJECTS+=("$project_path")
        _boxa::resolve_forge_identity "$project_path" || continue
        persona="${_BOXA_FORGE_RESOLVED_IDENTITY_ID:-none}"
        forge_gate="$_BOXA_FORGE_GATE"
        _boxa::resolve_ssh_gate "$project_path"
        [ -z "$_BOXA_SSH_HAS_LEGACY" ] \
            || _BOXA_FORGE_DASHBOARD_HAS_LEGACY=1
        gate="$_BOXA_SSH_GATE"
        gate_label="$gate"
        if [ -n "$_BOXA_SSH_LEGACY" ]; then
            gate_label+=' (legacy)'
        fi
        printf '  %s | persona: %s | forge gate: %s | SSH gate: %s\n' \
            "$project_path" "$persona" "$forge_gate" "$gate_label"
        if [ "$persona" = none ]; then
            [ "$gate" != on ] \
                || _BOXA_FORGE_DASHBOARD_MISSING_SSH_PROJECTS+=("$project_path")
            continue
        fi
        if ! _boxa::forge_load_persona "$persona"; then
            printf '    MISSING: assigned persona does not exist or is invalid.\n'
            continue
        fi
        keys="$_BOXA_FORGE_PERSONA_KEYS"
        if [ -z "$_BOXA_FORGE_GITHUB_TOKEN$_BOXA_FORGE_GITLAB_TOKEN" ]; then
            printf '    MISSING: assignment has no forge token.\n'
        fi
        if [ "$gate" = on ] && [ -z "$keys" ]; then
            printf '    MISSING: SSH gate is on but the assigned persona has no keys.\n'
        fi
    done <<< "$known_projects"
    for missing_projects in "${_BOXA_FORGE_DASHBOARD_MISSING_SSH_PROJECTS[@]}"; do
        project_list+="${project_list:+, }$missing_projects"
    done
    [ -z "$project_list" ] \
        || printf '  MISSING: SSH gate is on without an assigned persona or keys for Projects: %s.\n' \
            "$project_list"
}

_boxa::forge_dashboard_render() {
    local current_project="$1"

    _boxa::resolve_forge_gate "$current_project"
    printf '\n=== Forge dashboard ===\n'
    printf 'Default persona: %s\n' "${_BOXA_FORGE_GLOBAL_IDENTITY:-not set}"
    printf 'Personas (live credential probes and local key fingerprints):\n'
    _boxa::forge_dashboard_personas
    printf 'Projects (assignment and effective SSH gate):\n'
    _boxa::forge_dashboard_projects "$current_project"
}

_boxa::forge_dashboard_attach_key() {
    local identity_id

    identity_id="$(_boxa::forge_dashboard_persona_picker \
        'Which persona should receive an SSH key?')" || return 1
    _boxa::forge_keys "$identity_id"
}

_boxa::forge_dashboard_remove_persona() {
    local identity_id

    identity_id="$(_boxa::forge_dashboard_persona_picker \
        'Which persona should be removed?')" || return 1
    _boxa::forge_remove "$identity_id"
}

_boxa::forge_dashboard_rotate_token_locked() {
    local identity_id="$1" forge="$2" token username host created_at
    local kind keys github_token github_username github_created_at
    local gitlab_token gitlab_username gitlab_host gitlab_created_at
    local action operation

    _boxa::forge_load_persona "$identity_id" || return 1
    kind="$_BOXA_FORGE_IDENTITY_KIND"
    keys="$_BOXA_FORGE_PERSONA_KEYS"
    github_token="$_BOXA_FORGE_GITHUB_TOKEN"
    github_username="$_BOXA_FORGE_GITHUB_USERNAME"
    github_created_at="$_BOXA_FORGE_GITHUB_CREATED_AT"
    gitlab_token="$_BOXA_FORGE_GITLAB_TOKEN"
    gitlab_username="$_BOXA_FORGE_GITLAB_USERNAME"
    gitlab_host="$_BOXA_FORGE_GITLAB_HOST"
    gitlab_created_at="$_BOXA_FORGE_GITLAB_CREATED_AT"
    case "$forge" in
        github)
            if [ -n "$github_token" ]; then
                action=rotated
                operation=Rotating
            else
                action=configured
                operation=Adding
            fi
            ;;
        gitlab)
            if [ -n "$gitlab_token" ]; then
                action=rotated
                operation=Rotating
            else
                action=configured
                operation=Adding
            fi
            ;;
        *) return 1 ;;
    esac
    host="$gitlab_host"
    if [ "$forge" = gitlab ] && [ -z "$host" ]; then
        host="$(_boxa::forge_read_gitlab_host)" || return 1
    fi
    _boxa::forge_require_probe_cli "$forge" || return 1
    printf '%s the %s token for persona %s; the token enables CLI, API, and review operations.\n' \
        "$operation" "$forge" "$identity_id"
    _boxa::forge_token_mint_guidance "$forge" "$host" "$kind"
    printf 'Paste %s token: ' "$forge" >/dev/tty
    IFS= read -r -s token </dev/tty || { printf '\n' >/dev/tty; return 1; }
    printf '\n' >/dev/tty
    if [ -z "$token" ] \
            || [[ "$token" == *$'\r'* || "$token" == *$'\n'* ]]; then
        printf 'Token must be a non-empty single line.\n' >&2
        return 1
    fi
    username="$(_boxa::forge_probe "$forge" "$token" "$host")" || {
        if [ "$action" = rotated ]; then
            printf '%s token verification failed; the existing token is unchanged.\n' \
                "$forge" >&2
        else
            printf '%s token verification failed; no token was added to persona %s.\n' \
                "$forge" "$identity_id" >&2
        fi
        return 1
    }
    created_at="$(date +%s)"
    case "$forge" in
        github)
            github_token="$token"
            github_username="$username"
            github_created_at="$created_at"
            ;;
        gitlab)
            gitlab_token="$token"
            gitlab_username="$username"
            gitlab_host="$host"
            gitlab_created_at="$created_at"
            ;;
        *) return 1 ;;
    esac
    _boxa::forge_write_persona "$identity_id" "$kind" "$keys" \
        "$github_token" "$github_username" "$github_created_at" \
        "$gitlab_token" "$gitlab_username" "$gitlab_host" \
        "$gitlab_created_at" true || return 1
    printf '%s token %s for persona %s; authenticated as %s.\n' \
        "$forge" "$action" "$identity_id" "$username"
}

_boxa::forge_dashboard_rotate_token() {
    local identity_id forge selected
    local github gitlab

    identity_id="$(_boxa::forge_dashboard_persona_picker \
        'Which persona needs a token added or rotated?')" || return 1
    _boxa::forge_load_persona "$identity_id" || return 1
    if [ -z "$_BOXA_FORGE_GITHUB_TOKEN$_BOXA_FORGE_GITLAB_TOKEN" ]; then
        printf "Persona '%s' has no token to rotate; add a persona with a verified token.\n" \
            "$identity_id" >&2
        return 1
    fi
    if [ -n "$_BOXA_FORGE_GITHUB_TOKEN" ]; then
        github='GitHub — rotate the existing token'
    else
        github='GitHub — add a token'
    fi
    if [ -n "$_BOXA_FORGE_GITLAB_TOKEN" ]; then
        gitlab='GitLab — rotate the existing token'
    else
        gitlab='GitLab — add a token'
    fi
    selected="$(printf '%s\n' "$github" "$gitlab" | picker::one \
        --prompt 'Add or rotate token:' \
        --header "Forge dashboard — add or rotate one verified token for persona '$identity_id'."$'\n''Question: Which forge token should be configured?')" \
        || return 1
    case "$selected" in "$github") forge=github ;; "$gitlab") forge=gitlab ;; esac
    _boxa::forge_with_catalog_lock _boxa::forge_dashboard_rotate_token_locked \
        "$identity_id" "$forge"
}

_boxa::forge_dashboard_set_default() {
    local identity_id

    identity_id="$(_boxa::forge_dashboard_persona_picker \
        'Which persona should be the default?')" || return 1
    _boxa::forge_default "$identity_id"
}

_boxa::forge_dashboard_migrate_legacy_ssh_gates_locked() {
    local conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local registry project_path global_legacy='' global_has_legacy=''
    local global_gate='' global_write_gate='' ssh_backup='' ssh_existed=''
    local registry_backup='' registry_existed='' key_path i=0 status=0
    local -a projects=("${_BOXA_FORGE_DASHBOARD_PROJECTS[@]}")
    local -a write_projects=() gates=() modes=()

    for project_path in "${projects[@]}"; do
        _boxa::resolve_ssh_gate "$project_path"
        if [ -n "$_BOXA_SSH_PROJECT_HAS_LEGACY" ]; then
            write_projects+=("$project_path")
        elif [ "$_BOXA_SSH_SOURCE" = global ] \
                && [ -n "$_BOXA_SSH_LEGACY" ]; then
            write_projects+=("$project_path")
        else
            continue
        fi
        gates+=("$_BOXA_SSH_GATE")
        modes+=("$_BOXA_SSH_LEGACY_MODE")
    done
    _boxa::resolve_ssh_gate ""
    global_legacy="$_BOXA_SSH_LEGACY"
    global_has_legacy="$_BOXA_SSH_GLOBAL_HAS_LEGACY"
    global_gate="$_BOXA_SSH_GATE"
    global_write_gate="$global_gate"
    [ -z "$global_legacy" ] || global_write_gate=off
    registry="$(_boxa::ssh_key_registry_path)"
    _boxa::forge_backup_file "$conf" ssh_backup ssh_existed || return 1
    if ! _boxa::forge_backup_file "$registry" registry_backup \
            registry_existed; then
        _boxa::forge_discard_backup "$ssh_backup"
        return 1
    fi
    if { [ -z "$global_has_legacy" ] \
            || _boxa::write_ssh_conf global '' "$global_write_gate"; } \
            && for ((i = 0; i < ${#write_projects[@]}; i++)); do
                if [ "${modes[$i]}" = agent ]; then
                    key_path="$(_boxa::ssh_agent_key_path)"
                    _boxa::ssh_registry_replace_project \
                        "${write_projects[$i]}" "$key_path" || break
                fi
                _boxa::write_ssh_conf project "${write_projects[$i]}" \
                    "${gates[$i]}" || break
            done \
            && [ "$i" -eq "${#write_projects[@]}" ]; then
        _boxa::forge_discard_backup "$ssh_backup"
        _boxa::forge_discard_backup "$registry_backup"
    else
        status=1
        _boxa::forge_restore_file "$conf" "$ssh_backup" "$ssh_existed" \
            || true
        _boxa::forge_restore_file "$registry" "$registry_backup" \
            "$registry_existed" || true
        printf 'Legacy SSH gate migration failed; config was restored.\n' >&2
    fi
    [ "$status" -eq 0 ] || return 1
    printf 'Migrated legacy SSH gate config to explicit values for %s Project(s).\n' \
        "${#write_projects[@]}"
}

_boxa::forge_dashboard_migrate_legacy_ssh_gates() {
    local decline_mode="${1:-cancel}" project_path answer='' marker

    [ -n "$_BOXA_FORGE_DASHBOARD_HAS_LEGACY" ] || return 0
    printf 'Legacy SSH gate migration will write these explicit per-Project values:\n'
    for project_path in "${_BOXA_FORGE_DASHBOARD_PROJECTS[@]}"; do
        _boxa::resolve_ssh_gate "$project_path"
        if [ -n "$_BOXA_SSH_PROJECT_HAS_LEGACY" ] || {
                { [ "$_BOXA_SSH_SOURCE" = project ] \
                    || [ "$_BOXA_SSH_SOURCE" = global ]; } \
                    && [ -n "$_BOXA_SSH_LEGACY" ]
            }; then
            printf '  %s: %s\n' "$project_path" "$_BOXA_SSH_GATE"
        fi
    done
    printf 'Migrate legacy SSH gates now? [y/N] ' >/dev/tty
    IFS= read -r answer </dev/tty || answer=
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            if [ "$decline_mode" = remember ]; then
                _boxa::forge_record_legacy_ssh_gate_migration_decline || {
                    printf 'Could not record the legacy SSH gate migration decline.\n' >&2
                    return 1
                }
                printf 'Legacy SSH gate migration declined; config unchanged.\n'
                return 0
            fi
            printf 'Legacy SSH gate migration cancelled; config unchanged.\n'
            return 0
            ;;
    esac
    if _boxa::ssh_with_registry_lock \
            _boxa::forge_dashboard_migrate_legacy_ssh_gates_locked; then
        _BOXA_FORGE_DASHBOARD_HAS_LEGACY=
        marker="$(_boxa::forge_legacy_ssh_gate_migration_declined_path)"
        rm -f -- "$marker" \
            || printf 'Could not clear the legacy SSH gate migration decline marker.\n' >&2
    else
        return $?
    fi
}

_boxa::forge_dashboard_prompt_legacy_ssh_gate_migration() {
    local marker

    [ -n "$_BOXA_FORGE_DASHBOARD_HAS_LEGACY" ] || return 0
    marker="$(_boxa::forge_legacy_ssh_gate_migration_declined_path)"
    [ -e "$marker" ] && return 0
    _boxa::forge_dashboard_migrate_legacy_ssh_gates remember
}

_boxa::forge_dashboard() {
    local current_project="$1" preferred_forge="${2:-}" mode="${3:-interactive}"
    local action add='Add a persona' assign='Assign a persona to Projects'
    local set_default='Set the default persona' attach='Attach an SSH key'
    local rotate='Add or rotate a token' remove='Remove a persona'
    local migrate='Migrate legacy SSH gates' done='Done'
    local -a actions=()

    printf 'Forge dashboard configures who a Project acts as: tokens enable forge CLI/API operations, while attached SSH keys enable git transport through the per-Project gate.\n'
    _boxa::forge_migrate_legacy_credentials || return 1
    _boxa::forge_dashboard_render "$current_project"
    if [ "$mode" != interactive ] || ! _boxa::forge_has_tty; then
        printf '\nForge dashboard complete. Assigned personas provide their configured forge CLI/API access, and Projects with attached keys and an on SSH gate provide git push/pull.\n'
        return
    fi
    _boxa::forge_dashboard_prompt_legacy_ssh_gate_migration || return 1
    if [ "$_BOXA_FORGE_DASHBOARD_PERSONA_COUNT" -eq 0 ]; then
        printf '\nNo persona exists yet; starting the shared add-persona checklist.\n'
        _boxa::forge_add "$preferred_forge" || return 1
        preferred_forge=
    fi
    while :; do
        actions=("$add" "$assign" "$set_default" "$attach" "$rotate" "$remove")
        [ -z "$_BOXA_FORGE_DASHBOARD_HAS_LEGACY" ] || actions+=("$migrate")
        actions+=("$done")
        action="$(printf '%s\n' "${actions[@]}" | picker::one --prompt 'Forge action:' \
            --header 'Forge dashboard — actions report compact state changes below.'$'\n''Question: What should be configured next?')" \
            || break
        case "$action" in
            "$add") _boxa::forge_add "$preferred_forge" || return 1; preferred_forge= ;;
            "$assign") _boxa::forge_use '' "$current_project" || return 1 ;;
            "$set_default") _boxa::forge_dashboard_set_default || return 1 ;;
            "$attach") _boxa::forge_dashboard_attach_key || return 1 ;;
            "$rotate") _boxa::forge_dashboard_rotate_token || return 1 ;;
            "$remove") _boxa::forge_dashboard_remove_persona || return 1 ;;
            "$migrate")
                _boxa::forge_dashboard_migrate_legacy_ssh_gates || return 1
                ;;
            "$done") break ;;
            *) break ;;
        esac
    done
    printf '\nForge dashboard complete. Assigned personas provide their configured forge CLI/API access, and Projects with attached keys and an on SSH gate provide git push/pull.\n'
}
