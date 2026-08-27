#!/bin/bash
# Compose-aware teardown for the rootless Docker daemon inside a Boxa Container.

set -u -o pipefail

declare -A compose_project_ids=() compose_identity_by_project=()
declare -A degraded_project_names=()
declare -a compose_keys=() unmanaged=() degraded=() jobs=()

compose_identity_record() {
    local project_name="$1" working_dir="$2" config_files="$3"
    jq -cn \
        --arg project_name "$project_name" \
        --arg working_dir "$working_dir" \
        --arg config_files "$config_files" \
        '{project_name: $project_name, working_dir: $working_dir, config_files: $config_files}'
}

read_compose_identity() {
    local record="$1"
    mapfile -t compose_identity_fields < <(
        jq -r '.project_name, .working_dir, .config_files' <<< "$record"
    )
    project_name="${compose_identity_fields[0]}"
    working_dir="${compose_identity_fields[1]}"
    config_files="${compose_identity_fields[2]}"
}

warn_degraded() {
    local subject="$1" reason="$2"
    printf "WARNING: %s; using graceful stop and removal without dependency ordering (%s).\n" \
        "$subject" "$reason" >&2
}

stop_and_remove() {
    local -a ids=("$@")
    local id failed=false

    [ "${#ids[@]}" -gt 0 ] || return 0
    docker stop "${ids[@]}" >/dev/null 2>&1 || true
    for id in "${ids[@]}"; do
        if docker rm "$id" >/dev/null 2>&1; then
            continue
        fi
        # Compose down may have removed this record before returning failure.
        # That is a successful fallback outcome, but a record that still
        # exists (or an unreachable daemon) remains a real cleanup failure.
        if docker inspect "$id" >/dev/null 2>&1; then
            failed=true
        elif ! docker info >/dev/null 2>&1; then
            failed=true
        fi
    done
    [ "$failed" = false ]
}

if ! container_output="$(docker ps -aq)"; then
    printf 'ERROR: inner Docker daemon is unreachable; cleanup could not be verified.\n' >&2
    exit 1
fi
container_ids=()
if [ -n "$container_output" ]; then
    mapfile -t container_ids <<< "$container_output"
fi
[ "${#container_ids[@]}" -gt 0 ] || exit 0

for container_id in "${container_ids[@]}"; do
    if ! metadata="$(docker inspect --format \
        '{{.Name}}{{printf "\t"}}{{index .Config.Labels "com.docker.compose.project"}}{{printf "\t"}}{{index .Config.Labels "com.docker.compose.project.working_dir"}}{{printf "\t"}}{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
        "$container_id")"; then
        warn_degraded "Compose identity for inner container '$container_id' is unavailable" \
            'container metadata could not be read'
        degraded+=("$container_id")
        continue
    fi
    IFS=$'\t' read -r container_name project_name working_dir config_files <<< "$metadata"
    container_name="${container_name#/}"

    if [ -z "$project_name" ] || [ "$project_name" = "<no value>" ]; then
        if { [ -n "$working_dir" ] && [ "$working_dir" != "<no value>" ]; } \
            || { [ -n "$config_files" ] && [ "$config_files" != "<no value>" ]; }; then
            warn_degraded "Compose identity for inner container '$container_name' is incomplete" \
                'project name is missing'
            degraded+=("$container_id")
        else
            unmanaged+=("$container_id:$container_name")
        fi
        continue
    fi

    if [ -z "$working_dir" ] || [ "$working_dir" = "<no value>" ] \
        || [ -z "$config_files" ] || [ "$config_files" = "<no value>" ]; then
        warn_degraded "Compose project '$project_name' has incomplete identity metadata" \
            "inner container '$container_name'"
        degraded+=("$container_id")
        degraded_project_names[$project_name]=true
        continue
    fi

    key="$(compose_identity_record "$project_name" "$working_dir" "$config_files")"
    if [ -n "${compose_identity_by_project[$project_name]+present}" ]; then
        if [ "${compose_identity_by_project[$project_name]}" != "$key" ]; then
            degraded_project_names[$project_name]=true
        fi
    else
        compose_identity_by_project[$project_name]="$key"
    fi

    if [ -z "${compose_project_ids[$key]+present}" ]; then
        compose_project_ids[$key]="$container_id"
        compose_keys+=("$key")
    else
        compose_project_ids[$key]+=" $container_id"
    fi
