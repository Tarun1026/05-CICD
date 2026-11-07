#!/usr/bin/env bash
# Shared durable transaction journal for blue-green route + release metadata changes.
# Caller must hold the deployment flock and define CONFIG, RELEASES, PROXY, STATE_DIR.

TXN_DIR="${STATE_DIR}/transaction"

txn_recover() {
    local journal="$TXN_DIR/journal.json" phase had_config had_releases had_slot bootstrap tmp
    [[ -f "$journal" ]] || return 0

    phase="$(jq -r '.phase // "prepared"' "$journal")"
    if [[ "$phase" == "committed" ]]; then
        rm -rf "$TXN_DIR"
        echo "Recovered completed transaction journal."
        return 0
    fi

    had_config="$(jq -r '.had_config // false' "$journal")"
    had_releases="$(jq -r '.had_releases // false' "$journal")"
    had_slot="$(jq -r '.had_slot // false' "$journal")"
    bootstrap="$(jq -r '.bootstrap // false' "$journal")"

    if [[ "$had_config" == "true" ]]; then
        [[ -s "$TXN_DIR/old-nginx.conf" ]] || {
            echo "CRITICAL: Transaction journal is missing the previous Nginx configuration." >&2
            return 1
        }
        tmp="$(mktemp "$(dirname "$CONFIG")/.restore.XXXXXX")"
        cp "$TXN_DIR/old-nginx.conf" "$tmp"
        chmod 0644 "$tmp"
        mv -f "$tmp" "$CONFIG"
    else
        # Initial bootstrap did not have a production proxy/configuration to restore.
        docker rm -f "$PROXY" >/dev/null 2>&1 || true
        rm -f "$CONFIG"
    fi

    if [[ "$had_releases" == "true" ]]; then
        [[ -s "$TXN_DIR/old-releases.json" ]] || {
            echo "CRITICAL: Transaction journal is missing previous release metadata." >&2
            return 1
        }
        tmp="$(mktemp "$(dirname "$RELEASES")/.restore.XXXXXX")"
        cp "$TXN_DIR/old-releases.json" "$tmp"
        chmod 0600 "$tmp"
        mv -f "$tmp" "$RELEASES"
    else
        rm -f "$RELEASES"
    fi

    if [[ "$had_slot" == "true" && -s "$TXN_DIR/old-active-slot.txt" ]]; then
        tmp="$(mktemp "$STATE_DIR/.active-slot.restore.XXXXXX")"
        cp "$TXN_DIR/old-active-slot.txt" "$tmp"
        chmod 0600 "$tmp"
        mv -f "$tmp" "$STATE_DIR/active-slot.txt"
    elif [[ -f "$STATE_DIR/active-slot.txt" ]]; then
        if [[ -f "$RELEASES" ]]; then
            jq -r '.active.slot // empty' "$RELEASES" > "$STATE_DIR/active-slot.txt" || rm -f "$STATE_DIR/active-slot.txt"
        else
            rm -f "$STATE_DIR/active-slot.txt"
        fi
    fi

    if [[ "$had_config" == "true" ]]; then
        if [[ "$bootstrap" == "true" ]]; then
            docker rm -f "$PROXY" >/dev/null 2>&1 || true
        elif docker container inspect "$PROXY" >/dev/null 2>&1; then
            if [[ "$(docker inspect --format '{{.State.Running}}' "$PROXY" 2>/dev/null)" != "true" ]]; then
                docker start "$PROXY" >/dev/null
            fi
            docker exec "$PROXY" nginx -t
            docker exec "$PROXY" nginx -s reload
            if [[ -n "${PUBLIC_URL:-}" && -n "${HEALTH_PATH:-}" ]]; then
                curl -fsS --connect-timeout 2 --max-time 5 -o /dev/null \
                    "${PUBLIC_URL}${HEALTH_PATH}" || {
                    echo "CRITICAL: Previous Nginx route restored but public health verification failed." >&2
                    return 1
                }
            fi
        else
            echo "CRITICAL: Previous Nginx proxy is missing; restored config file but could not reload it." >&2
            return 1
        fi
    fi

    rm -rf "$TXN_DIR"
    echo "Recovered interrupted transaction: previous route and release metadata restored."
}

txn_begin() {
    local bootstrap="$1"
    local had_config=false had_releases=false had_slot=false
    rm -rf "$TXN_DIR"
    mkdir -p "$TXN_DIR"
    if [[ -f "$CONFIG" ]]; then
        had_config=true
        cp "$CONFIG" "$TXN_DIR/old-nginx.conf"
        chmod 0600 "$TXN_DIR/old-nginx.conf"
    fi
    if [[ -f "$RELEASES" ]]; then
        had_releases=true
        cp "$RELEASES" "$TXN_DIR/old-releases.json"
        chmod 0600 "$TXN_DIR/old-releases.json"
    fi
    if [[ -f "$STATE_DIR/active-slot.txt" ]]; then
        had_slot=true
        cp "$STATE_DIR/active-slot.txt" "$TXN_DIR/old-active-slot.txt"
        chmod 0600 "$TXN_DIR/old-active-slot.txt"
    fi
    jq -n --argjson had_config "$had_config" --argjson had_releases "$had_releases" --argjson had_slot "$had_slot" --argjson bootstrap "$bootstrap" \
        '{phase:"prepared",had_config:$had_config,had_releases:$had_releases,had_slot:$had_slot,bootstrap:$bootstrap}' \
        > "$TXN_DIR/journal.json"
    chmod 0600 "$TXN_DIR/journal.json"
}

txn_commit() {
    local tmp
    tmp="$(mktemp "$TXN_DIR/journal.XXXXXX")"
    jq '.phase = "committed"' "$TXN_DIR/journal.json" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$TXN_DIR/journal.json"
    rm -rf "$TXN_DIR"
}
