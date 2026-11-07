
#!/usr/bin/env bash
set -Eeuo pipefail

# Blue-green deployment for the CI/CD learning application.
# Usage: deploy-blue-green.sh IMAGE:TAG
# Run through AWS Systems Manager as root.

IMAGE="${1:?Usage: deploy-blue-green.sh IMAGE:TAG}"

ROOT="/home/ubuntu/blue-green"
CONFIG="$ROOT/nginx/default.conf"
STATE_DIR="$ROOT/rollback"
RELEASES="$STATE_DIR/releases.json"
NETWORK="blue-green-net"
PROXY="nginx-proxy"
LOCK="/var/lock/cicd-blue-green-deploy.lock"
PUBLIC_URL="http://127.0.0.1"
CONTAINER_PORT=8080
HEALTH_PATH="/health/ready"
source "$(dirname "$0")/transaction-lib.sh"

for cmd in docker curl flock jq mktemp ss awk grep seq base64 install; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Required command missing: $cmd"
        exit 1
    }
done

[[ "$IMAGE" =~ ^[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+$ ]] || {
    echo "ERROR: Supply an explicit image:tag reference."
    exit 1
}

mkdir -p "$ROOT/nginx" "$STATE_DIR"

exec 9>"$LOCK"
flock -n 9 || {
    echo "LOCK_BUSY: Another deployment or rollback is running."
    exit 75
}

# Recover an interrupted route/metadata transaction before inspecting live state.
txn_recover

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create "$NETWORK" >/dev/null
fi

# Identify the active production slot from the host configuration.
ACTIVE=""
if [[ -f "$CONFIG" ]] &&
   docker container inspect "$PROXY" >/dev/null 2>&1; then
    if grep -Fq 'proxy_pass http://cicd-blue:8080;' "$CONFIG"; then
        ACTIVE="blue"
    elif grep -Fq 'proxy_pass http://cicd-green:8080;' "$CONFIG"; then
        ACTIVE="green"
    fi
fi

BOOTSTRAP=false

if [[ -z "$ACTIVE" ]]; then
    if docker container inspect "$PROXY" >/dev/null 2>&1; then
        echo "ERROR: Running proxy has an unrecognized active route."
        echo "If it still points to cicd-blue:80 or cicd-green:80, it is the legacy Nginx app."
        echo "Migrate the proxy and slot containers to the Go app on port 8080 before deploying."
        echo "Refusing to change production routing."
        exit 1
    fi

    BOOTSTRAP=true
    TARGET="blue"
else
    [[ "$ACTIVE" == "blue" ]] && TARGET="green" || TARGET="blue"
fi

TARGET_CONTAINER="cicd-$TARGET"
if [[ "$TARGET" == "blue" ]]; then
    TARGET_PORT=8081
else
    TARGET_PORT=8082
fi

ACTIVE_IMAGE=""
ACTIVE_IMAGE_ID=""
ACTIVE_DIGEST=""

if [[ "$BOOTSTRAP" == false ]]; then
    if ! docker container inspect "cicd-$ACTIVE" >/dev/null 2>&1; then
        echo "ERROR: Active slot container is missing."
        exit 1
    fi

    ACTIVE_IMAGE=$(docker inspect --format '{{.Config.Image}}' "cicd-$ACTIVE")
    ACTIVE_IMAGE_ID=$(docker inspect --format '{{.Image}}' "cicd-$ACTIVE")
    ACTIVE_DIGEST=$(docker image inspect --format \
        '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
        "$ACTIVE_IMAGE" 2>/dev/null || true)

    ACTIVE_PORT=8081
    [[ "$ACTIVE" == "green" ]] && ACTIVE_PORT=8082

    # Validate availability by HTTP status only; response bodies are app-specific.
    curl -fsS --max-time 5 -o /dev/null \
        "http://127.0.0.1:${ACTIVE_PORT}${HEALTH_PATH}" || {
        echo "ERROR: Active slot health endpoint failed."
        exit 1
    }
fi

echo "Pulling candidate image: $IMAGE"
docker pull "$IMAGE"

CANDIDATE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE")
CANDIDATE_DIGEST=$(docker image inspect --format \
    '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$IMAGE")

# Run candidate in isolation before touching the standby slot.
TEMP_SUFFIX="${RANDOM}-$$"
CANDIDATE_CONTAINER="cicd-candidate-$TEMP_SUFFIX"
CANDIDATE_PORT=18080

for _ in $(seq 1 20); do
    if ! ss -ltn | awk '{print $4}' |
        grep -Eq "(:|\\])${CANDIDATE_PORT}$"; then
        break
    fi
    CANDIDATE_PORT=$((CANDIDATE_PORT + 1))
done

if ss -ltn | awk '{print $4}' |
    grep -Eq "(:|\\])${CANDIDATE_PORT}$"; then
    echo "ERROR: Could not find a free candidate port."
    exit 1
fi

cleanup_candidate() {
    docker rm -f "$CANDIDATE_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup_candidate EXIT

docker run -d \
    --name "$CANDIDATE_CONTAINER" \
    --network "$NETWORK" \
    -p "127.0.0.1:${CANDIDATE_PORT}:${CONTAINER_PORT}" \
    "$CANDIDATE_ID" >/dev/null

CANDIDATE_OK=false

for attempt in $(seq 1 15); do
    if curl -fsS --max-time 3 -o /dev/null \
        "http://127.0.0.1:${CANDIDATE_PORT}${HEALTH_PATH}" 2>/dev/null; then
        CANDIDATE_OK=true
        break
    fi
    sleep 2
done

if [[ "$CANDIDATE_OK" != true ]]; then
    echo "ERROR: Candidate health endpoint did not return a successful HTTP status."
    echo "Production and the standby slot have not been changed."
    exit 1
fi

cleanup_candidate
trap - EXIT

# Preserve the old standby image so it can be restored if startup fails.
OLD_TARGET_ID=""
if docker container inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
    OLD_TARGET_ID=$(docker inspect --format '{{.Image}}' "$TARGET_CONTAINER")
    docker rm -f "$TARGET_CONTAINER" >/dev/null
fi

restore_standby() {
    if [[ -n "$OLD_TARGET_ID" ]] &&
       ! docker container inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
        docker run -d \
            --name "$TARGET_CONTAINER" \
            --restart unless-stopped \
            --network "$NETWORK" \
            -p "127.0.0.1:${TARGET_PORT}:${CONTAINER_PORT}" \
            "$OLD_TARGET_ID" >/dev/null
    fi
}

if ! docker run -d \
    --name "$TARGET_CONTAINER" \
    --restart unless-stopped \
    --network "$NETWORK" \
    -p "127.0.0.1:${TARGET_PORT}:${CONTAINER_PORT}" \
    "$CANDIDATE_ID" >/dev/null; then
    echo "ERROR: Could not start candidate in standby slot."
    restore_standby || echo "CRITICAL: Standby restoration failed."
    exit 1
fi

STANDBY_OK=false
for attempt in $(seq 1 15); do
    if curl -fsS --max-time 3 -o /dev/null \
        "http://127.0.0.1:${TARGET_PORT}${HEALTH_PATH}" 2>/dev/null; then
        STANDBY_OK=true
        break
    fi
    sleep 2
done

if [[ "$STANDBY_OK" != true ]]; then
    echo "ERROR: Candidate failed standby validation."
    docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
    restore_standby || echo "CRITICAL: Standby restoration failed."
    exit 1
fi

META_TMP=$(mktemp "$STATE_DIR/releases.json.XXXXXX")

jq -n \
    --arg active_slot "$TARGET" \
    --arg active_image "$IMAGE" \
    --arg active_image_id "$CANDIDATE_ID" \
    --arg active_digest "$CANDIDATE_DIGEST" \
    --arg previous_slot "${ACTIVE:-}" \
    --arg previous_image "$ACTIVE_IMAGE" \
    --arg previous_image_id "$ACTIVE_IMAGE_ID" \
    --arg previous_digest "$ACTIVE_DIGEST" \
    '{
        active: {
            slot: $active_slot,
            image: $active_image,
            image_id: $active_image_id,
            digest: $active_digest
        },
        previous: {
            slot: $previous_slot,
            image: $previous_image,
            image_id: $previous_image_id,
            digest: $previous_digest
        }
    }' > "$META_TMP"


# Save the current route for recovery.
BACKUP=""
if [[ "$BOOTSTRAP" == false ]]; then
    BACKUP=$(mktemp)
    cp "$CONFIG" "$BACKUP"
fi

TMP_CONFIG=$(mktemp "$ROOT/nginx/default.conf.XXXXXX")

write_config() {
    local slot="$1"
    local output="$2"

    cat > "$output" <<NGINX
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://cicd-${slot}:${CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
}

write_config "$TARGET" "$TMP_CONFIG"
txn_begin "$BOOTSTRAP"
trap 'rc=$?; txn_recover || echo "CRITICAL: transaction recovery failed"; exit "$rc"' ERR
mv "$TMP_CONFIG" "$CONFIG"

restore_route() {
    txn_recover
}

# Bootstrap uses a directory mount. Existing proxies must be migrated separately
# before deploying; do not silently recreate a live production proxy here.
if [[ "$BOOTSTRAP" == true ]]; then
    if ! docker run -d \
        --name "$PROXY" \
        --restart unless-stopped \
        --network "$NETWORK" \
        -p 80:80 \
        -v "$ROOT/nginx:/etc/nginx/conf.d:ro" \
        nginx:alpine >/dev/null; then
        echo "ERROR: Could not start initial proxy."
        restore_route || true
        exit 1
    fi
else
    MOUNT_TYPE=$(docker inspect --format \
        '{{range .Mounts}}{{if eq .Destination "/etc/nginx/conf.d/default.conf"}}file{{end}}{{if eq .Destination "/etc/nginx/conf.d"}}directory{{end}}{{end}}' \
        "$PROXY")

    if [[ "$MOUNT_TYPE" != "directory" ]]; then
        echo "ERROR: Existing proxy still uses a single-file bind mount."
        echo "Migrate nginx-proxy to the directory mount before retrying."
        echo "The active route file has been changed on disk; restoring it now."

        restore_route || echo "CRITICAL: Route restoration could not be verified."
        rm -f "$BACKUP"
        exit 1
    fi

    if ! docker exec "$PROXY" nginx -t ||
       ! docker exec "$PROXY" nginx -s reload; then
        echo "ERROR: Nginx validation/reload failed."
        restore_route || echo "CRITICAL: Route restoration failed."
        docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
        restore_standby || echo "CRITICAL: Standby restoration failed."
        rm -f "$BACKUP"
        exit 1
    fi
fi

PROD_OK=false
for attempt in $(seq 1 15); do
    if curl -fsS --max-time 3 -o /dev/null \
        "${PUBLIC_URL}${HEALTH_PATH}" 2>/dev/null; then
        PROD_OK=true
        break
    fi
    sleep 2
done

if [[ "$PROD_OK" != true ]]; then
    echo "ERROR: Production verification failed; restoring previous route."
    restore_route || echo "CRITICAL: Automatic route restoration failed."
    docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
    restore_standby || echo "CRITICAL: Standby restoration failed."
    rm -f "$BACKUP"
    exit 1
fi

chmod 600 "$META_TMP"
mv "$META_TMP" "$RELEASES"
printf '%s\n' "$TARGET" > "$STATE_DIR/active-slot.txt"
printf '%s\n' "$IMAGE" > "$STATE_DIR/${TARGET}-image.txt"
txn_commit
trap - ERR

[[ -z "$BACKUP" ]] || rm -f "$BACKUP"

echo "SUCCESS: $TARGET is serving production traffic."
echo "Image=$IMAGE ImageID=$CANDIDATE_ID Digest=${CANDIDATE_DIGEST:-unavailable}"
[[ "$BOOTSTRAP" == true ]] || echo "Previous production release preserved in $ACTIVE."
