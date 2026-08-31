#!/bin/bash
# monitor-tvheadend.sh — Prometheus metrics exporter for TVheadend
#
# Outputs Prometheus-compatible metrics to stdout or a file.
# Designed to be run by a cron job or a Prometheus textfile collector.
#
# Metrics exported:
#   tvh_adapter_signal_strength_dbm — Signal strength in dBm
#   tvh_adapter_snr_db — Signal-to-noise ratio in dB
#   tvh_adapter_ber — Bit error rate
#   tvh_adapter_unc_errors — Uncorrectable errors
#   tvh_adapter_active — Whether adapter is active (1=yes, 0=no)
#   tvh_channel_count — Total number of channels
#   tvh_channel_active_count — Currently active/scheduled channels
#   tvh_epg_broadcasts — Number of EPG broadcasts
#   tvh_epg_size_bytes — Size of guide.xml in bytes
#   tvh_dvr_upcoming_count — Upcoming DVR recordings
#   tvh_subscription_count — Active streaming subscriptions
#   tvh_container_healthy — Docker healthcheck status (1=healthy, 0=unhealthy)
#   tvh_uptime_seconds — TVheadend process uptime
#
# Usage:
#   ./monitor-tvheadend.sh                  — print to stdout
#   ./monitor-tvheadend.sh > /tmp/tvh.prom  — write to file (for node_exporter textfile collector)
#
# Cron example (every 2 minutes):
#   */2 * * * * /opt/tvheadend/monitor-tvheadend.sh > /opt/tvheadend/tvh.prom 2>/dev/null

set -euo pipefail

TVH_API="http://127.0.0.1:9981"
PROM_FILE="${1:-}"  # optional output file

# ─── Helper functions ──────────────────────────────────────────
api_get() {
    curl -s --digest -u admin:admin --max-time 5 "${TVH_API}$1" 2>/dev/null || echo ""
}

# ─── 1. Docker healthcheck status ─────────────────────────────
HEALTHY=0
if docker inspect tvheadend --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
    HEALTHY=1
fi
echo "# HELP tvh_container_healthy Docker healthcheck status"
echo "# TYPE tvh_container_healthy gauge"
echo "tvh_container_healthy $HEALTHY"

# Early exit if container is not healthy
if [ "$HEALTHY" -eq 0 ]; then
    echo "# HELP tvh_adapter_active Adapter active status"
    echo "# TYPE tvh_adapter_active gauge"
    echo "tvh_adapter_active 0"
    echo "# HELP tvh_channel_count Total channels"
    echo "# TYPE tvh_channel_count gauge"
    echo "tvh_channel_count 0"
    exit 0
fi

# ─── 2. Adapter signal quality (from Docker logs — last known values) ──────
# TVheadend 4.3 doesn't expose signal via a simple API endpoint,
# so we parse dmesg/log output for the last known values.

ADAPTER_EXISTS=0
if [ -e /dev/dvb/adapter0/frontend0 ]; then
    ADAPTER_EXISTS=1
fi

echo "# HELP tvh_adapter_active Whether DVB adapter device exists"
echo "# TYPE tvh_adapter_active gauge"
echo "tvh_adapter_active $ADAPTER_EXISTS"

# Signal stats from docker logs (last 200 lines, grep for signal-related entries)
SIGNAL_DBM=0
SNR_DB=0
BER=0
UNC=0

LOG_TAIL=$(docker logs tvheadend --tail 200 2>/dev/null || true)

# Try to extract signal from log (format: "signal ... dBm", "snr ... dB")
if echo "$LOG_TAIL" | grep -q "signal_strength"; then
    SIGNAL_DBM=$(echo "$LOG_TAIL" | grep -oP 'signal_strength[":\s]+(-?\d+\.?\d*)' | tail -1 | grep -oP '[-\d.]+$' || echo "0")
fi

# For signal/SNR/BER/UNC we can try reading from the device via dvb-fe-tool if available
if command -v dvb-fe-tool &>/dev/null && [ "$ADAPTER_EXISTS" -eq 1 ]; then
    FE_INFO=$(dvb-fe-tool 2>/dev/null || true)
    if [ -n "$FE_INFO" ]; then
        SIGNAL_DBM=$(echo "$FE_INFO" | grep -oP 'signal.*?(-?\d+\.?\d*)' | head -1 | grep -oP '[-\d.]+$' || echo "$SIGNAL_DBM")
        SNR_DB=$(echo "$FE_INFO" | grep -oP 'SNR.*?(\d+\.?\d*)' | head -1 | grep -oP '[\d.]+$' || echo "$SNR_DB")
        BER=$(echo "$FE_INFO" | grep -oP 'BER.*?(\d+)' | head -1 | grep -oP '\d+$' || echo "$BER")
        UNC=$(echo "$FE_INFO" | grep -oP 'UNC.*?(\d+)' | head -1 | grep -oP '\d+$' || echo "$UNC")
    fi