done

for key in "${compose_keys[@]}"; do
    read_compose_identity "$key"
    read -ra project_ids <<< "${compose_project_ids[$key]}"
    printf 'Stopping Compose project: %s\n' "$project_name"
    (
        if [ "${degraded_project_names[$project_name]:-false}" = true ]; then
            warn_degraded "Compose project '$project_name' has inconsistent identity metadata" \
                'containers disagree about the project identity'
            stop_and_remove "${project_ids[@]}"
            exit
        fi
        reason=""
        compose_args=(--project-name "$project_name" --project-directory "$working_dir")
        if [ ! -d "$working_dir" ] || [ ! -r "$working_dir" ] || [ ! -x "$working_dir" ]; then
            reason="working directory '$working_dir' is unusable"
        else
            IFS=',' read -ra project_config_files <<< "$config_files"
            if [ "${#project_config_files[@]}" -eq 0 ]; then
                reason='config-file metadata is empty'
            else
                for config_file in "${project_config_files[@]}"; do
                    resolved_config="$config_file"
                    if [[ "$resolved_config" != /* ]]; then
                        resolved_config="$working_dir/$resolved_config"
                    fi
                    if [ -z "$config_file" ] || [ ! -f "$resolved_config" ] \
                        || [ ! -r "$resolved_config" ]; then
                        reason="config file '$config_file' is unusable"
                        break
                    fi
                    compose_args+=(--file "$config_file")
                done
            fi
        fi

        if [ -z "$reason" ]; then
            if cd "$working_dir" \
                && docker compose "${compose_args[@]}" down --remove-orphans >/dev/null 2>&1; then
                exit 0
            fi
            reason='Compose teardown failed'
        fi

        warn_degraded "Compose project '$project_name' could not use Compose teardown" "$reason"
        stop_and_remove "${project_ids[@]}"
    ) &
    jobs+=("$!")
done

if [ "${#unmanaged[@]}" -gt 0 ]; then
    unmanaged_ids=()
    printf 'Stopping unmanaged inner containers:'
    for unmanaged_container in "${unmanaged[@]}"; do
        unmanaged_ids+=("${unmanaged_container%%:*}")
        printf ' %s' "${unmanaged_container#*:}"
    done
    printf '\n'
    stop_and_remove "${unmanaged_ids[@]}" &
    jobs+=("$!")
fi

if [ "${#degraded[@]}" -gt 0 ]; then
    stop_and_remove "${degraded[@]}" &
    jobs+=("$!")
fi

failed=false
for job in "${jobs[@]}"; do
    wait "$job" || failed=true
done

# Sweep records created concurrently or left by a failed cleanup, then verify.
if ! remaining_output="$(docker ps -aq)"; then
    printf 'ERROR: inner Docker daemon became unreachable during cleanup.\n' >&2
    exit 1
fi
remaining_ids=()
if [ -n "$remaining_output" ]; then
    mapfile -t remaining_ids <<< "$remaining_output"
fi
if [ "${#remaining_ids[@]}" -gt 0 ]; then
    stop_and_remove "${remaining_ids[@]}" || failed=true
fi

if ! remaining_output="$(docker ps -aq)"; then
    printf 'ERROR: inner Docker cleanup could not be verified.\n' >&2
    exit 1
fi
if [ -n "$remaining_output" ]; then
    printf 'ERROR: inner Docker containers remain after shutdown: %s\n' \
        "$(tr '\n' ' ' <<< "$remaining_output" | sed 's/ $//')" >&2
    failed=true
fi

[ "$failed" = false ]
