# VA-API Hardware Transcoding – AMD Ryzen iGPU

## Environment

| Component | Value |
|---|---|
| Hypervisor | Proxmox VE 8.x |
| GPU | AMD Ryzen (Renoir / Cezanne iGPU) |
| LXC | CT302 (docker-host) |
| Jellyfin image | `lscr.io/linuxserver/jellyfin:latest` |

---

## 1. Verify VA-API on Proxmox host

```bash
# On pve-03 host:
ls /dev/dri/
# Expected: by-path  card0  renderD128

vainfo
# Expected: radeonsi driver, VAEntrypointEncSlice for H264/HEVC
```

If `vainfo` is missing: `apt install vainfo libva-utils`

---

## 2. Pass device into LXC

Add these two lines to the LXC config on the Proxmox host:

```bash
echo "lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file" \
  >> /etc/pve/lxc/302.conf

pct reboot 302
```

Verify inside the LXC:
```bash
pct exec 302 -- ls -la /dev/dri/
# Expected: crw-rw---- renderD128
```

---

## 3. Docker Compose device mapping

Already included in `docker-compose.yml`:

```yaml
jellyfin:
  devices:
    - /dev/dri/renderD128:/dev/dri/renderD128
```

No additional configuration needed.

---

## 4. Jellyfin transcoding settings

**Dashboard → Playback → Transcoding:**

| Setting | Value |
|---|---|
| Hardware Acceleration | **VA-API** |
| VA-API Device | `/dev/dri/renderD128` |
| Transcode Path | *(leave empty)* |

**Enable hardware decoding:**
- ✅ H264, HEVC, VC1, VP9, HEVC 10bit, VP9 10bit
- ❌ AV1 — not supported on Renoir iGPU
- ❌ MPEG2, VP8 — unnecessary

**Enable hardware encoding:**
- ✅ Allow hardware encoding
- ✅ HEVC encoding
- ❌ AV1 encoding — not supported
- ❌ Intel Low-Power H.264 — AMD system, ignore

**Tone mapping:**
- ✅ VPP tone mapping
- Method: `BT.2390`
- Peak brightness override: `100` (1000 nit)
- Saturation reduction: `0`

---

## 5. Verify it's working

```bash
# Check transcoding log for hardware acceleration
docker logs jellyfin --tail=50 | grep -i "vaapi\|hardware"
# Expected: -hwaccel vaapi -hwaccel_output_format vaapi
#           -codec:v:0 h264_vaapi
```

**Expected results:**

| Metric | Value |
|---|---|
| Jellyfin CPU during transcode | ~0% |
| Outbound bandwidth (720p stream) | ~1.1 Mbit/s |
| Driver | Mesa Gallium – radeonsi |

Software transcoding the same stream would use 80–100% CPU.

---

## 6. Supported codec matrix (Renoir iGPU)

| Codec | Decode | Encode |
|---|---|---|
| H264 | ✅ | ✅ |
| HEVC Main | ✅ | ✅ |
| HEVC Main10 | ✅ | ✅ |
| VP9 | ✅ | ❌ |
| AV1 | ❌ | ❌ |