fi

# Alternative: read signal from a streaming test (quick probe)
if [ "$ADAPTER_EXISTS" -eq 1 ] && [ "$SIGNAL_DBM" = "0" ] && [ "$SNR_DB" = "0" ]; then
    # Start a quick stream to activate the tuner, then read signal
    CHANNELS_JSON=$(api_get "/api/channel/list")
    FIRST_UUID=$(echo "$CHANNELS_JSON" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    for e in d.get('entries', []):
        print(e['key'])
        break
except: pass
" 2>/dev/null || echo "")

    if [ -n "$FIRST_UUID" ]; then
        # Start background stream
        (curl -s --max-time 4 "${TVH_API}/stream/channel/${FIRST_UUID}" -o /dev/null 2>/dev/null) &
        STREAM_PID=$!
        sleep 2

        # Try to get signal info from dmesg (kernel messages for DVB)
        DMESG_TAIL=$(dmesg | tail -30 2>/dev/null || true)
        if echo "$DMESG_TAIL" | grep -q "signal"; then
            SNR_DB=$(echo "$DMESG_TAIL" | grep -oP 'SNR[:\s]+(\d+)' | tail -1 | grep -oP '\d+$' || echo "$SNR_DB")
        fi

        wait $STREAM_PID 2>/dev/null || true
    fi
fi

echo "# HELP tvh_adapter_signal_strength_dbm Signal strength in dBm"
echo "# TYPE tvh_adapter_signal_strength_dbm gauge"
echo "tvh_adapter_signal_strength_dbm $SIGNAL_DBM"

echo "# HELP tvh_adapter_snr_db Signal-to-noise ratio in dB"
echo "# TYPE tvh_adapter_snr_db gauge"
echo "tvh_adapter_snr_db $SNR_DB"

echo "# HELP tvh_adapter_ber Bit error rate"
echo "# TYPE tvh_adapter_ber gauge"
echo "tvh_adapter_ber $BER"

echo "# HELP tvh_adapter_unc_errors Uncorrectable errors"
echo "# TYPE tvh_adapter_unc_errors counter"
echo "tvh_adapter_unc_errors $UNC"

# ─── 3. Channel count ─────────────────────────────────────────
CHANNELS_JSON=$(api_get "/api/channel/list")
TOTAL_CHANNELS=$(echo "$CHANNELS_JSON" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(len(d.get('entries', [])))
except: print(0)
" 2>/dev/null || echo "0")

echo "# HELP tvh_channel_count Total number of configured channels"
echo "# TYPE tvh_channel_count gauge"
echo "tvh_channel_count $TOTAL_CHANNELS"

# ─── 4. EPG stats ─────────────────────────────────────────────
EPG_SIZE=0
if [ -f /opt/tvheadend/config/data/guide.xml ]; then
    EPG_SIZE=$(stat -c%s /opt/tvheadend/config/data/guide.xml 2>/dev/null || echo "0")
fi

echo "# HELP tvh_epg_size_bytes Size of guide.xml in bytes"
echo "# TYPE tvh_epg_size_bytes gauge"
echo "tvh_epg_size_bytes $EPG_SIZE"

# EPG broadcast count from epgdb
EPGDB_SIZE=0
if [ -f /opt/tvheadend/config/epgdb.v3 ]; then
    EPGDB_SIZE=$(stat -c%s /opt/tvheadend/config/epgdb.v3 2>/dev/null || echo "0")
fi

echo "# HELP tvh_epg_database_size_bytes Size of EPG database in bytes"
echo "# TYPE tvh_epg_database_size_bytes gauge"
echo "tvh_epg_database_size_bytes $EPGDB_SIZE"

# ─── 5. Subscription count (from status.xml) ───────────────────
SUBS=0
STATUS_XML=$(curl -s --max-time 5 "${TVH_API}/status.xml" 2>/dev/null || true)
if [ -n "$STATUS_XML" ]; then
    SUBS=$(echo "$STATUS_XML" | grep -oP '<subscriptions>\K\d+' || echo "0")
fi

echo "# HELP tvh_subscription_count Active streaming subscriptions"
echo "# TYPE tvh_subscription_count gauge"
echo "tvh_subscription_count $SUBS"

# ─── 6. Uptime ────────────────────────────────────────────────
TVH_STARTED=$(docker inspect tvheadend --format '{{.State.StartedAt}}' 2>/dev/null || echo "")
if [ -n "$TVH_STARTED" ]; then
    STARTED_EPOCH=$(date -d "$TVH_STARTED" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)
    UPTIME=$((NOW_EPOCH - STARTED_EPOCH))
else
    UPTIME=0
fi

echo "# HELP tvh_uptime_seconds TVheadend container uptime in seconds"
echo "# TYPE tvh_uptime_seconds gauge"
echo "tvh_uptime_seconds $UPTIME"
