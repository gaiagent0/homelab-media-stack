#!/bin/bash
# media-healthcheck.sh — Unified media stack healthcheck
#
# Checks all media services (Jellyfin, Radarr, Sonarr, TVHeadend, etc.)
# and reports status, disk usage, and any issues.
#
# Usage:
#   ./media-healthcheck.sh              — full healthcheck (human-readable)
#   ./media-healthcheck.sh --json       — JSON output (for APIs)
#   ./media-healthcheck.sh --quick      — quick status only
#   ./media-healthcheck.sh --fix        — attempt auto-fixes
#
# Designed to run on CT302 (Proxmox LXC container)

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────
JELLYFIN_URL="http://127.0.0.1:8096"
JELLYFIN_TOKEN="4e8fe300bc69482d85e411219d803482"
RADARR_URL="http://127.0.0.1:7878"
SONARR_URL="http://127.0.0.1:8989"
TVH_URL="http://127.0.0.1:9981"
TVH_USER="admin"
TVH_PASS="admin"

OUTPUT_MODE="human"  # human, json, quick
AUTO_FIX=false
ERRORS=0
WARNINGS=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)  OUTPUT_MODE="json"; shift ;;
        --quick) OUTPUT_MODE="quick"; shift ;;
        --fix)   AUTO_FIX=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--json|--quick|--fix]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helper functions ───────────────────────────────────────────
ok()     { [[ "$OUTPUT_MODE" == "human" || "$OUTPUT_MODE" == "quick" ]] && echo "  ✅ $*"; }
warn()   { [[ "$OUTPUT_MODE" == "human" || "$OUTPUT_MODE" == "quick" ]] && echo "  ⚠️  $*"; ((WARNINGS++)); }
error()  { [[ "$OUTPUT_MODE" == "human" || "$OUTPUT_MODE" == "quick" ]] && echo "  ❌ $*"; ((ERRORS++)); }
info()   { [[ "$OUTPUT_MODE" == "human" || "$OUTPUT_MODE" == "quick" ]] && echo "  ℹ️  $*"; }
header() { [[ "$OUTPUT_MODE" == "human" || "$OUTPUT_MODE" == "quick" ]] && echo -e "\n━━━ $* ━━━"; }

http_check() {
    local url="$1" timeout="${2:-5}"
    shift 2
    curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" "$@" 2>/dev/null || echo "000"
}

docker_check() {
    local name="$1"
    local status
    status=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
    echo "$status"
}

docker_health() {
    local name="$1"
    docker inspect "$name" --format '{{.State.Health.Status}}' 2>/dev/null || echo "none"
}

bytes_to_human() {
    python3 -c "
b = $1
for u in ['B','KB','MB','GB','TB']:
    if abs(b) < 1024: print(f'{b:.1f}{u}'); break
    b /= 1024
" 2>/dev/null || echo "${1}B"
}

# ─── JSON accumulator ───────────────────────────────────────────
declare -A JSON_RESULTS

# ─── 1. Docker containers ──────────────────────────────────────
check_containers() {
    header "Docker Containers"
    
    local containers=("jellyfin" "radarr" "sonarr" "tvheadend" "homepage")
    
    for c in "${containers[@]}"; do
        local status health
        status=$(docker_check "$c")
        health=$(docker_health "$c")
        
        case "$status" in
            running)
                if [[ "$health" == "healthy" ]]; then
                    ok "$c: running (healthy)"
                elif [[ "$health" == "unhealthy" ]]; then
                    error "$c: running but UNHEALTHY"
                    if $AUTO_FIX; then
                        info "Restarting $c..."
                        docker restart "$c" >/dev/null 2>&1 || true
                    fi
                else
                    ok "$c: running"
                fi
                ;;
            exited)
                error "$c: STOPPED"
                if $AUTO_FIX; then
                    info "Starting $c..."
                    docker start "$c" >/dev/null 2>&1 || true
                fi
                ;;
            not_found)
                warn "$c: not found (not deployed?)"
                ;;
            *)
                error "$c: $status"
                ;;
        esac
        JSON_RESULTS["container_$c"]="$status"
    done
}

