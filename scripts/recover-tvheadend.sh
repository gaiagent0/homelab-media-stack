#!/usr/bin/env bash
# recover-tvheadend.sh — Teljes TVheadend recovery beragadt USB DVB driver esetén
#
# Használat:
#   pve-03-on futtatni: bash /root/recover-tvheadend.sh
#   Vagy SSH-ról:       ssh pve-03 'bash /root/recover-tvheadend.sh'
#
# Mit csinál:
#   1. Leállítja a tvheadend container-t CT302-ben
#   2. USB DVB tuner unbind/bind a pve-03 hoszton
#   3. CT302 teljes LXC restart
#   4. Docker container újraindítás
#   5. Adapter detection és signal teszt
#   6. EPG frissítés ha szükséges
#
set -euo pipefail

CT=302
USB_PORT="4-1"
TVH_API="http://127.0.0.1:9981"
TVH_COMPOSE="/opt/tvheadend"

# Telegram webhook (állítsd be a saját bot token + chat ID-det)
# Pl: https://api.telegram.org/bot<BOT_TOKEN>/sendMessage?chat_id=<CHAT_ID>
TELEGRAM_WEBHOOK="${TELEGRAM_WEBHOOK:-}"  # Environment variable-ból, vagy ideírd egyenesen

# Színek
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[HIBA]${NC} $*"; }
step()  { echo -e "\n${GREEN}=== $* ===${NC}"; }

# ─── Előellenőrzés ──────────────────────────────────────────────
step "1/7 Előellenőrzés"

send_telegram() {
    if [ -n "$TELEGRAM_WEBHOOK" ]; then
        local MSG="$1"
        curl -s -X POST "$TELEGRAM_WEBHOOK" \
            -d chat_id="$(echo "$TELEGRAM_WEBHOOK" | grep -oP 'chat_id=\K[^&]+')" \
            -d text="$MSG" \
            -d parse_mode="Markdown" \
            > /dev/null 2>&1 || true
    fi
}

if ! command -v pct &>/dev/null; then
    error "Ezt a scriptet a pve-03 Proxmox hoszon kell futtatni!"
    send_telegram "❌ *TVheadend Recovery Sikertelen*

Hiba: Nem Proxmox hoszton fut!\n🕐 $(date '+%Y-%m-%d %H:%M:%S')"
    exit 1
fi

if ! lsusb | grep -qi hauppauge; then
    error "Hauppauge USB tuner nem található!"
    exit 1
fi
log "Hauppauge tuner: $(lsusb | grep -i hauppauge)"

if ! pct status "$CT" &>/dev/null; then
    error "CT${CT} nem található!"
    exit 1
fi
log "CT${CT}状态: $(pct status "$CT")"

# ─── Step 2: TVheadend leállítás ────────────────────────────────
step "2/7 TVheadend container leállítása"

if pct exec "$CT" -- docker ps --format '{{.Names}}' | grep -q tvheadend; then
    pct exec "$CT" -- docker stop tvheadend
    log "TVheadend container leállítva"
else
    warn "TVheadend container nem fut"
fi

# ─── Step 3: USB unbind/bind ────────────────────────────────────
step "3/7 USB DVB driver unbind/bind ($USB_PORT)"

# Mentsük el a device state-et előtte
BEFORE_USB=$(lsusb | grep -i hauppauge || true)

echo "$USB_PORT" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || warn "unbind hiba (lehetséges, hogy már le volt választva)"
sleep 3

