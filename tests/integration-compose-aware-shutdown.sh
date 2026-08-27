#!/bin/bash
# Opt-in end-to-end proof in a uniquely named disposable Boxa Project.
# Usage: BOXA_COMPOSE_SHUTDOWN_INTEGRATION=1 bash tests/integration-compose-aware-shutdown.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "${BOXA_COMPOSE_SHUTDOWN_INTEGRATION:-}" != 1 ]; then
    printf 'SKIP  integration-compose-aware-shutdown — opt-in gate is not set.\n'
    printf '      Run on the Docker host with BOXA_COMPOSE_SHUTDOWN_INTEGRATION=1.\n'
    exit 0
fi

if [ -f /etc/boxa/identity.json ]; then
    printf "SKIP  integration-compose-aware-shutdown — refusing the caller's inner Docker daemon.\n"
    printf '      Run this test on the Docker host; it creates a disposable Boxa Project.\n'
    exit 0
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    printf 'SKIP  integration-compose-aware-shutdown — no reachable host Docker daemon.\n'
    exit 0
fi

# shellcheck source-path=SCRIPTDIR/.. source=lib/brand.sh disable=SC1091
source "$BOXA_DIR/lib/brand.sh"
# shellcheck source-path=SCRIPTDIR/.. source=lib/naming.sh disable=SC1091
source "$BOXA_DIR/lib/naming.sh"

if ! docker image inspect "$BRAND_IMAGE" >/dev/null 2>&1; then
    printf 'SKIP  integration-compose-aware-shutdown — local Boxa image is missing: %s.\n' \
        "$BRAND_IMAGE"
    printf '      Build the current checkout first with: %s/build.sh\n' "$BOXA_DIR"
    exit 0
fi

source_entrypoint_checksum="$(cksum "$BOXA_DIR/scripts/boxa-entrypoint.sh" \
    | awk '{print $1, $2}')"
source_helper_checksum="$(cksum "$BOXA_DIR/scripts/shutdown-inner-containers.sh" \
    | awk '{print $1, $2}')"
image_entrypoint_checksum="$(docker run --rm --entrypoint cksum "$BRAND_IMAGE" \
    /usr/local/bin/boxa-entrypoint.sh 2>/dev/null | awk '{print $1, $2}')"
image_helper_checksum="$(docker run --rm --entrypoint cksum "$BRAND_IMAGE" \
    /usr/local/bin/boxa-shutdown-inner 2>/dev/null | awk '{print $1, $2}')"
if [ "$image_entrypoint_checksum" != "$source_entrypoint_checksum" ] \
    || [ "$image_helper_checksum" != "$source_helper_checksum" ]; then
    printf 'SKIP  integration-compose-aware-shutdown — local Boxa image is stale.\n'
    printf '      Build this checkout first with: %s/build.sh\n' "$BOXA_DIR"
    exit 0
fi

RUN_ID="shutdown-it-$PPID-$(date +%s)-$RANDOM"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/boxa-$RUN_ID.XXXXXX")"
PROJECT_DIR="$TMPROOT/$RUN_ID"
mkdir -p "$PROJECT_DIR"
PROJECT_NAME="$(boxa::sanitize "$(basename "$PROJECT_DIR")")"
OUTER_CONTAINER="boxa-$PROJECT_NAME"
COMPOSE_PROJECT="shutdown-proof-$RUN_ID"
PROBE_IMAGE="boxa-shutdown-probe:$RUN_ID"
STATE_VOLUME="$RUN_ID-state"
LAUNCH_PID=""
START_LOG="$TMPROOT/start.log"
STOP_LOG="$TMPROOT/stop.log"