# ─── 2. Jellyfin ────────────────────────────────────────────────
check_jellyfin() {
    header "Jellyfin"
    
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "${JELLYFIN_URL}/System/Info" -H "X-Emby-Token: ${JELLYFIN_TOKEN}" 2>/dev/null || echo "000")
    
    if [[ "$code" == "200" ]]; then
        ok "Web UI: accessible (HTTP $code)"
    else
        error "Web UI: not responding (HTTP $code)"
        return
    fi
    
    # Check media items
    local movie_count series_count episode_count
    movie_count=$(curl -s --max-time 10 "${JELLYFIN_URL}/Items?IncludeItemTypes=Movie&Recursive=true&Limit=1" \
        -H "X-Emby-Token: ${JELLYFIN_TOKEN}" 2>/dev/null | \
        python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('TotalRecordCount',0))" 2>/dev/null || echo "?")
    series_count=$(curl -s --max-time 10 "${JELLYFIN_URL}/Items?IncludeItemTypes=Series&Recursive=true&Limit=1" \
        -H "X-Emby-Token: ${JELLYFIN_TOKEN}" 2>/dev/null | \
        python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('TotalRecordCount',0))" 2>/dev/null || echo "?")
    episode_count=$(curl -s --max-time 10 "${JELLYFIN_URL}/Items?IncludeItemTypes=Episode&Recursive=true&Limit=1" \
        -H "X-Emby-Token: ${JELLYFIN_TOKEN}" 2>/dev/null | \
        python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('TotalRecordCount',0))" 2>/dev/null || echo "?")
    
    ok "Movies: $movie_count"
    ok "Series: $series_count"
    ok "Episodes: $episode_count"
    JSON_RESULTS["jellyfin_movies"]="$movie_count"
    JSON_RESULTS["jellyfin_series"]="$series_count"
    JSON_RESULTS["jellyfin_episodes"]="$episode_count"
    
    # Check active sessions
    local sessions
    sessions=$(curl -s --max-time 10 "${JELLYFIN_URL}/Sessions" \
        -H "X-Emby-Token: ${JELLYFIN_TOKEN}" 2>/dev/null || echo "[]")
    local active
    active=$(echo "$sessions" | python3 -c "
import json,sys
sessions = json.loads(sys.stdin.read())
active = [s for s in sessions if s.get('NowPlayingItem')]
print(len(active))
" 2>/dev/null || echo "0")
    
    if [[ "$active" -gt 0 ]]; then
        info "Active streams: $active"
    fi
    JSON_RESULTS["jellyfin_streams"]="$active"
}

# ─── 3. Radarr ─────────────────────────────────────────────────
check_radarr() {
    header "Radarr"
    
    local api_key
    api_key=$(docker exec radarr cat /config/config.xml 2>/dev/null | \
        grep -o '<ApiKey>[^<]*</ApiKey>' | sed 's/<[^>]*>//g' || echo "")
    
    if [[ -z "$api_key" ]]; then
        warn "Cannot read API key"
        return
    fi
    
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "${RADARR_URL}/api/v3/system/status" -H "X-Api-Key: ${api_key}" 2>/dev/null || echo "000")
    
    if [[ "$code" == "200" ]]; then
        ok "API: accessible"
    else
        error "API: not responding (HTTP $code)"
        return
    fi
    
    # Count movies
    local movie_data
    movie_data=$(curl -s --max-time 30 "${RADARR_URL}/api/v3/movie" \
        -H "X-Api-Key: ${api_key}" 2>/dev/null || echo "[]")
    
    local total has_file monitored
    total=$(echo "$movie_data" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")
    has_file=$(echo "$movie_data" | python3 -c "import json,sys; print(len([m for m in json.loads(sys.stdin.read()) if m.get('hasFile')]))" 2>/dev/null || echo "0")
    monitored=$(echo "$movie_data" | python3 -c "import json,sys; print(len([m for m in json.loads(sys.stdin.read()) if m.get('monitored')]))" 2>/dev/null || echo "0")
    
    ok "Movies: $total total, $has_file with file, $monitored monitored"
    JSON_RESULTS["radarr_movies"]="$total"
}

# ─── 4. Sonarr ─────────────────────────────────────────────────
check_sonarr() {
    header "Sonarr"
    
    local api_key
    api_key=$(docker exec sonarr cat /config/config.xml 2>/dev/null | \
        grep -o '<ApiKey>[^<]*</ApiKey>' | sed 's/<[^>]*>//g' || echo "")
    
    if [[ -z "$api_key" ]]; then
        warn "Cannot read API key"
        return
    fi
    
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "${SONARR_URL}/api/v3/system/status" -H "X-Api-Key: ${api_key}" 2>/dev/null || echo "000")
    
    if [[ "$code" == "200" ]]; then
        ok "API: accessible"
    else
        error "API: not responding (HTTP $code)"
        return
    fi
    
    # Count series
    local series_data
    series_data=$(curl -s --max-time 30 "${SONARR_URL}/api/v3/series" \
        -H "X-Api-Key: ${api_key}" 2>/dev/null || echo "[]")
    
    local total monitored
    total=$(echo "$series_data" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")
    monitored=$(echo "$series_data" | python3 -c "import json,sys; print(len([s for s in json.loads(sys.stdin.read()) if s.get('monitored')]))" 2>/dev/null || echo "0")
    
    ok "Series: $total total, $monitored monitored"
    JSON_RESULTS["sonarr_series"]="$total"
}

