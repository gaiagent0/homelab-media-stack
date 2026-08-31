#!/bin/bash
# tvh-benchmark.sh — TVheadend streaming performance benchmark
#
# Measures bitrate, latency, and stream health for each channel.
# Useful for identifying weak muxes and problematic channels.
#
# Usage:
#   ./tvh-benchmark.sh                    — benchmark all channels (3s each)
#   ./tvh-benchmark.sh --channels 10      — benchmark first 10 channels
#   ./tvh-benchmark.sh --duration 5       — 5 seconds per channel
#   ./tvh-benchmark.sh --output report.md — save results to markdown file
#   ./tvh-benchmark.sh --json             — output as JSON (for scripting)
#
# Cron example (weekly, Sunday 03:00):
#   0 3 * * 0 /opt/tvheadend/tvh-benchmark.sh --output /opt/tvheadend/benchmark-report.md

set -euo pipefail

TVH_API="http://127.0.0.1:9981"
DURATION=3        # seconds per channel
MAX_CHANNELS=0    # 0 = all
OUTPUT=""
JSON_MODE=false

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --channels|-c) MAX_CHANNELS="$2"; shift 2 ;;
        --duration|-d) DURATION="$2"; shift 2 ;;
        --output|-o)   OUTPUT="$2"; shift 2 ;;
        --json|-j)     JSON_MODE=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--channels N] [--duration S] [--output FILE] [--json]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helpers ───────────────────────────────────────────────────
ts() { date '+%Y-%m-%d %H:%M:%S'; }

api_get() {
    curl -s --digest -u admin:admin --max-time 10 "${TVH_API}$1" 2>/dev/null || echo ""
}

# ─── Get channel list ──────────────────────────────────────────
echo "[$(ts)] Fetching channel list..." >&2

CHANNELS_JSON=$(api_get "/api/channel/list")
CHANNEL_COUNT=$(echo "$CHANNELS_JSON" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
entries = d.get('entries', [])
print(len(entries))
" 2>/dev/null || echo "0")

if [ "$CHANNEL_COUNT" -eq 0 ]; then
    echo "ERROR: No channels found!" >&2
    exit 1
fi

echo "[$(ts)] Found $CHANNEL_COUNT channels" >&2

# ─── Benchmark each channel ────────────────────────────────────
RESULTS=()
TOTAL=0
SUCCESS=0
FAIL=0

echo "$CHANNELS_JSON" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for e in d.get('entries', []):
    print(e['key'] + '|' + e['val'])
" 2>/dev/null | while IFS='|' read -r UUID NAME; do

    TOTAL=$((TOTAL + 1))

    if [ "$MAX_CHANNELS" -gt 0 ] && [ "$TOTAL" -gt "$MAX_CHANNELS" ]; then
        break
    fi

    echo -n "[$(ts)] [$TOTAL/$CHANNEL_COUNT] $NAME ... " >&2

    # Start stream in background and measure
    TMPFILE=$(mktemp)
    START_TIME=$(date +%s%N)

    # Stream for DURATION seconds, capture bytes
    curl -s --max-time "$DURATION" \
        "${TVH_API}/stream/channel/${UUID}" \
        -o "$TMPFILE" 2>/dev/null &
    CURL_PID=$!

    # Wait for curl to finish
    wait $CURL_PID 2>/dev/null
    EXIT_CODE=$?
    END_TIME=$(date +%s%N)

    # Calculate metrics
    BYTES=$(stat -c%s "$TMPFILE" 2>/dev/null || echo "0")
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))

    # Check for adapter busy (no free adapter)
    RECENT_LOG=$(docker logs tvheadend --tail 5 2>/dev/null || true)
    if echo "$RECENT_LOG" | grep -q "No free adapter"; then
        STATUS="⏭️ SKIP (adapter busy)"
        BITRATE_KBPS=0
        BITRATE_MBPS="0"
        # Don't count as fail — adapter is legitimately in use
    elif [ "$BYTES" -gt 0 ] && [ "$ELAPSED_MS" -gt 0 ]; then
        BITRATE_KBPS=$(( (BYTES * 8) / ELAPSED_MS ))
        BITRATE_MBPS=$(python3 -c "print(f'{$BITRATE_KBPS / 1000:.2f}')" 2>/dev/null || echo "0")
        STATUS="✅"
        SUCCESS=$((SUCCESS + 1))
    else
        BITRATE_KBPS=0
        BITRATE_MBPS="0"
        STATUS="❌"
        FAIL=$((FAIL + 1))
    fi

    # Get signal info if this is the first stream (adapter is now active)
    SIGNAL_INFO=""
    if [ "$TOTAL" -eq 1 ]; then
        # Quick signal probe from last dmesg
        DMESG_INFO=$(dmesg | grep -i "signal\|snr" | tail -1 2>/dev/null || true)
        if [ -n "$DMESG_INFO" ]; then
            SIGNAL_INFO=" (dmesg: $(echo "$DMESG_INFO" | head -c 60))"
        fi
    fi

    echo "$STATUS ${BITRATE_MBPS} Mbps (${BYTES} bytes, ${ELAPSED_MS}ms)${SIGNAL_INFO}" >&2

    # Build result JSON
    RESULT="{\"name\":\"$NAME\",\"uuid\":\"$UUID\",\"bytes\":$BYTES,\"elapsed_ms\":$ELAPSED_MS,\"bitrate_kbps\":$BITRATE_KBPS,\"bitrate_mbps\":$BITRATE_MBPS,\"status\":\"$([ "$EXIT_CODE" = "0" ] && echo "ok" || echo "timeout")\",\"exit_code\":$EXIT_CODE}"
    RESULTS+=("$RESULT")

    rm -f "$TMPFILE"
