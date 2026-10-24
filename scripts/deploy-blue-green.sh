
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
HEALTH_PATH="/health"
APP_PATH="/app.txt"

for cmd in docker curl flock jq mktemp ss awk grep; do
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
    echo "ERROR: Another deployment or rollback is running."
    exit 1
}

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create "$NETWORK" >/dev/null
fi

# Identify the active production slot from the host configuration.
ACTIVE=""
if [[ -f "$CONFIG" ]] &&
   docker ps --format '{{.Names}}' | grep -qx "$PROXY"; then
    if grep -Fq 'proxy_pass http://cicd-blue:80;' "$CONFIG"; then
        ACTIVE="blue"
    elif grep -Fq 'proxy_pass http://cicd-green:80;' "$CONFIG"; then
        ACTIVE="green"
    fi
fi

BOOTSTRAP=false

if [[ -z "$ACTIVE" ]]; then
    if docker ps --format '{{.Names}}' | grep -qx "$PROXY"; then
        echo "ERROR: Running proxy has an ambiguous active slot."
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
ACTIVE_EXPECTED=""

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

    # Legacy active releases may not provide /health.
    # Preserve production as long as the application response is available.
    ACTIVE_EXPECTED=$(curl -fsS --max-time 5 \
        "http://127.0.0.1:${ACTIVE_PORT}${APP_PATH}") || {
        echo "ERROR: Active application response check failed."
        exit 1
    }

    [[ -n "$ACTIVE_EXPECTED" ]] || {
        echo "ERROR: Active application response is empty."
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
    -p "127.0.0.1:${CANDIDATE_PORT}:80" \
    "$CANDIDATE_ID" >/dev/null

CANDIDATE_OK=false
CANDIDATE_EXPECTED=""

for attempt in $(seq 1 15); do
    HEALTH=$(curl -fsS --max-time 3 \
        "http://127.0.0.1:${CANDIDATE_PORT}${HEALTH_PATH}" 2>/dev/null || true)
    RESPONSE=$(curl -fsS --max-time 3 \
        "http://127.0.0.1:${CANDIDATE_PORT}${APP_PATH}" 2>/dev/null || true)

    if [[ -n "$HEALTH" && -n "$RESPONSE" ]]; then
        CANDIDATE_EXPECTED="$RESPONSE"
        CANDIDATE_OK=true
        break
    fi
    sleep 2
done

if [[ "$CANDIDATE_OK" != true ]]; then
    echo "ERROR: Candidate failed /health or /app.txt validation."
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
            -p "127.0.0.1:${TARGET_PORT}:80" \
            "$OLD_TARGET_ID" >/dev/null
    fi
}

if ! docker run -d \
    --name "$TARGET_CONTAINER" \
    --restart unless-stopped \
    --network "$NETWORK" \
    -p "127.0.0.1:${TARGET_PORT}:80" \
    "$CANDIDATE_ID" >/dev/null; then
    echo "ERROR: Could not start candidate in standby slot."
    restore_standby || echo "CRITICAL: Standby restoration failed."
    exit 1
fi

STANDBY_OK=false
for attempt in $(seq 1 15); do
    H=$(curl -fsS --max-time 3 \
        "http://127.0.0.1:${TARGET_PORT}${HEALTH_PATH}" 2>/dev/null || true)
    R=$(curl -fsS --max-time 3 \
        "http://127.0.0.1:${TARGET_PORT}${APP_PATH}" 2>/dev/null || true)

    if [[ -n "$H" && "$R" == "$CANDIDATE_EXPECTED" ]]; then
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
        proxy_pass http://cicd-${slot}:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
}

write_config "$TARGET" "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG"

restore_route() {
    if [[ "$BOOTSTRAP" == true ]]; then
        docker rm -f "$PROXY" >/dev/null 2>&1 || true
        return 0
    fi

    # Restore the old route through a replacement file in the mounted directory.
    local restore_tmp
    restore_tmp=$(mktemp "$ROOT/nginx/default.conf.restore.XXXXXX")
    cp "$BACKUP" "$restore_tmp"
    mv "$restore_tmp" "$CONFIG"

    docker exec "$PROXY" nginx -t &&
        docker exec "$PROXY" nginx -s reload || return 1

    local port expected
    port=8081
    [[ "$ACTIVE" == "green" ]] && port=8082

    expected=$(curl -fsS --max-time 5 \
        "http://127.0.0.1:${port}${APP_PATH}") || return 1

    [[ "$expected" == "$ACTIVE_EXPECTED" ]] &&
        [[ "$(curl -fsS --max-time 5 "${PUBLIC_URL}${APP_PATH}")" == "$ACTIVE_EXPECTED" ]]
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
        rm -f "$BACKUP"
        exit 1
    fi
fi

PROD_OK=false
for attempt in $(seq 1 15); do
    PROD_HEALTH=$(curl -fsS --max-time 3 \
        "${PUBLIC_URL}${HEALTH_PATH}" 2>/dev/null || true)
    PROD_RESPONSE=$(curl -fsS --max-time 3 \
        "${PUBLIC_URL}${APP_PATH}" 2>/dev/null || true)

    if [[ -n "$PROD_HEALTH" &&
          "$PROD_RESPONSE" == "$CANDIDATE_EXPECTED" ]]; then
        PROD_OK=true
        break
    fi
    sleep 2
done

if [[ "$PROD_OK" != true ]]; then
    echo "ERROR: Production verification failed; restoring previous route."
    restore_route || echo "CRITICAL: Automatic route restoration failed."
    rm -f "$BACKUP"
    exit 1
fi

META_TMP=$(mktemp "$STATE_DIR/releases.json.XXXXXX")

jq -n \
    --arg active_slot "$TARGET" \
    --arg active_image "$IMAGE" \
    --arg active_image_id "$CANDIDATE_ID" \
    --arg active_digest "$CANDIDATE_DIGEST" \
    --arg active_expected "$CANDIDATE_EXPECTED" \
    --arg previous_slot "${ACTIVE:-}" \
    --arg previous_image "$ACTIVE_IMAGE" \
    --arg previous_image_id "$ACTIVE_IMAGE_ID" \
    --arg previous_digest "$ACTIVE_DIGEST" \
    --arg previous_expected "$ACTIVE_EXPECTED" \
    '{
        active: {
            slot: $active_slot,
            image: $active_image,
            image_id: $active_image_id,
            digest: $active_digest,
            expected: $active_expected
        },
        previous: {
            slot: $previous_slot,
            image: $previous_image,
            image_id: $previous_image_id,
            digest: $previous_digest,
            expected: $previous_expected
        }
    }' > "$META_TMP"

chmod 600 "$META_TMP"
mv "$META_TMP" "$RELEASES"
printf '%s\n' "$TARGET" > "$STATE_DIR/active-slot.txt"
printf '%s\n' "$IMAGE" > "$STATE_DIR/${TARGET}-image.txt"

[[ -z "$BACKUP" ]] || rm -f "$BACKUP"

echo "SUCCESS: $TARGET is serving production traffic."
echo "Image=$IMAGE ImageID=$CANDIDATE_ID Digest=${CANDIDATE_DIGEST:-unavailable}"
[[ "$BOOTSTRAP" == true ]] || echo "Previous production release preserved in $ACTIVE."
