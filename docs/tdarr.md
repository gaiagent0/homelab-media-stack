# Tdarr – Transcode Automation

## What Tdarr Does

Tdarr watches your media library and automatically re-encodes files that don't meet your defined codec/quality standards. Typical use: convert H264 remuxes to HEVC to cut storage by 40–60% without visible quality loss.

---

## Scheduling — Critical for Homelab

Tdarr is CPU/GPU intensive. On pve-03 the PBS (Proxmox Backup Server) nightly backup runs at **02:30**.

**Configure Tdarr to run 06:00–02:00 only** to avoid storage I/O contention during backup.

In Tdarr UI → **Nodes → [Node] → Scheduling:**
- Enable scheduling: ✅
- Active hours: `06:00` – `02:00`
- Timezone: match your `TZ` env var

---

## Initial Setup

### 1. Access UI
`http://[LXC_IP]:8265`

### 2. Add Server
The internal node connects automatically. Verify under **Nodes** — status should be `Connected`.

### 3. Add Library

**Libraries → Add Library:**

| Setting | Value |
|---|---|
| Name | Movies |
| Source | `/data/movies` |
| Output | *(same as source — in-place)* |
| File types | `mkv,mp4,avi` |

Repeat for `tv` and `music` libraries.

### 4. Transcode Plugin Stack (example)

Community plugin stack for H264→HEVC conversion:
1. **Requeue** — re-check files after changes
2. **Check codec** — skip if already HEVC
3. **Handbrake/FFmpeg HEVC** — encode with VA-API hardware acceleration

VA-API FFmpeg args for AMD (add to plugin settings):
```
-hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi
```

---

## Storage Impact

Running Tdarr on a full 4TB movie library will temporarily use significant temp space during transcoding. The compose file maps `/tmp/tdarr_transcode` as the temp directory — ensure the host has enough space (recommend 50GB+ free on the Proxmox host).

---

## Verify Hardware Encoding

```bash
docker logs tdarr --tail=100 | grep -i "vaapi\|encode\|hardware"
```

CPU usage should stay low (iGPU handles encode). If CPU spikes to 100% — VA-API passthrough isn't working, recheck [docs/vaapi.md](vaapi.md).
