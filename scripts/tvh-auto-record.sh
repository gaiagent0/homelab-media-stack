#!/bin/bash
# tvh-auto-record.sh — TVHeadend automatic recording based on EPG search
#
# Searches the EPG for configured series/movies and creates DVR entries.
# Can also create auto-recording rules (autorec) for recurring series.
#
# Usage:
#   ./tvh-auto-record.sh                    — process all configured shows
#   ./tvh-auto-record.sh --list             — list configured shows
#   ./tvh-auto-record.sh --search "Minta"   — search EPG for a title
#   ./tvh-auto-record.sh --autorec "Minta"  — create auto-recording rule
#   ./tvh-auto-record.sh --upcoming         — show upcoming recordings
#   ./tvh-auto-record.sh --dry-run          — preview without recording
#
# Configuration: edit the SHOWS array below or use tvh-auto-record.conf

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────
TVH_API="http://127.0.0.1:9981"
TVH_USER="admin"
TVH_PASS="admin"
CONF_FILE="${TVH_AUTO_RECORD_CONF:-/opt/tvheadend/tvh-auto-record.conf}"

# Default shows (can be overridden by conf file)
declare -a SHOWS=(
    "Az elefántok titkai"
)
declare -a DVR_CONFIG=""  # Leave empty for default DVR config

DRY_RUN=false
LOG_FILE="/opt/tvheadend/tvh-auto-record.log"
ACTION="process"  # process, list, search, autorec, upcoming

# ─── Parse arguments ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)     ACTION="list"; shift ;;
        --search)   ACTION="search"; SEARCH_TERM="$2"; shift 2 ;;
        --autorec)  ACTION="autorec"; SEARCH_TERM="$2"; shift 2 ;;
        --upcoming) ACTION="upcoming"; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --config)   CONF_FILE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--list|--search TERM|--autorec TERM|--upcoming|--dry-run|--config FILE]"
            echo ""
            echo "Commands:"
            echo "  (none)           Process all configured shows and record upcoming episodes"
            echo "  --list           List configured shows"
            echo "  --search TERM    Search EPG for a title"
            echo "  --autorec TERM   Create an auto-recording rule for a series"
            echo "  --upcoming       Show upcoming DVR recordings"
            echo "  --dry-run        Preview actions without actually recording"
            echo "  --config FILE    Use alternate config file"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Load config file if exists ─────────────────────────────────
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# ─── Helper functions ───────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

api_get() {
    curl -s --digest -u "${TVH_USER}:${TVH_PASS}" --max-time 10 \
        "${TVH_API}$1" 2>/dev/null || echo ""
}

api_post() {
    local endpoint="$1"
    shift
    curl -s --digest -u "${TVH_USER}:${TVH_PASS}" --max-time 10 \
        -X POST "$@" "${TVH_API}${endpoint}" 2>/dev/null || echo ""
}

json_get() {
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); $1" 2>/dev/null || echo ""
}

# ─── Check TVHeadend connectivity ───────────────────────────────
if ! api_get "/ping" | grep -q "" 2>/dev/null; then
    # /ping doesn't return body, just check HTTP code
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --digest -u "${TVH_USER}:${TVH_PASS}" "${TVH_API}/ping" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" != "200" ]]; then
        log "ERROR: TVHeadend is not reachable (HTTP $HTTP_CODE)"
        exit 1
    fi
fi

# ─── Get channel list ───────────────────────────────────────────
get_channels() {
    api_get "/api/channel/list" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
channels = data.get('entries', [])
for ch in channels:
    print(f\"{ch['key']}|{ch['val']}\")
" 2>/dev/null
}

# ─── Search EPG for a title ────────────────────────────────────
search_epg() {
    local query="$1"
    local limit="${2:-50}"
    # URL-encode the query
    local encoded
    encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))" 2>/dev/null || echo "$query")
    
    local result
    result=$(api_get "/api/epg/events/grid?limit=${limit}")
    
    echo "$result" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
query = '$query'.lower()
entries = data.get('entries', [])
matches = [e for e in entries if query in e.get('title', '').lower()]
for e in matches:
    import datetime
    start = datetime.datetime.fromtimestamp(e.get('start', 0)).strftime('%Y-%m-%d %H:%M')
    stop = datetime.datetime.fromtimestamp(e.get('stop', 0)).strftime('%H:%M')
    eid = e.get('id', '')
    title = e.get('title', '?')
    desc = e.get('description', '')[:80]
    print(f'{eid}|{title}|{start}-{stop}|{desc}')
if not matches:
    print(f'No EPG results for: $query (searched {len(entries)} events)')
" 2>/dev/null
}

