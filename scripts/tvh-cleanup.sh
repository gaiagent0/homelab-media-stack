#!/bin/bash
# TVHeadend Recording Auto-Cleanup
# - Törli a régi/szemetet felvételeket
# - Megtartja a kívánt sorozatokat
# - Automatikusan fut cron-ból
#
# Használat: 
#   /opt/tvheadend/scripts/tvh-cleanup.sh          (cron futtatás)
#   /opt/tvheadend/scripts/tvh-cleanup.sh --dry-run (csak listázás)
#   /opt/tvheadend/scripts/tvh-cleanup.sh --show-size (méret kijelzés)
#
# Konfiguráció: /opt/tvheadend/scripts/tvh-cleanup.conf

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/tvh-cleanup.conf"
LOG_FILE="/opt/tvheadend/logs/tvh-cleanup.log"

# Alapértelmezett beállítások
RECORDINGS_DIR="/recordings"
KEEP_DAYS=30
MIN_SIZE_MB=50
DRY_RUN=false
SHOW_SIZE=false

# Megtartandó sorozatok (case-insensitive)
KEEP_SERIES=(
    "Az elefántok titkai"
)

# Törlendő sorozatok (case-insensitive)
DELETE_SERIES=(
    "Linda"
    "Barátok közt"
    "Heartland"
    "Jóban Rosszban"
)

# Naplózás
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

# Konfiguráció betöltése
if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
fi

# CLI argumentumok
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --show-size) SHOW_SIZE=true; shift ;;
        --keep-days) KEEP_DAYS="$2"; shift 2 ;;
        --help|-h)
            echo "TVHeadend Recording Auto-Cleanup"
            echo "Használat: $0 [--dry-run] [--show-size] [--keep-days NAP]"
            exit 0
            ;;
        *) shift ;;
    esac
done

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

log "=== TVHeadend Recording Cleanup kezdődik ==="

# Mappa méret kijelzés
if $SHOW_SIZE; then
    echo ""
    echo "=== Recordings méret ==="
    du -sh "$RECORDINGS_DIR"/* 2>/dev/null
    echo ""
    echo "=== Összes felvétel ==="
    find "$RECORDINGS_DIR" -type f -name "*.ts" -o -name "*.mp4" -o -name "*.mkv" | while read f; do
        size=$(du -h "$f" | cut -f1)
        echo "  $size  $(basename "$(dirname "$f")")/$(basename "$f")"
    done
    echo ""
fi

# Ellenőrzés: megtartandó sorozatok
echo ""
echo "=== Megtartandó sorozatok ==="
for series in "${KEEP_SERIES[@]}"; do
    found=$(find "$RECORDINGS_DIR" -maxdepth 2 -iname "*$series*" -type d 2>/dev/null)
    if [ -n "$found" ]; then
        count=$(find "$found" -type f 2>/dev/null | wc -l)
        echo "  ✅ $series ($count fájl)"
    else
        echo "  ⚠️  $series (nincs a lemezen)"
    fi
done

# Törlendő sorozatok
echo ""
echo "=== Törlendő szemetet ==="
deleted=0
freed=0

# 1. Explicit törlendő sorozatok
for series in "${DELETE_SERIES[@]}"; do
    found=$(find "$RECORDINGS_DIR" -maxdepth 2 -iname "*$series*" -type d 2>/dev/null)
    if [ -n "$found" ]; then
        for dir in $found; do
            size=$(du -sb "$dir" 2>/dev/null | cut -f1)
            size_mb=$((size / 1024 / 1024))
            echo "  🗑️  $(basename "$dir") (${size_mb}MB)"
            if ! $DRY_RUN; then
                rm -rf "$dir"
                log "törölve: $dir (${size_mb}MB)"
            fi
            deleted=$((deleted + 1))
            freed=$((freed + size_mb))
        done
    fi
done

# 2. Régi felvételek (KEEP_DAYS napnál régebbiek)
echo ""
echo "=== Régi felvételek (${KEEP_DAYS} napnál régebbiek) ==="
old_count=0
while IFS= read -r f; do
    if [ -n "$f" ]; then
        basename_f=$(basename "$f")
        dirname_f=$(basename "$(dirname "$f")")
        # Csak a "nem megtartandó" sorozatokat töröljük
        is_keep=false
        for series in "${KEEP_SERIES[@]}"; do
            if echo "$dirname_f" | grep -qi "$series"; then
                is_keep=true
                break
            fi
        done
        
        if ! $is_keep; then
            size=$(du -sb "$f" 2>/dev/null | cut -f1)
            size_mb=$((size / 1024 / 1024))
            if [ "$size_mb" -lt "$MIN_SIZE_MB" ]; then
                echo "  🗑️  ${dirname_f}/${basename_f} (${size_mb}MB - túl kicsi)"
                if ! $DRY_RUN; then
                    rm -f "$f"
                    log "törölve (kicsi): $f"
                fi
                old_count=$((old_count + 1))
                freed=$((freed + size_mb))
            fi
        fi
    fi
done < <(find "$RECORDINGS_DIR" -type f \( -name "*.ts" -o -name "*.mp4" -o -name "*.mkv" \) -mtime +$KEEP_DAYS 2>/dev/null)

# 3. Üres mappák törlése
echo ""
echo "=== Üres mappák ==="
empty_count=0
while IFS= read -r d; do
    if [ -n "$d" ] && [ "$d" != "$RECORDINGS_DIR" ]; then
        count=$(find "$d" -type f 2>/dev/null | wc -l)
        if [ "$count" -eq 0 ]; then
            echo "  🗑️  $(basename "$d") (üres)"
            if ! $DRY_RUN; then
                rmdir "$d" 2>/dev/null
                log "törölve (üres): $d"
            fi
            empty_count=$((empty_count + 1))
        fi
    fi
done < <(find "$RECORDINGS_DIR" -maxdepth 2 -type d 2>/dev/null)

# Összegzés
echo ""
echo "=== Összegzés ==="
echo "  Törölt sorozatok: $deleted"
echo "  Törölt régi/kicsi: $old_count"
echo "  Törölt üres mappák: $empty_count"
echo "  Felszabadított hely: ~${freed}MB"
echo ""

# Maradék
echo "=== Maradék felvételek ==="
find "$RECORDINGS_DIR" -type f 2>/dev/null | while read f; do
    size=$(du -h "$f" | cut -f1)
    echo "  ✅ $size  $(basename "$(dirname "$f")")/$(basename "$f")"
done

remaining=$(find "$RECORDINGS_DIR" -type f 2>/dev/null | wc -l)
if [ "$remaining" -eq 0 ]; then
    echo "  (nincsenek felvételek)"
fi

log "=== Cleanup befejeződött: $deleted törölt, ${freed}MB felszabadítva ==="