# ─── 5. TVHeadend ──────────────────────────────────────────────
check_tvheadend() {
    header "TVHeadend"
    
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --digest -u "${TVH_USER}:${TVH_PASS}" \
        --max-time 5 "${TVH_URL}/ping" 2>/dev/null || echo "000")
    
    if [[ "$code" == "200" ]]; then
        ok "Web UI: accessible"
    else
        error "Web UI: not responding (HTTP $code)"
        return
    fi
    
    # Count channels
    local channels
    channels=$(curl -s --digest -u "${TVH_USER}:${TVH_PASS}" --max-time 10 \
        "${TVH_URL}/api/channel/list" 2>/dev/null || echo '{"entries":[]}')
    
    local ch_count
    ch_count=$(echo "$channels" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('entries',[])))" 2>/dev/null || echo "0")
    ok "Channels: $ch_count"
    
    # Check active subscriptions
    local subs
    subs=$(curl -s --digest -u "${TVH_USER}:${TVH_PASS}" --max-time 10 \
        "${TVH_URL}/api/status/subscriptions" 2>/dev/null || echo '{"entries":[]}')
    
    local sub_count
    sub_count=$(echo "$subs" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('entries',[])))" 2>/dev/null || echo "0")
    
    if [[ "$sub_count" -gt 0 ]]; then
        ok "Active streams: $sub_count"
    fi
    
    # Check DVR upcoming
    local dvr
    dvr=$(curl -s --digest -u "${TVH_USER}:${TVH_PASS}" --max-time 10 \
        "${TVH_URL}/api/dvr/entry/grid_upcoming" 2>/dev/null || echo '{"entries":[]}')
    
    local dvr_count
    dvr_count=$(echo "$dvr" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('entries',[])))" 2>/dev/null || echo "0")
    
    ok "Upcoming recordings: $dvr_count"
    JSON_RESULTS["tvh_channels"]="$ch_count"
    JSON_RESULTS["tvh_streams"]="$sub_count"
    JSON_RESULTS["tvh_recordings"]="$dvr_count"
    
    # DVB adapter
    if [[ -d /dev/dvb/adapter0 ]]; then
        ok "DVB adapter: present"
    else
        error "DVB adapter: NOT FOUND"
    fi
}

# ─── 6. Disk usage ─────────────────────────────────────────────
check_disk() {
    header "Disk Usage"
    
    local mediastore_size
    mediastore_size=$(du -sh /mnt/mediastore 2>/dev/null | awk '{print $1}' || echo "?")
    ok "Media store: $mediastore_size used"
    
    # Breakdown
    for entry in "data/movies:Movies" "data/tv:TV Shows" "data/music:Music" "data/epg:EPG" "recordings:Recordings"; do
        local path="/mnt/mediastore/$(echo "$entry" | cut -d: -f1)"
        local name=$(echo "$entry" | cut -d: -f2)
        
        if [[ -d "$path" ]]; then
            local size count
            size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
            count=$(find "$path" -type f 2>/dev/null | wc -l)
            info "$name: $size ($count files)"
        fi
    done
    
    # System disk
    local root_usage
    root_usage=$(df -h / | tail -1 | awk '{print $5}')
    if [[ "${root_usage%\%}" -gt 90 ]]; then
        error "Root disk: $root_usage used (CRITICAL)"
    elif [[ "${root_usage%\%}" -gt 80 ]]; then
        warn "Root disk: $root_usage used"
    else
        ok "Root disk: $root_usage used"
    fi
}

# ─── 7. Network connectivity ───────────────────────────────────
check_network() {
    header "Network"
    
    local ports=("8096:Jellyfin" "7878:Radarr" "8989:Sonarr" "9981:TVHeadend" "9982:TVHeadend-HTSP" "8181:EPG-HTTP" "8050:TVH-Status")
    
    for entry in "${ports[@]}"; do
        local port name
        port=$(echo "$entry" | cut -d: -f1)
        name=$(echo "$entry" | cut -d: -f2)
        
        if nc -z -w2 127.0.0.1 "$port" 2>/dev/null; then
            ok "$name (port $port): listening"
        else
            warn "$name (port $port): not listening"
        fi
    done
}

# ─── Main ───────────────────────────────────────────────────────
if [[ "$OUTPUT_MODE" == "human" || "$OUTPUT_MODE" == "quick" ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║        Media Stack Healthcheck — $(date '+%Y-%m-%d %H:%M')       ║"
    echo "╚══════════════════════════════════════════════════════╝"
fi

check_containers
check_jellyfin
check_radarr
check_sonarr
check_tvheadend
check_disk
check_network

if [[ "$OUTPUT_MODE" == "human" || "$OUTPUT_MODE" == "quick" ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
        echo "🟢 ALL HEALTHY — No issues found"
    elif [[ $ERRORS -eq 0 ]]; then
        echo "🟡 $WARNINGS warning(s), 0 errors"
    else
        echo "🔴 $ERRORS error(s), $WARNINGS warning(s)"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

if [[ "$OUTPUT_MODE" == "json" ]]; then
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"errors\": $ERRORS,"
    echo "  \"warnings\": $WARNINGS,"
    for key in "${!JSON_RESULTS[@]}"; do
        echo "  \"$key\": \"${JSON_RESULTS[$key]}\","
    done | sed '$ s/,$//'
    echo "}"
fi

# Exit with error code if errors found
[[ $ERRORS -eq 0 ]] || exit 1
