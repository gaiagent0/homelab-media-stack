#!/usr/bin/env bash
# fix-epg.sh — EPG healthcheck és javítás TVheadend-hez
#
# Használat:
#   CT302-n:    bash /opt/tvheadend/fix-epg.sh
#   pve-03-ról: ssh pve-03 'pct exec 302 -- bash /opt/tvheadend/fix-epg.sh'
#
# Mit csinál:
#   1. Ellenőrzi a guide.xml méretét és XML validitását
#   2. Ellenőrzi a /config/data/ mappában lévő XML fájlok számát
#   3. Ellenőrzi a hd_dedupe_epg.py meglétét és hívását az epg_update.sh-ban
#   4. Szükség esetén frissíti az EPG-t
#   5. Újraimportálja a guide.xml-t a TVheadend-be
#
set -euo pipefail

TVH_API="http://127.0.0.1:9981"
CONFIG_DIR="/opt/tvheadend/config"
DATA_DIR="${CONFIG_DIR}/data"
EPG_SCRIPT="/opt/tvheadend/epg_update.sh"
DEDUPE_SCRIPT="/opt/tvheadend/hd_dedupe_epg.py"
JELLYFIN_EPG="/mnt/mediastore/data/epg/guide.xml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ISSUES=0

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[FIGYELMEZTETÉS]${NC} $*"; ISSUES=$((ISSUES+1)); }
error() { echo -e "${RED}[HIBA]${NC} $*"; ISSUES=$((ISSUES+1)); }
step()  { echo -e "\n${GREEN}── $* ──${NC}"; }

# ─── 1. guide.xml ellenőrzés ────────────────────────────────────
step "1. guide.xml fájl ellenőrzése"

EPG_FILE="${DATA_DIR}/guide.xml"
if [ ! -f "$EPG_FILE" ]; then
    error "guide.xml NEM LÉTEZIK: $EPG_FILE"
else
    EPG_SIZE=$(stat -c%s "$EPG_FILE" 2>/dev/null || echo "0")
    if [ "$EPG_SIZE" -eq 0 ]; then
        error "guide.xml ÜRES (0 byte)!"
    elif [ "$EPG_SIZE" -lt 1000000 ]; then
        warn "guide.xml túl kicsi: $(numfmt --to=iec $EPG_SIZE) — valószínűleg hibás"
    else
        log "guide.xml: $(numfmt --to=iec $EPG_SIZE)"
    fi
fi

# ─── 2. XML validitás ──────────────────────────────────────────
step "2. XML validitás ellenőrzése"

