
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/home/ubuntu/blue-green"
CONFIG="$ROOT/nginx/default.conf"
STATE_DIR="$ROOT/rollback"
RELEASES="$STATE_DIR/releases.json"
NETWORK="blue-green-net"
PROXY="nginx-proxy"
LOCK="/var/lock/cicd-blue-green-deploy.lock"

for cmd in docker curl flock jq mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Missing command: $cmd"
        exit 1
    }
done

mkdir -p "$STATE_DIR"
exec 9>"$LOCK"
flock -n 9 || {
    echo "ERROR: Another deployment or rollback is running."
    exit 1
}

[[ -r "$RELEASES" ]] || {
    echo "ERROR: Missing release metadata; refusing rollback."
    exit 1
}

[[ -f "$CONFIG" ]] || {
    echo "ERROR: Nginx config missing; refusing rollback."
    exit 1
}

docker container inspect "$PROXY" >/dev/null 2>&1 || {
    echo "ERROR: Nginx proxy is missing."
    exit 1
}

# Require the directory bind mount so atomic configuration replacement works.
MOUNT_TYPE=$(docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/etc/nginx/conf.d"}}directory{{end}}{{end}}' \
    "$PROXY")

[[ "$MOUNT_TYPE" == "directory" ]] || {
    echo "ERROR: Proxy must use the configuration directory bind mount."
    exit 1
}

PREVIOUS_SLOT=$(jq -r '.previous.slot // empty' "$RELEASES")
PREVIOUS_IMAGE=$(jq -r '.previous.image // empty' "$RELEASES")
PREVIOUS_IMAGE_ID=$(jq -r '.previous.image_id // empty' "$RELEASES")
PREVIOUS_DIGEST=$(jq -r '.previous.digest // empty' "$RELEASES")
PREVIOUS_EXPECTED=$(jq -r '.previous.expected // empty' "$RELEASES")

ACTIVE_SLOT=$(jq -r '.active.slot // empty' "$RELEASES")
ACTIVE_IMAGE=$(jq -r '.active.image // empty' "$RELEASES")
ACTIVE_IMAGE_ID=$(jq -r '.active.image_id // empty' "$RELEASES")
ACTIVE_DIGEST=$(jq -r '.active.digest // empty' "$RELEASES")
ACTIVE_EXPECTED=$(jq -r '.active.expected // empty' "$RELEASES")

# Ensure saved metadata agrees with the live production route.
if grep -Fq 'proxy_pass http://cicd-blue:80;' "$CONFIG"; then
    LIVE_SLOT="blue"
elif grep -Fq 'proxy_pass http://cicd-green:80;' "$CONFIG"; then
    LIVE_SLOT="green"
else
    echo "ERROR: Cannot determine live production slot from Nginx config."
    exit 1
fi

if [[ "$LIVE_SLOT" != "$ACTIVE_SLOT" ]]; then
    echo "ERROR: Live route ($LIVE_SLOT) disagrees with metadata ($ACTIVE_SLOT)."
    echo "Refusing rollback to avoid acting on stale release state."
    exit 1
fi

[[ "$PREVIOUS_SLOT" == "blue" || "$PREVIOUS_SLOT" == "green" ]] || {
    echo "ERROR: No valid previous slot recorded."
    exit 1
}

[[ "$ACTIVE_SLOT" == "blue" || "$ACTIVE_SLOT" == "green" ]] || {
    echo "ERROR: No valid active slot recorded."
    exit 1
}

[[ "$PREVIOUS_SLOT" != "$ACTIVE_SLOT" ]] || {
    echo "ERROR: Active and previous slots are identical."
    exit 1
}

[[ "$PREVIOUS_IMAGE_ID" =~ ^sha256:[a-f0-9]+$ ]] || {
    echo "ERROR: Previous exact image ID is missing."
    exit 1
}

[[ -n "$PREVIOUS_EXPECTED" ]] || {
    echo "ERROR: Previous expected application response is missing."
    exit 1
}

case "$PREVIOUS_SLOT" in
    blue) PORT=8081 ;;
    green) PORT=8082 ;;
esac

CONTAINER="cicd-$PREVIOUS_SLOT"

