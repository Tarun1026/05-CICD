#!/usr/bin/env bash
# Local production monitor: 30-second interval, 3 consecutive failures,
# one rollback attempt per incident, repeat SNS email every 10 minutes.
set -Eeuo pipefail

ROOT="/home/ubuntu/blue-green"
STATE_DIR="$ROOT/monitor"
RELEASES="$ROOT/rollback/releases.json"
ROLLBACK_SCRIPT="/usr/local/sbin/rollback-app.sh"
PUBLIC_URL="http://127.0.0.1"
HEALTH_PATH="/health"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
REPEAT_ALERT_SECONDS="${REPEAT_ALERT_SECONDS:-600}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:?Set SNS_TOPIC_ARN in the systemd service environment}"
AWS_REGION="${AWS_REGION:?Set AWS_REGION in the systemd service environment}"

for cmd in curl aws jq date; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Missing required command: $cmd"
    exit 1
  }
done

mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="$STATE_DIR/monitor.log"
exec >> "$LOG_FILE" 2>&1

log() { echo "[$(date -Is)] $*"; }


notify() {
  local subject="$1"
  local message="$2"

  if aws sns publish \
    --region "$AWS_REGION" \
    --topic-arn "$SNS_TOPIC_ARN" \
    --subject "$subject" \
    --message "$message" >/dev/null; then
    log "SNS notification sent: ${subject}"
  else
    log "ERROR: SNS notification failed: ${subject}"
  fi
}


is_healthy() {
  # HTTP success status only. Response body is deliberately ignored.
  curl -fsS --connect-timeout 2 --max-time 5 \
    "${PUBLIC_URL}${HEALTH_PATH}" -o /dev/null 2>/dev/null
}

read_state() {
  INCIDENT="false"
  FAILURES=0
  ROLLBACK_ATTEMPTED="false"
  LAST_ALERT=0
  INCIDENT_START=0
  if [[ -r "$STATE_FILE" ]]; then
    # State is a JSON file written by this script.
    INCIDENT="$(jq -r '.incident // false' "$STATE_FILE")"
    FAILURES="$(jq -r '.failures // 0' "$STATE_FILE")"
    ROLLBACK_ATTEMPTED="$(jq -r '.rollback_attempted // false' "$STATE_FILE")"
    LAST_ALERT="$(jq -r '.last_alert // 0' "$STATE_FILE")"
    INCIDENT_START="$(jq -r '.incident_start // 0' "$STATE_FILE")"
  fi
}

save_state() {
  local tmp
  tmp="$(mktemp "$STATE_DIR/state.XXXXXX")"
  jq -n \
    --argjson incident "$INCIDENT" \
    --argjson failures "$FAILURES" \
    --argjson rollback_attempted "$ROLLBACK_ATTEMPTED" \
    --argjson last_alert "$LAST_ALERT" \
    --argjson incident_start "$INCIDENT_START" \
    '{incident:$incident,failures:$failures,rollback_attempted:$rollback_attempted,last_alert:$last_alert,incident_start:$incident_start}' > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

while true; do
  NOW="$(date +%s)"
  read_state

  if is_healthy; then
    if [[ "$INCIDENT" == "true" ]]; then
      DURATION=$((NOW - INCIDENT_START))
      notify "Blue-Green service recovered" \
        "Production health checks recovered on $(hostname). Incident duration: ${DURATION}s. Check ${LOG_FILE} and release metadata for rollback outcome."
      log "Health recovered; incident cleared after ${DURATION}s."
    fi
    INCIDENT="false"
    FAILURES=0
    ROLLBACK_ATTEMPTED="false"
    LAST_ALERT=0
    INCIDENT_START=0
    save_state
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  FAILURES=$((FAILURES + 1))
  log "Production health check failed (${FAILURES}/${FAILURE_THRESHOLD})."

  if [[ "$INCIDENT" == "false" && "$FAILURES" -ge "$FAILURE_THRESHOLD" ]]; then
    INCIDENT="true"
    INCIDENT_START="$NOW"
    LAST_ALERT="$NOW"
    ROLLBACK_ATTEMPTED="false"
    save_state

    ACTIVE_SLOT="$(jq -r '.active.slot // "unknown"' "$RELEASES" 2>/dev/null || echo unknown)"
    PREVIOUS_SLOT="$(jq -r '.previous.slot // "unknown"' "$RELEASES" 2>/dev/null || echo unknown)"
    notify "ALERT: Blue-Green production unhealthy" \
      "Production failed ${FAILURES} consecutive checks on $(hostname). Automatic rollback will be attempted once. Active slot=${ACTIVE_SLOT}; previous slot=${PREVIOUS_SLOT}. Health URL=${PUBLIC_URL}${HEALTH_PATH}."
    log "Incident declared; alert sent."

    
    # Retry rollback only when the shared lock is busy.
    ROLLBACK_ATTEMPTED="true"
    save_state

    MAX_LOCK_ATTEMPTS=5
    LOCK_RETRY_DELAY=5
    ROLLBACK_DONE="false"

    for ((attempt = 1; attempt <= MAX_LOCK_ATTEMPTS; attempt++)); do
      log "Rollback attempt ${attempt}/${MAX_LOCK_ATTEMPTS}."

      if bash "$ROLLBACK_SCRIPT"; then
        ROLLBACK_DONE="true"
        log "Automatic rollback script returned success."
        notify "Blue-Green automatic rollback initiated" \
          "Rollback script returned success on $(hostname). The monitor will verify production health on subsequent checks."
        break
      else
        rollback_rc=$?
      fi

      if [[ "$rollback_rc" -eq 75 ]]; then
        log "Deployment lock busy on attempt ${attempt}/${MAX_LOCK_ATTEMPTS}."

        if [[ "$attempt" -lt "$MAX_LOCK_ATTEMPTS" ]]; then
          sleep "$LOCK_RETRY_DELAY"
        fi
      else
        log "CRITICAL: Rollback failed with exit code ${rollback_rc}; not retrying."
        break
      fi
    done

    if [[ "$ROLLBACK_DONE" != "true" ]]; then
      log "CRITICAL: Automatic rollback did not complete."
      notify "CRITICAL: Blue-Green automatic rollback failed" \
        "Rollback did not complete on $(hostname). Check ${LOG_FILE}, ${ROOT}/rollback/releases.json, and Nginx/container logs."
    fi


  elif [[ "$INCIDENT" == "true" && $((NOW - LAST_ALERT)) -ge "$REPEAT_ALERT_SECONDS" ]]; then
    LAST_ALERT="$NOW"
    save_state
    notify "REMINDER: Blue-Green production still unhealthy" \
      "Production remains unhealthy on $(hostname). Consecutive failed checks=${FAILURES}. Automatic rollback was attempted=${ROLLBACK_ATTEMPTED}. Inspect ${LOG_FILE} and EC2/Nginx/container state."
    log "Repeat incident alert sent."
  fi

  save_state
  sleep "$INTERVAL_SECONDS"
done