cleanup() {
    if [ -n "$LAUNCH_PID" ]; then
        kill "$LAUNCH_PID" >/dev/null 2>&1 || true
        wait "$LAUNCH_PID" 2>/dev/null || true
    fi

    # Every target is derived from the unique mktemp Project name. The normal
    # remove flow clears the registry, routes, certificates, and Project
    # volumes and reconciles shared infrastructure; the exact-name operations
    # are interruption/failure backstops.
    "$BOXA_DIR/docker-run.sh" stop "$PROJECT_NAME" >/dev/null 2>&1 || true
    docker rm -f "$OUTER_CONTAINER" >/dev/null 2>&1 || true
    "$BOXA_DIR/docker-run.sh" remove "$PROJECT_NAME" >/dev/null 2>&1 || true
    for suffix in "${BOXA_PROJECT_VOLUME_SUFFIXES[@]}"; do
        docker volume rm "$(boxa::volume_name "$PROJECT_NAME" "$suffix")" \
            >/dev/null 2>&1 || true
    done
    rm -rf "$TMPROOT"
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' INT TERM

start_disposable_project() {
    : > "$START_LOG"
    "$BOXA_DIR/docker-run.sh" "$PROJECT_DIR" </dev/null >"$START_LOG" 2>&1 &
    LAUNCH_PID=$!

    local ready=false
    for _ in $(seq 1 180); do
        if docker exec -u node "$OUTER_CONTAINER" docker info >/dev/null 2>&1; then
            ready=true
            break
        fi
        if ! kill -0 "$LAUNCH_PID" 2>/dev/null \
            && ! docker ps --filter "name=^${OUTER_CONTAINER}$" --format '{{.Names}}' \
                | grep -qx "$OUTER_CONTAINER"; then
            break
        fi
        sleep 0.25
    done

    if kill -0 "$LAUNCH_PID" 2>/dev/null; then
        kill "$LAUNCH_PID" >/dev/null 2>&1 || true
    fi
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCH_PID=""

    if [ "$ready" != true ]; then
        printf 'FAIL  disposable Boxa Project did not become ready.\n' >&2
        sed -n '1,200p' "$START_LOG" >&2
        return 1
    fi
}

# A tiny static PID 1 probe avoids pulling any workload image. Each service
# appends its label on SIGTERM, making Compose's reverse dependency order
# directly observable in the preserved named volume.
cat > "$PROJECT_DIR/shutdown-probe.c" <<'EOF'
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

static const char *label = "unknown";

static void stop_handler(int signal_number) {
    int fd;
    (void)signal_number;
    fd = open("/events/order", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
        (void)write(fd, label, strlen(label));
        (void)write(fd, "\n", 1);
        (void)close(fd);
    }
    _exit(0);
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "read") == 0) {
        char buffer[256];
        ssize_t size;
        int fd = open("/events/order", O_RDONLY);
        if (fd < 0) {
            return 1;
        }
        while ((size = read(fd, buffer, sizeof(buffer))) > 0) {
            if (write(STDOUT_FILENO, buffer, (size_t)size) != size) {
                (void)close(fd);
                return 1;
            }
        }
        (void)close(fd);
        return size < 0;
    }
    if (argc > 1) {
        label = argv[1];
    }
    (void)signal(SIGTERM, stop_handler);
    for (;;) {
        pause();
    }
}
EOF

cat > "$PROJECT_DIR/Dockerfile.probe" <<'EOF'
FROM scratch
COPY shutdown-probe /shutdown-probe
ENTRYPOINT ["/shutdown-probe"]
EOF

cat > "$PROJECT_DIR/compose.yml" <<EOF
services:
  database:
    build:
      context: .
      dockerfile: Dockerfile.probe
    image: $PROBE_IMAGE
    user: "0"
    command: ["database"]
    volumes: ["state:/events"]
  application:
    build:
      context: .
      dockerfile: Dockerfile.probe
    image: $PROBE_IMAGE
    user: "0"
    depends_on: [database]
    command: ["application"]
    volumes: ["state:/events"]
volumes:
  state:
    name: $STATE_VOLUME
EOF

cat > "$PROJECT_DIR/compose.override.yml" <<'EOF'
services:
  application:
    stop_grace_period: 5s
EOF

start_disposable_project || exit 1

# Simulate a Container created before ADR 0035. Rebuilding the local image does
# not update the root filesystem of an already-running Container, so the host
# CLI must be able to stream its current helper into this disposable target.
if ! docker exec -u root "$OUTER_CONTAINER" \
    rm -f /usr/local/bin/boxa-shutdown-inner; then
    printf 'FAIL  could not prepare the mixed-version shutdown scenario.\n' >&2
    exit 1
fi

if ! docker exec -u node -w "$PROJECT_DIR" "$OUTER_CONTAINER" \
    gcc -static -Os -s -o shutdown-probe shutdown-probe.c; then
    printf 'FAIL  could not compile the local no-pull shutdown probe.\n' >&2
    exit 1
fi

if ! docker exec -u node -w "$PROJECT_DIR" "$OUTER_CONTAINER" \
    docker compose -p "$COMPOSE_PROJECT" \
        -f compose.yml -f compose.override.yml up --build -d; then
    printf 'FAIL  disposable Compose workload did not start.\n' >&2
    exit 1
