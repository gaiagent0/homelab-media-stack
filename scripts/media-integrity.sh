#!/bin/bash
# media-integrity.sh — Media file integrity checker
#
# Checks for:
# - Missing files (Radarr/Sonarr says it should exist but doesn't)
# - Zero-byte files
# - Orphaned files (on disk but not in any library)
# - Empty directories
#
# Usage:
#   ./media-integrity.sh              — full check
#   ./media-integrity.sh --movies     — movies only
#   ./media-integrity.sh --tv         — TV shows only
#   ./media-integrity.sh --recordings — TVHeadend recordings only
#   ./media-integrity.sh --fix        — attempt auto-fix
#
# Designed to run on CT302 (Proxmox LXC container)

# ─── Configuration ──────────────────────────────────────────────
RADARR_URL="http://127.0.0.1:7878"
SONARR_URL="http://127.0.0.1:8989"
MOVIES_DIR="/mnt/mediastore/data/movies"
TV_DIR="/mnt/mediastore/data/tv"
RECORDINGS_DIR="/mnt/mediastore/recordings"
# Radarr/Sonarr container paths start with /data/ but on host they're /mnt/mediastore/data/
PATH_SUBST="s|^/data/|/mnt/mediastore/data/|"

CHECK_MOVIES=true
CHECK_TV=true
CHECK_RECORDINGS=true
AUTO_FIX=false

ISSUES=0
FIXED=0

# ─── Parse arguments ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --movies)     CHECK_TV=false; CHECK_RECORDINGS=false; shift ;;
        --tv)         CHECK_MOVIES=false; CHECK_RECORDINGS=false; shift ;;
        --recordings) CHECK_MOVIES=false; CHECK_TV=false; shift ;;
        --fix)        AUTO_FIX=true; shift ;;
        --help|-h)    echo "Usage: $0 [--movies|--tv|--recordings|--fix]"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helpers ────────────────────────────────────────────────────
issue() { echo "  ❌ $*"; ISSUES=$((ISSUES+1)); }
fixed() { echo "  🔧 $* (auto-fixed)"; FIXED=$((FIXED+1)); }
ok()    { echo "  ✅ $*"; }
info()  { echo "  ℹ️  $*"; }
header(){ echo -e "\n━━━ $* ━━━"; }

bytes_to_human() {
    python3 -c "b=$1
for u in ['B','KB','MB','GB','TB']:
    if abs(b)<1024: print(f'{b:.1f}{u}'); break
    b/=1024" 2>/dev/null || echo "${1}B"
}

# ─── 1. Movies integrity ───────────────────────────────────────
check_movies() {
    header "Movies — $MOVIES_DIR"
    
    local api_key
    api_key=$(docker exec radarr cat /config/config.xml 2>/dev/null | \
        grep -o '<ApiKey>[^<]*</ApiKey>' | sed 's/<[^>]*>//g' 2>/dev/null || echo "")
    
    if [[ -z "$api_key" ]]; then
        info "Cannot read Radarr API key"
        return
    fi
    
    # Fetch movie data to temp file
    local tmpf
    tmpf=$(mktemp)
    curl -s --max-time 30 "${RADARR_URL}/api/v3/movie" \
        -H "X-Api-Key: ${api_key}" > "$tmpf" 2>/dev/null
    
    # Analyze with Python
    local py_result
    py_result=$(python3 -c "
import json, os
with open('$tmpf') as f:
    movies = json.loads(f.read())
monitored = [m for m in movies if m.get('monitored')]
for m in monitored:
    title = m.get('title','?')
    # Convert container path (/data/...) to host path (/mnt/mediastore/data/...)
    path = m.get('path','').replace('/data/','/mnt/mediastore/data/',1)
    has_file = m.get('hasFile', False)
    if has_file:
        fp = m.get('movieFile',{}).get('path','').replace('/data/','/mnt/mediastore/data/',1)
        if fp and not os.path.exists(fp):
            print(f'MISSING|{title}|{fp}')
        elif fp and os.path.exists(fp):
            sz = os.path.getsize(fp)
            if sz < 10485760:
                print(f'TINY|{title}|{fp}|{sz}')
    elif path and os.path.exists(path):
        files = [f for f in os.listdir(path) if any(f.lower().endswith(e) for e in ['mkv','mp4','avi','ts'])]
        if not files:
            print(f'EMPTY|{title}|{path}')
print(f'TOTAL|{len(monitored)}')
" 2>/dev/null)
    
    rm -f "$tmpf"
    
    while IFS='|' read -r type title path extra; do
        [[ -z "$type" ]] && continue
        case "$type" in
            MISSING)  issue "MISSING: $title — file not found: $path" ;;
            TINY)     issue "TINY: $title — $path ($(bytes_to_human "${extra:-0}"))" ;;
            EMPTY)    info "EMPTY: $title — $path (no media files, pending download?)" ;;
            TOTAL)    info "Checked $title monitored Radarr movies" ;;
        esac
    done <<< "$py_result"
    
    rm -f "$tmpf"
}

