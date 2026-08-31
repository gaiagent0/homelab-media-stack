#!/bin/bash
# dvb-watchdog.sh — Automatic DVB adapter watchdog
#
# Checks TVheadend adapter health and triggers automatic recovery if needed.
# Designed to run via cron (every 5 minutes).
#
# Recovery steps:
#   1. Check Docker healthcheck
#   2. Check DVB device node exists
#   3. Check TVheadend responds to /ping
#   4. If any check fails → run recover-tvheadend.sh
#
# Usage:
#   ./dvb-watchdog.sh                  — check and recover if needed
#   ./dvb-watchdog.sh --dry-run        — check only, don't recover
#   ./dvb-watchdog.sh --status         — print status JSON
#
# Cron example:
#   */5 * * * * /opt/tvheadend/dvb-watchdog.sh >> /opt/tvheadend/watchdog.log 2>&1

set -euo pipefail

TVH_API="http://127.0.0.1:9981"
RECOVERY_SCRIPT="/opt/tvheadend/recover-tvheadend.sh"
LOG_FILE="/opt/tvheadend/watchdog.log"
STATUS_FILE="/opt/tvheadend/watchdog-status.json"
MAX_LOG_SIZE=1048576  # 1MB
DRY_RUN=false
STATUS_ONLY=false

# Parse args
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --status)  STATUS_ONLY=true ;;
    esac
done

# ─── Helpers ───────────────────────────────────────────────────
ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() { echo "[$(ts)] $*"; }

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.1"
            log "Log rotated (was ${size} bytes)"
        fi
    fi
}

# ─── Checks ────────────────────────────────────────────────────
ISSUES=()
WARNINGS=()

# Check 1: Docker healthcheck
check_docker_health() {
    local status
    status=$(docker inspect tvheadend --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    if [ "$status" = "healthy" ]; then
        return 0
    else
        ISSUES+=("docker_healthcheck:$status")
        return 1
    fi
}

# Check 2: DVB device node
check_dvb_device() {
    if [ -e /dev/dvb/adapter0/frontend0 ]; then
        # Check if device is accessible (not stale)
        if docker exec tvheadend test -e /dev/dvb/adapter0/frontend0 2>/dev/null; then
            return 0
        else
            ISSUES+=("dvb_device:exists_but_inaccessible")
            return 1
        fi
    else
        ISSUES+=("dvb_device:missing")
        return 1
    fi
}

# Check 3: TVheadend HTTP response
check_tvh_http() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${TVH_API}/ping" 2>/dev/null || echo "000")
    if [ "$http_code" = "200" ]; then
        return 0
    else
        ISSUES+=("tvh_http:$http_code")
        return 1
    fi
}

# Check 4: Channel count sanity
check_channels() {
    local count
    count=$(curl -s --digest -u admin:admin --max-time 5 "${TVH_API}/api/channel/list" 2>/dev/null | \
        python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('entries',[])))" 2>/dev/null || echo "0")
    if [ "$count" -gt 0 ]; then
        return 0
    else
        WARNINGS+=("channels:$count")
        return 0  # warning, not critical
    fi
}

# Check 5: Container not in restart loop
check_restart_loop() {
    local restart_count
    restart_count=$(docker inspect tvheadend --format '{{.RestartCount}}' 2>/dev/null || echo "0")
    if [ "$restart_count" -gt 5 ]; then
        ISSUES+=("restart_loop:$restart_count")
        return 1
    fi
    return 0
}

# ─── Run all checks ────────────────────────────────────────────
OVERALL_HEALTHY=true

check_docker_health || OVERALL_HEALTHY=false
check_dvb_device    || OVERALL_HEALTHY=false
check_tvh_http      || OVERALL_HEALTHY=false
check_channels
check_restart_loop  || OVERALL_HEALTHY=false

# ─── Status output ─────────────────────────────────────────────
ISSUE_COUNT=${#ISSUES[@]}
WARN_COUNT=${#WARNINGS[@]}

if [ "$STATUS_ONLY" = true ]; then
    python3 -c "
import json
status = {
    'healthy': $( [ "$OVERALL_HEALTHY" = true ] && echo 'True' || echo 'False' ),
    'issues': '$(IFS=,; echo "${ISSUES[*]:-}")'.split(',') if '$(IFS=,; echo "${ISSUES[*]:-}")' else [],
    'warnings': '$(IFS=,; echo "${WARNINGS[*]:-}")'.split(',') if '$(IFS=,; echo "${WARNINGS[*]:-}")' else [],
    'issue_count': $ISSUE_COUNT,
    'warning_count': $WARN_COUNT,
    'timestamp': '$(date -Iseconds)'
}
print(json.dumps(status, indent=2))
"
    exit 0
fi

# Write status file
python3 -c "
import json
status = {
    'healthy': $( [ "$OVERALL_HEALTHY" = true ] && echo 'True' || echo 'False' ),
    'issues': '$(IFS=,; echo "${ISSUES[*]:-}")'.split(',') if '$(IFS=,; echo "${ISSUES[*]:-}")' else [],
    'warnings': '$(IFS=,; echo "${WARNINGS[*]:-}")'.split(',') if '$(IFS=,; echo "${WARNINGS[*]:-}")' else [],
    'issue_count': $ISSUE_COUNT,
    'warning_count': $WARN_COUNT,
    'timestamp': '$(date -Iseconds)'
}
with open('$STATUS_FILE', 'w') as f:
    json.dump(status, f, indent=2)
" 2>/dev/null || true

# ─── Log ───────────────────────────────────────────────────────
rotate_log

if [ "$OVERALL_HEALTHY" = true ]; then
    log "✅ HEALTHY — ${WARN_COUNT} warnings"
    exit 0
fi

log "⚠️  ISSUES DETECTED (${ISSUE_COUNT}):"
for issue in "${ISSUES[@]}"; do
    log "  - $issue"
done

if [ "$WARN_COUNT" -gt 0 ]; then
    log "  Warnings (${WARN_COUNT}):"
    for warn in "${WARNINGS[@]}"; do
        log "    - $warn"
    done
fi

# ─── Recovery ──────────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    log "🔍 DRY RUN — recovery would be triggered"
    exit 1
fi

if [ ! -f "$RECOVERY_SCRIPT" ]; then
    log "❌ Recovery script not found: $RECOVERY_SCRIPT"
    exit 1
fi

log "🔧 Triggering recovery: $RECOVERY_SCRIPT"
bash "$RECOVERY_SCRIPT" >> "$LOG_FILE" 2>&1
RECOVERY_EXIT=$?

if [ "$RECOVERY_EXIT" -eq 0 ]; then
    log "✅ Recovery completed successfully"
else
    log "❌ Recovery failed (exit code: $RECOVERY_EXIT)"
fi

exit $RECOVERY_EXIT