done

# ─── Generate output ───────────────────────────────────────────
echo "" >&2
echo "[$(ts)] Benchmark complete: $SUCCESS ok, $FAIL failed" >&2

# Collect all results into JSON
ALL_RESULTS="[]"
for r in "${RESULTS[@]:-}"; do
    if [ -n "$r" ]; then
        ALL_RESULTS=$(echo "$ALL_RESULTS" | python3 -c "
import json, sys
results = json.loads(sys.stdin.read())
results.append($r)
print(json.dumps(results))
" 2>/dev/null || echo "$ALL_RESULTS")
    fi
done

if [ "$JSON_MODE" = true ]; then
    echo "$ALL_RESULTS" | python3 -m json.tool 2>/dev/null || echo "$ALL_RESULTS"
    exit 0
fi

# ─── Markdown report ───────────────────────────────────────────
REPORT="# TVheadend Streaming Benchmark Report\n"
REPORT+="Generated: $(date '+%Y-%m-%d %H:%M:%S')\n\n"

REPORT+="## Summary\n"
REPORT+="| Metric | Value |\n"
REPORT+="|---|---|\n"
REPORT+="| Channels tested | $TOTAL |\n"
REPORT+="| Successful streams | $SUCCESS |\n"
REPORT+="| Failed streams | $FAIL |\n"
REPORT+="| Test duration | ${DURATION}s per channel |\n\n"

REPORT+="## Channel Results\n"
REPORT+="| Channel | Bitrate (Mbps) | Bytes | Duration | Status |\n"
REPORT+="|---|---|---|---|---|\n"

echo "$ALL_RESULTS" | python3 -c "
import json, sys
try:
    results = json.loads(sys.stdin.read())
    for r in sorted(results, key=lambda x: x.get('bitrate_kbps', 0), reverse=True):
        name = r.get('name', 'Unknown')
        mbps = r.get('bitrate_mbps', 0)
        b = r.get('bytes', 0)
        ms = r.get('elapsed_ms', 0)
        s = r.get('status', '?')
        icon = '✅' if s == 'ok' else '❌'
        print(f'| {name} | {mbps} | {b:,} | {ms}ms | {icon} |')
except: pass
" 2>/dev/null

# Sort by bitrate for the report
REPORT+=$(echo "$ALL_RESULTS" | python3 -c "
import json, sys
try:
    results = json.loads(sys.stdin.read())
    for r in sorted(results, key=lambda x: x.get('bitrate_kbps', 0), reverse=True):
        name = r.get('name', 'Unknown')
        mbps = r.get('bitrate_mbps', 0)
        b = r.get('bytes', 0)
        ms = r.get('elapsed_ms', 0)
        s = r.get('status', '?')
        icon = '✅' if s == 'ok' else '❌'
        print(f'| {name} | {mbps} | {b:,} | {ms}ms | {icon} |')
except: pass
" 2>/dev/null)

echo -e "$REPORT"

# Save to file if requested
if [ -n "$OUTPUT" ]; then
    echo -e "$REPORT" > "$OUTPUT"
    echo "[$(ts)] Report saved to $OUTPUT" >&2
fi