echo "$USB_PORT" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || { error "USB bind sikertelen!"; send_telegram "❌ *TVheadend Recovery Sikertelen*

Hiba: USB bind sikertelen!\nPort: $USB_PORT\n🕐 $(date '+%Y-%m-%d %H:%M:%S')"; exit 1; }
sleep 8

AFTER_USB=$(lsusb | grep -i hauppauge || true)
if [ -z "$AFTER_USB" ]; then
    error "USB tuner nem jelent meg újra bind után!"
    exit 1
fi
log "USB újrakötve: $AFTER_USB"

# Ellenőrizzük a DVB device node-okat
if [ ! -e /dev/dvb/adapter0/frontend0 ]; then
    error "DVB frontend0 nem jelent meg a hoszton!"
    exit 1
fi
log "DVB device node-ok: $(ls /dev/dvb/adapter0/)"

# ─── Step 4: CT302 teljes restart ───────────────────────────────
step "4/7 CT${CT} teljes LXC restart"

pct stop "$CT"
sleep 5
pct start "$CT"
log "CT${CT} elindítva, várakozás a hálózatra..."

# Várakozás a hálózat készenlétére (max 60 mp)
WAIT=0
MAX_WAIT=60
while [ $WAIT -lt $MAX_WAIT ]; do
    if pct exec "$CT" -- true &>/dev/null; then
        break
    fi
    sleep 2
    WAIT=$((WAIT + 2))
done

if [ $WAIT -ge $MAX_WAIT ]; then
    error "CT${CT} nem válaszol ${MAX_WAIT} mp után!"
    exit 1
fi
log "CT${CT} elérhető (${WAIT}s)"

# Extra várakozás a Docker daemonnak
sleep 15
log "Docker daemon kész"

# ─── Step 5: Docker container újraindítás ───────────────────────
step "5/7 TVheadend Docker container újraindítása"

pct exec "$CT" -- bash -c "cd $TVH_COMPOSE && docker compose up -d"
sleep 10

# Ellenőrizzük a container állapotot
CONTAINER_STATUS=$(pct exec "$CT" -- docker ps --filter "name=tvheadend" --format '{{.Status}}')
if echo "$CONTAINER_STATUS" | grep -qi "up"; then
    log "TVheadend container: $CONTAINER_STATUS"
else
    error "TVheadend container nem indult el!"
    pct exec "$CT" -- docker logs tvheadend --tail 20
    exit 1
fi

# ─── Step 6: Adapter detection teszt ────────────────────────────
step "6/7 Adapter detection és signal teszt"

# Ellenőrizzük, hogy a container belül elérhető-e a DVB device
DEVICE_TEST=$(pct exec "$CT" -- docker exec --user root tvheadend python3 -c "
try:
    f = open('/dev/dvb/adapter0/frontend0', 'rb')
    f.close()
    print('OK')
except Exception as e:
    print(f'FAIL: {e}')
" 2>&1)

if echo "$DEVICE_TEST" | grep -q "OK"; then
    log "DVB device elérhető a containerben"
else
    error "DVB device NEM elérhető a containerben: $DEVICE_TEST"
    warn "Ellenőrizd a docker-compose.yml-t: devices: szekcióban kell lennie a /dev/dvb-nek!"
    exit 1
fi

# Ellenőrizzük az adapter státuszt
sleep 5
ADAPTER_STATUS=$(curl -s "$TVH_API/api/status/inputs" 2>/dev/null || pct exec "$CT" -- curl -s "$TVH_API/api/status/inputs" 2>/dev/null)
TOTAL_ADAPTERS=$(echo "$ADAPTER_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo "0")

if [ "$TOTAL_ADAPTERS" -gt 0 ]; then
    log "Adapter észlelve: $TOTAL_ADAPTERS adapter"
    echo "$ADAPTER_STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for e in d.get('entries', []):
    print(f\"  Input: {e.get('input')}\")
    print(f\"  Stream: {e.get('stream', 'n/a')}\")
    print(f\"  Signal: {e.get('signal', 0)/1000:.1f} dBm\")
    print(f\"  SNR: {e.get('snr', 0)/1000:.1f} dB\")
    print(f\"  BER: {e.get('ber', 0)}\")
" 2>/dev/null || warn "Signal adatok nem olvashatók"
else
    error "NINCS adapter észlelve a TVheadend-ben!"
    warn "Ellenőrizd a TVheadend webUI-t: http://10.10.40.32:9981"
    exit 1
fi

# ─── Step 7: EPG ellenőrzés ─────────────────────────────────────
step "7/7 EPG ellenőrzés"

EPG_SIZE=$(pct exec "$CT" -- stat -c%s /opt/tvheadend/config/data/guide.xml 2>/dev/null || echo "0")
if [ "$EPG_SIZE" -gt 1000 ]; then
    log "guide.xml: $(numfmt --to=iec $EPG_SIZE)"
else
    warn "guide.xml méret: ${EPG_SIZE} byte — frissítés szükséges!"
    pct exec "$CT" -- /opt/tvheadend/epg_update.sh
    NEW_SIZE=$(pct exec "$CT" -- stat -c%s /opt/tvheadend/config/data/guide.xml 2>/dev/null || echo "0")
    log "guide.xml frissítve: $(numfmt --to=iec $NEW_SIZE)"

    # EPG re-run
    pct exec "$CT" -- curl -s -X POST "$TVH_API/api/epggrab/internal/rerun" -d "rerun=1" 2>/dev/null
    log "EPG grabber újrafuttatva"
fi

# ─── Összefoglalás ──────────────────────────────────────────────
step "✓ RECOVERY KÉSZ"
echo ""
echo "  TVheadend:  http://10.10.40.32:9981"
echo "  HTSP:       http://10.10.40.32:9982"
echo "  Adapter:    $TOTAL_ADAPTERS db"
echo "  EPG:        $(numfmt --to=iec ${EPG_SIZE:-0})"
echo ""
echo "  Ha a csatornák továbbra sem működnek:"
echo "  1. Nyisd meg a TVheadend webUI-t"
echo "  2. Configuration → DVB Inputs → Networks"
echo "  3. Ellenőrizd, hogy a hálózat megvan és az idlescan ki van kapcsolva"
echo "  4. Configuration → DVB Inputs → Services → Map all services"

# ─── Telegram értesítés ────────────────────────────────────────
if [ -n "$TELEGRAM_WEBHOOK" ]; then
    MSG="✅ *TVheadend Recovery Kész*
"
    MSG+="\n📦 CT${CT} újraindítva
"
    MSG+="🔌 Adapter: ${TOTAL_ADAPTERS} db
"
    MSG+="📺 EPG: $(numfmt --to=iec ${EPG_SIZE:-0})
"
    MSG+="🕐 $(date '+%Y-%m-%d %H:%M:%S')"

    curl -s -X POST "$TELEGRAM_WEBHOOK" \
        -d chat_id="$(echo "$TELEGRAM_WEBHOOK" | grep -oP 'chat_id=\K[^&]+')" \
        -d text="$MSG" \
        -d parse_mode="Markdown" \
        > /dev/null 2>&1 || warn "Telegram értesítés sikertelen"
    log "Telegram értesítés elküldve"
fi
