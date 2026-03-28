# Wizarr – Invite Manager

## What It Does

Wizarr provides a branded invite flow for Jellyfin — share a link, users sign up themselves with no access to your admin panel.

Combine with a Cloudflare Tunnel for a clean external URL (`https://join.yourdomain.com`) without exposing your homelab IP.

---

## Docker Compose

Already in `docker-compose.yml` on port `5690`. Wizarr stores its database in:
```
${DOCKER_VOLUMES}/wizarr/
```

---

## Initial Setup

1. Access: `http://[LXC_IP]:5690`
2. Create admin account on first run
3. **Settings → Media Server:**
   - Type: `Jellyfin`
   - URL: `http://jellyfin:8096`
   - API Key: from Jellyfin → Dashboard → API Keys → New Key

---

## Creating Invites

**Invitations → Create:**

| Setting | Recommended |
|---|---|
| Duration | 7 days |
| Max uses | 1 (per-person links) |
| Unlimited | only for trusted groups |

Share the generated link — users land on a custom page, enter their details, and get a Jellyfin account automatically.

---

## Cloudflare Tunnel (External Access)

Expose Wizarr publicly without opening firewall ports:

```bash
# On any machine with cloudflared installed:
cloudflared tunnel create homelab
cloudflared tunnel route dns homelab join.yourdomain.com

# config.yml:
tunnel: <tunnel-id>
credentials-file: /root/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: join.yourdomain.com
    service: http://[LXC_IP]:5690
  - service: http_status:404
```

Result: `https://join.yourdomain.com` routes to Wizarr. Jellyfin itself stays internal.

---

## Notes

- Wizarr only creates Jellyfin user accounts — it doesn't manage libraries or permissions beyond what you configure in the invite settings.
- Revoke invites immediately after use for security.
- Combine with Jellyseerr so new users can also request content from day one.