# Recover the exact previous image if it is not present locally.
if ! docker image inspect "$PREVIOUS_IMAGE_ID" >/dev/null 2>&1; then
    if [[ "$PREVIOUS_DIGEST" == *@sha256:* ]]; then
        docker pull "$PREVIOUS_DIGEST"
        PULLED_ID=$(docker image inspect --format '{{.Id}}' "$PREVIOUS_DIGEST")

        [[ "$PULLED_ID" == "$PREVIOUS_IMAGE_ID" ]] || {
            echo "ERROR: Downloaded image ID does not match recorded release."
            exit 1
        }
    else
        echo "ERROR: Previous image is unavailable locally and has no immutable digest."
        exit 1
    fi
fi

# Ensure the previous slot is running the exact recorded image.
if ! docker container inspect "$CONTAINER" >/dev/null 2>&1 ||
   [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" != "true" ]] ||
   [[ "$(docker inspect --format '{{.Image}}' "$CONTAINER")" != "$PREVIOUS_IMAGE_ID" ]]; then

    echo "Recreating previous slot from exact image ID $PREVIOUS_IMAGE_ID"

    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --network "$NETWORK" \
        -p "127.0.0.1:${PORT}:80" \
        "$PREVIOUS_IMAGE_ID" >/dev/null
fi

# Check the previous app response. Older releases may legitimately lack /health.
PREVIOUS_OK=false

for attempt in $(seq 1 15); do
    RESPONSE=$(curl -fsS --max-time 3 \
        "http://127.0.0.1:${PORT}/app.txt" 2>/dev/null || true)

    if [[ -n "$RESPONSE" && "$RESPONSE" == "$PREVIOUS_EXPECTED" ]]; then
        PREVIOUS_OK=true
        break
    fi

    sleep 2
done

[[ "$PREVIOUS_OK" == "true" ]] || {
    echo "ERROR: Previous release failed its application response check."
    echo "Production route remains unchanged."
    exit 1
}

# Record the original config and prepare the replacement in the same directory.
BACKUP=$(mktemp)
cp "$CONFIG" "$BACKUP"

TMP=$(mktemp "$ROOT/nginx/default.conf.XXXXXX")

cleanup() {
    rm -f "${TMP:-}" "${BACKUP:-}"
}
trap cleanup EXIT

cat > "$TMP" <<NGINX
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://cicd-${PREVIOUS_SLOT}:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

# Switch config atomically. The directory mount makes the new file visible.
mv "$TMP" "$CONFIG"
TMP=""

restore_original_route() {
    local restore_tmp
    restore_tmp=$(mktemp "$ROOT/nginx/default.conf.restore.XXXXXX")

    cp "$BACKUP" "$restore_tmp"
    mv "$restore_tmp" "$CONFIG"

    docker exec "$PROXY" nginx -t &&
        docker exec "$PROXY" nginx -s reload
}

if ! docker exec "$PROXY" nginx -t ||
   ! docker exec "$PROXY" nginx -s reload; then
    echo "ERROR: Nginx validation or reload failed; restoring original route."

    restore_original_route || {
        echo "CRITICAL: Could not restore the original route."
        exit 1
    }

    exit 1
fi

# Verify production returns the recorded previous application response.
VERIFIED=false

for attempt in $(seq 1 10); do
    RESPONSE=$(curl -fsS --max-time 3 \
        http://127.0.0.1/app.txt 2>/dev/null || true)

    if [[ -n "$RESPONSE" && "$RESPONSE" == "$PREVIOUS_EXPECTED" ]]; then
        VERIFIED=true
        break
    fi

    sleep 2
done

if [[ "$VERIFIED" != "true" ]]; then
    echo "ERROR: Production verification failed; restoring original route."

    restore_original_route || {
        echo "CRITICAL: Original route restoration failed."
        exit 1
    }

    exit 1
fi

# Swap the active and previous release metadata only after verification.
META_TMP=$(mktemp "$STATE_DIR/releases.json.XXXXXX")

jq -n \
    --arg active_slot "$PREVIOUS_SLOT" \
    --arg active_image "$PREVIOUS_IMAGE" \
    --arg active_image_id "$PREVIOUS_IMAGE_ID" \
    --arg active_digest "$PREVIOUS_DIGEST" \
    --arg active_expected "$PREVIOUS_EXPECTED" \
    --arg previous_slot "$ACTIVE_SLOT" \
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

printf '%s\n' "$PREVIOUS_SLOT" > "$STATE_DIR/active-slot.txt"

echo "ROLLBACK SUCCESS: Production now routes to $PREVIOUS_SLOT ($PREVIOUS_IMAGE)."