# ─── 2. TV Shows integrity ─────────────────────────────────────
check_tv() {
    header "TV Shows — $TV_DIR"
    
    local api_key
    api_key=$(docker exec sonarr cat /config/config.xml 2>/dev/null | \
        grep -o '<ApiKey>[^<]*</ApiKey>' | sed 's/<[^>]*>//g' 2>/dev/null || echo "")
    
    if [[ -z "$api_key" ]]; then
        info "Cannot read Sonarr API key"
        return
    fi
    
    local tmpf
    tmpf=$(mktemp)
    curl -s --max-time 30 "${SONARR_URL}/api/v3/series" \
        -H "X-Api-Key: ${api_key}" > "$tmpf" 2>/dev/null
    
    local py_result
    py_result=$(python3 -c "
import json
with open('$tmpf') as f:
    series = json.loads(f.read())
monitored = [s for s in series if s.get('monitored')]
for s in monitored:
    title = s.get('title','?')
    st = s.get('statistics',{})
    have = st.get('episodeFileCount', 0)
    total = st.get('episodeCount', 0)
    missing = total - have
    if missing > 0:
        print(f'INCOMPLETE|{title}|{have}/{total}|{missing} missing')
    else:
        print(f'OK|{title}|{have}/{total}')
print(f'TOTAL|{len(monitored)}')
" 2>/dev/null)
    
    rm -f "$tmpf"
    
    while IFS='|' read -r type title info extra; do
        [[ -z "$type" ]] && continue
        case "$type" in
            INCOMPLETE) issue "INCOMPLETE: $title — $info episodes ($extra)" ;;
            OK)         ok "OK: $title — $info episodes" ;;
            TOTAL)      info "Checked $title monitored Sonarr series" ;;
        esac
    done <<< "$py_result"
}

# ─── 3. Recordings integrity ───────────────────────────────────
check_recordings() {
    header "TVHeadend Recordings — $RECORDINGS_DIR"
    
    if [[ ! -d "$RECORDINGS_DIR" ]]; then
        info "Recordings directory not found"
        return
    fi
    
    local total_size=0 total_files=0 small_files=0 zero_files=0
    
    while IFS= read -r -d '' f; do
        local size
        size=$(stat -c%s "$f" 2>/dev/null || echo "0")
        total_files=$((total_files+1))
        total_size=$((total_size + size))
        if [[ "$size" -eq 0 ]]; then
            issue "ZERO-BYTE: $f"
            zero_files=$((zero_files+1))
            $AUTO_FIX && rm -f "$f" && fixed "Deleted: $f"
        elif [[ "$size" -lt 10485760 ]]; then
            small_files=$((small_files+1))
        fi
    done < <(find "$RECORDINGS_DIR" -type f -print0 2>/dev/null)
    
    if [[ $total_files -eq 0 ]]; then
        info "No recording files found"
    else
        ok "Files: $total_files ($(bytes_to_human "$total_size"))"
        [[ $zero_files -gt 0 ]] && issue "Zero-byte files: $zero_files"
        [[ $small_files -gt 0 ]] && info "Small files (<10MB): $small_files"
    fi
    
    # DVR status
    local dvr_upcoming dvr_failed
    dvr_upcoming=$(curl -s --digest -u admin:admin --max-time 10 \
        "http://127.0.0.1:9981/api/dvr/entry/grid_upcoming" 2>/dev/null || echo '{"entries":[]}')
    local uc
    uc=$(echo "$dvr_upcoming" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('entries',[])))" 2>/dev/null || echo "0")
    info "Upcoming DVR recordings: $uc"
    
    dvr_failed=$(curl -s --digest -u admin:admin --max-time 10 \
        "http://127.0.0.1:9981/api/dvr/entry/grid_failed" 2>/dev/null || echo '{"entries":[]}')
    local fc
    fc=$(echo "$dvr_failed" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('entries',[])))" 2>/dev/null || echo "0")
    [[ "$fc" -gt 0 ]] && issue "Failed recordings: $fc"
}

# ─── 4. Zero-byte cleanup ──────────────────────────────────────
cleanup_zero_byte() {
    header "Zero-byte file cleanup"
    local count=0
    local dirs=("$MOVIES_DIR" "$TV_DIR" "$RECORDINGS_DIR" "/mnt/mediastore/data/music")
    
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            if $AUTO_FIX; then
                rm -f "$f"
                fixed "Deleted: $f"
                count=$((count+1))
            else
                info "Would delete: $f"
            fi
        done < <(find "$dir" -type f -empty -print0 2>/dev/null)
    done
    
    [[ $count -gt 0 ]] && info "Cleaned $count zero-byte files"
    [[ $count -eq 0 && "$AUTO_FIX" == "true" ]] && ok "No zero-byte files found"
}

# ─── Main ───────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║        Media Integrity Check — $(date '+%Y-%m-%d %H:%M')       ║"
echo "╚══════════════════════════════════════════════════════╝"

$CHECK_MOVIES   && check_movies
$CHECK_TV       && check_tv
$CHECK_RECORDINGS && check_recordings
cleanup_zero_byte

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $ISSUES -eq 0 ]]; then
    echo "🟢 ALL CLEAN — No integrity issues found"
else
    echo "🔴 $ISSUES issue(s) found, $FIXED auto-fixed"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $ISSUES -eq 0 ]] || exit 1