# ─── Record an event by ID ─────────────────────────────────────
record_event() {
    local event_id="$1"
    local config_name="${2:-}"
    
    local payload="event_id=${event_id}"
    if [[ -n "$config_name" ]]; then
        payload="${payload}&config=${config_name}"
    fi
    
    if $DRY_RUN; then
        log "DRY-RUN: Would record event $event_id"
        return 0
    fi
    
    local result
    result=$(api_post "/api/dvr/entry/create_by_event" -d "$payload")
    
    if echo "$result" | grep -q "error"; then
        local error
        error=$(echo "$result" | json_get "print(d.get('error','unknown'))")
        log "ERROR recording event $event_id: $error"
        return 1
    else
        log "OK: Recording scheduled for event $event_id"
        return 0
    fi
}

# ─── Create auto-recording rule ─────────────────────────────────
create_autorec() {
    local title="$1"
    local config_name="${2:-}"
    
    if $DRY_RUN; then
        log "DRY-RUN: Would create autorec for '$title'"
        return 0
    fi
    
    local payload="title=${title}&enabled=true"
    if [[ -n "$config_name" ]]; then
        payload="${payload}&config=${config_name}"
    fi
    
    local result
    result=$(api_post "/api/dvr/autorec/create" -d "$payload")
    
    if echo "$result" | grep -q "error"; then
        local error
        error=$(echo "$result" | json_get "print(d.get('error','unknown'))")
        log "ERROR creating autorec for '$title': $error"
        return 1
    else
        log "OK: Auto-recording rule created for '$title'"
        return 0
    fi
}

# ─── Show upcoming recordings ───────────────────────────────────
show_upcoming() {
    echo "=== Upcoming DVR recordings ==="
    local result
    result=$(api_get "/api/dvr/entry/grid_upcoming")
    
    echo "$result" | python3 -c "
import json, sys, datetime
data = json.loads(sys.stdin.read())
entries = data.get('entries', [])
if not entries:
    print('No upcoming recordings')
else:
    for e in entries:
        start = datetime.datetime.fromtimestamp(e.get('start', 0)).strftime('%Y-%m-%d %H:%M')
        stop = datetime.datetime.fromtimestamp(e.get('stop', 0)).strftime('%H:%M')
        title = e.get('title', '?')
        channel = e.get('channel', '?')
        status = e.get('status', '?')
        print(f'  {start}-{stop} | {title} | ch: {channel} | {status}')
    print(f'\nTotal: {len(entries)} upcoming recordings')
" 2>/dev/null
}

# ─── Main: Process all configured shows ─────────────────────────
process_shows() {
    log "Processing ${#SHOWS[@]} configured shows..."
    
    local recorded=0
    local skipped=0
    local failed=0
    
    for show in "${SHOWS[@]}"; do
        log "Searching EPG for: $show"
        
        # Search EPG
        local epg_results
        epg_results=$(search_epg "$show" 200)
        
        if echo "$epg_results" | grep -q "No EPG results"; then
            log "  No upcoming broadcasts found for '$show'"
            ((skipped++))
            continue
        fi
        
        # Parse and record each match
        while IFS='|' read -r eid title times desc; do
            [[ -z "$eid" ]] && continue
            
            # Only record future events
            local now
            now=$(date +%s)
            local start_time
            start_time=$(echo "$times" | cut -d'-' -f1)
            # Extract epoch from the full datetime
            local event_start
            event_start=$(date -d "$start_time" +%s 2>/dev/null || echo 0)
            
            if [[ "$event_start" -gt "$now" ]]; then
                log "  Recording: $title ($times) [$desc]"
                if record_event "$eid" "$DVR_CONFIG"; then
                    ((recorded++))
                else
                    ((failed++))
                fi
            else
                log "  Skipping past event: $title ($times)"
            fi
        done <<< "$epg_results"
    done
    
    log "Summary: $recorded recorded, $skipped skipped, $failed failed"
}

# ─── Main ───────────────────────────────────────────────────────
log "tvh-auto-record.sh started (action=$ACTION, dry_run=$DRY_RUN)"

case "$ACTION" in
    list)
        echo "=== Configured shows ==="
        for show in "${SHOWS[@]}"; do
            echo "  - $show"
        done
        echo ""
        echo "Config: $CONF_FILE"
        [[ -f "$CONF_FILE" ]] && echo "(loaded)" || echo "(using defaults)"
        ;;
    search)
        echo "=== EPG search: $SEARCH_TERM ==="
        search_epg "$SEARCH_TERM" 200
        ;;
    autorec)
        create_autorec "$SEARCH_TERM" "$DVR_CONFIG"
        ;;
    upcoming)
        show_upcoming
        ;;
    process)
        process_shows
        ;;
esac

log "tvh-auto-record.sh finished"