if [ -f "$EPG_FILE" ] && [ "$EPG_SIZE" -gt 0 ]; then
    XML_VALID=$(python3 -c "
import xml.etree.ElementTree as ET
try:
    ET.parse('$EPG_FILE')
    print('VALID')
except ET.ParseError as e:
    print(f'INVALID: {e}')
except Exception as e:
    print(f'ERROR: {e}')
" 2>&1)

    if echo "$XML_VALID" | grep -q "VALID"; then
        log "XML valid"
    else
        error "XML érvénytelen: $XML_VALID"
    fi

    # Ellenőrzés: több root <tv> elem (több XML összefűzése)
    TV_COUNT=$(grep -c '<tv ' "$EPG_FILE" 2>/dev/null || echo "0")
    if [ "$TV_COUNT" -gt 1 ]; then
        error "Több <tv> gyökérelem ($TV_COUNT) — érvénytelen XML! Ellenőrizd a /config/data/ mappát!"
    fi

    # Ellenőrzés: escapeletlen & karakterek
    AMP_COUNT=$(grep -oP '(?<!\&amp;)(?<!\&lt;)(?<!\&gt;)(?<!\&quot;)(?<!\&apos;)\&(?!amp;|lt;|gt;|quot;|apos;|#)' "$EPG_FILE" 2>/dev/null | wc -l || echo "0")
    if [ "$AMP_COUNT" -gt 0 ]; then
        warn "Escapeletlen & karakterek találhatók ($AMP_COUNT) — XML hibákat okozhat"
    fi
fi

# ─── 3. XML fájlok száma a data mappában ───────────────────────
step "3. XML fájlok száma a /config/data/ mappában"

XML_COUNT=$(find "$DATA_DIR" -maxdepth 1 -name "*.xml" 2>/dev/null | wc -l)
if [ "$XML_COUNT" -eq 0 ]; do
    error "Nincs .xml fájl a data mappában!"
elif [ "$XML_COUNT" -eq 1 ]; then
    log "Pontosan 1 XML fájl (helyes)"
else
    error "$XML_COUNT XML fájl van a data mappában — a tv_grab_file mindegyiket összefűzi, ami érvénytelen XML-t eredményez!"
    find "$DATA_DIR" -maxdepth 1 -name "*.xml" -exec ls -la {} \;
    echo ""
    warn "Töröld a fölösleges XML fájlokat, csak a guide.xml maradjon!"
fi

# ─── 4. hd_dedupe_epg.py ellenőrzés ────────────────────────────
step "4. hd_dedupe_epg.py ellenőrzése"

if [ -f "$DEDUPE_SCRIPT" ]; then
    log "hd_dedupe_epg.py létezik"

    # Ellenőrzés: van-e xml_escape az ALIASES-ben
    if grep -q "xml_escape" "$DEDUPE_SCRIPT"; then
        log "xml_escape használva az alias-nevekhez"
    else
        warn "NINCS xml_escape a hd_dedupe_epg.py-ban — a '&'-t tartalmazó nevek elronthatják a guide.xml-t!"
    fi

    # Ellenőrzés: van-e ALIASES szótár
    if grep -q "ALIASES" "$DEDUPE_SCRIPT"; then
        ALIAS_COUNT=$(grep -c "'" "$DEDUPE_SCRIPT" 2>/dev/null || echo "0")
        log "ALIASES szótár jelen van (~$((ALIAS_COUNT/2)) alias)"
    else
        warn "Nincs ALIASES szótár a hd_dedupe_epg.py-ban — egyes csatornáknak nem lesz EPG-je"
    fi
else
    error "hd_dedupe_epg.py NEM LÉTEZIK: $DEDUPE_SCRIPT"
fi

# ─── 5. epg_update.sh ellenőrzés ────────────────────────────────
step "5. epg_update.sh ellenőrzése"

if [ -f "$EPG_SCRIPT" ]; then
    log "epg_update.sh létezik"

    # Ellenőrzés: tartalmazza-e a hd_dedupe_epg.py hívást
    if grep -q "hd_dedupe_epg.py" "$EPG_SCRIPT"; then
        log "hd_dedupe_epg.py hívás benne van az epg_update.sh-ban"
    else
        error "hd_dedupe_epg.py NINCS meghívva az epg_update.sh-ban! A napi EPG frissítés HD-dedupe nélkül fut!"
    fi

    # Ellenőrzés: cp guide.xml a Jellyfin-nek
    if grep -q "cp.*guide.xml.*epg" "$EPG_SCRIPT"; then
        log "guide.xml másolás a Jellyfin-nek benne van"
    else
        warn "guide.xml másolás a Jellyfin mappába hiányzik az epg_update.sh-ból"
    fi
else
    error "epg_update.sh NEM LÉTEZIK: $EPG_SCRIPT"
fi

# ─── 6. Cron ellenőrzés ────────────────────────────────────────
step "6. Cron beállítás ellenőrzése"

CRON_FILE="/etc/cron.d/tvheadend"
if [ -f "$CRON_FILE" ]; then
    CRON_CONTENT=$(cat "$CRON_FILE")
    if echo "$CRON_CONTENT" | grep -q "epg_update"; then
        log "Cron aktív: $(echo "$CRON_CONTENT" | tr -s ' ')"
    else
        warn "Cron fájl létezik, de nem hívja az epg_update.sh-t!"
    fi
else
    warn "Nincs /etc/cron.d/tvheadend cron fájl!"
fi

# ─── 7. Jellyfin EPG ellenőrzés ────────────────────────────────
step "7. Jellyfin EPG másolat ellenőrzése"

if [ -f "$JELLYFIN_EPG" ]; then
    JE_SIZE=$(stat -c%s "$JELLYFIN_EPG" 2>/dev/null || echo "0")
    if [ "$JE_SIZE" -gt 1000000 ]; then
        log "Jellyfin guide.xml: $(numfmt --to=iec $JE_SIZE)"
    else
        warn "Jellyfin guide.xml kicsi: $(numfmt --to=iec $JE_SIZE)"
    fi
else
    warn "Jellyfin guide.xml NEM LÉTEZIK: $JELLYFIN_EPG"
fi

# ─── 8. EPG broadcast szám ──────────────────────────────────────
step "8. EPG broadcast szám (EPGDB)"

EPGDB_SIZE=$(stat -c%s "${CONFIG_DIR}/epgdb.v3" 2>/dev/null || echo "0")
if [ "$EPGDB_SIZE" -gt 100000 ]; then
    log "epgdb.v3: $(numfmt --to=iec $EPGDB_SIZE)"
else
    warn "epgdb.v3 kicsi vagy hiányzik: $(numfmt --to=iec $EPGDB_SIZE)"
fi

# ─── Összefoglalás ──────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$ISSUES" -eq 0 ]; then
    echo -e "${GREEN}✓ EPH HEALTHCHECK: MINDEN RENDBEN${NC}"
else
    echo -e "${YELLOW}⚠ EPH HEALTHCHECK: $ISSUES PROBLÉMA TALÁLVA${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$ISSUES" -gt 0 ]; then
    echo ""
    echo "Javítás futtatása? (letöltés + dedupe + import)"
    read -p "Igen/Nem [i/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ii]$ ]]; then
        echo ""
        step "Javítás: EPG frissítés"

        if [ -f "$EPG_SCRIPT" ]; then
            bash "$EPG_SCRIPT"
            log "EPG frissítés kész"

            # EPG re-run
            curl -s -X POST "$TVH_API/api/epggrab/internal/rerun" -d "rerun=1" 2>/dev/null || \
                pct exec 302 -- curl -s -X POST "$TVH_API/api/epggrab/internal/rerun" -d "rerun=1" 2>/dev/null || true
            log "EPG grabber újrafuttatva"
        else
            error "epg_update.sh nem található — kézi frissítés szükséges!"
        fi
    fi
fi