fi

if ! "$BOXA_DIR/docker-run.sh" stop "$PROJECT_NAME" >"$STOP_LOG" 2>&1; then
    printf 'FAIL  explicit Boxa shutdown failed.\n' >&2
    sed -n '1,240p' "$STOP_LOG" >&2
    exit 1
fi

if ! grep -q "Stopping Compose project: $COMPOSE_PROJECT" "$STOP_LOG"; then
    printf 'FAIL  explicit shutdown did not report the Compose project.\n' >&2
    sed -n '1,240p' "$STOP_LOG" >&2
    exit 1
fi
if ! grep -q "Using current shutdown helper for older Container: $OUTER_CONTAINER" \
    "$STOP_LOG"; then
    printf 'FAIL  explicit shutdown did not use the mixed-version helper fallback.\n' >&2
    sed -n '1,240p' "$STOP_LOG" >&2
    exit 1
fi

# Recreate only the disposable outer Container. Its Project Docker volume is
# preserved, so this observes the exact daemon state left by explicit stop.
start_disposable_project || exit 1

if [ -n "$(docker exec -u node "$OUTER_CONTAINER" docker ps -aq)" ]; then
    printf 'FAIL  Inner container records remained after explicit shutdown.\n' >&2
    exit 1
fi

order="$(docker exec -u node "$OUTER_CONTAINER" \
    docker run --rm -v "$STATE_VOLUME:/events" "$PROBE_IMAGE" \
        read 2>/dev/null)"
if [ "$order" != "$(printf 'application\ndatabase')" ]; then
    printf 'FAIL  unexpected shutdown order: %q\n' "$order" >&2
    exit 1
fi

if ! docker exec -u node "$OUTER_CONTAINER" docker image inspect "$PROBE_IMAGE" \
    >/dev/null 2>&1; then
    printf 'FAIL  explicit shutdown removed the workload image.\n' >&2
    exit 1
fi

printf 'PASS  disposable Boxa Project proved reverse dependency order, empty inner state, and preserved image/volume data.\n'

# Prove the emergency path against Docker's real outer deadline. The wrapper
# replaces only this disposable Container's Docker client after all inner
# daemon assertions are complete. PID 1 sees one synthetic running Inner
# container whose stop never returns; host `docker stop` must therefore enforce
# the Container's configured 45-second deadline and SIGKILL the outer process.
outer_stop_timeout="$(docker inspect --format '{{.Config.StopTimeout}}' "$OUTER_CONTAINER")"
if [ "$outer_stop_timeout" != 45 ]; then
    printf 'FAIL  disposable outer Container stop timeout is %q, expected 45.\n' \
        "$outer_stop_timeout" >&2
    exit 1
fi

cat > "$PROJECT_DIR/stalling-docker" <<'EOF'
#!/bin/bash
case "${1:-}" in
    info) exit 0 ;;
    ps) printf '%s\n' 'stalled-id stalled-inner' ;;
    stop)
        : > "$BOXA_PROJECT_HOST_PATH/pid1-stop-started"
        sleep 120
        ;;
    *) exit 1 ;;
esac
EOF
docker cp "$PROJECT_DIR/stalling-docker" "$OUTER_CONTAINER:/usr/local/bin/docker" \
    >/dev/null
docker exec -u root "$OUTER_CONTAINER" chmod 0755 /usr/local/bin/docker

deadline_started_at="$(date +%s)"
if ! docker stop "$OUTER_CONTAINER" >/dev/null; then
    printf 'FAIL  direct outer Docker stop failed.\n' >&2
    exit 1
fi
deadline_elapsed=$(($(date +%s) - deadline_started_at))

if [ ! -f "$PROJECT_DIR/pid1-stop-started" ]; then
    printf 'FAIL  direct SIGTERM did not enter the PID 1 Inner container fallback.\n' >&2
    exit 1
fi
if [ "$deadline_elapsed" -lt 40 ] || [ "$deadline_elapsed" -gt 60 ]; then
    printf 'FAIL  direct SIGTERM completed in %ss; expected the configured 45s outer deadline.\n' \
        "$deadline_elapsed" >&2
    exit 1
fi

printf 'PASS  a stalled emergency Inner container stop was bounded by the real %ss outer deadline.\n' \
    "$outer_stop_timeout"
