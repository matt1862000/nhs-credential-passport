# Cloudflare Tunnel — DocPass on Raspberry Pi

Production uses **Cloudflare Tunnel** (`cloudflared`) instead of exposing ports 80/443 on the home router. HTTPS terminates at Cloudflare; the Pi runs DocPass in Docker on `127.0.0.1:8000` and forwards traffic through the tunnel.

## Architecture

```
Internet → Cloudflare (TLS) → cloudflared on Pi → http://127.0.0.1:8000 (DocPass Docker)
```

No Caddy is required when using a tunnel. The deploy script restarts `cloudflared` after each successful deploy so Cloudflare picks up the new origin.

## Pi layout (typical)

| Item | Path |
|------|------|
| Git repo | `~/docpass/app` |
| Env file | `/home/raihant/docpass/docpass.env` |
| Data | `/home/raihant/docpass/data` |
| Keys | `/home/raihant/docpass/keys` |
| Tunnel config | `/etc/cloudflared/config.yml` |
| Tunnel credentials | `/home/raihant/.cloudflared/<tunnel-id>.json` |

## Example `/etc/cloudflared/config.yml`

```yaml
tunnel: <tunnel-uuid>
credentials-file: /home/raihant/.cloudflared/<tunnel-uuid>.json

ingress:
  - hostname: docpass.co.uk
    service: http://127.0.0.1:8000

  - hostname: www.docpass.co.uk
    service: http://127.0.0.1:8000

  - hostname: ha.docpass.co.uk
    service: http://192.168.1.214:8123

  - service: http_status:404
```

After editing config:

```bash
sudo systemctl restart cloudflared
sudo systemctl status cloudflared --no-pager
```

## DNS (Cloudflare dashboard)

For each hostname routed by the tunnel, Cloudflare DNS needs a record. The easiest path:

1. **Zero Trust** → **Networks** → **Tunnels** → select your tunnel
2. **Public Hostname** → add `docpass.co.uk`, `www.docpass.co.uk`, and any other hostnames
3. Cloudflare creates the CNAME to `<tunnel-id>.cfargotunnel.com` automatically

Verify from outside your LAN:

```bash
nslookup docpass.co.uk 1.1.1.1
curl -I https://docpass.co.uk/static/dashboard/
```

You should see Cloudflare anycast IPs (e.g. `104.21.x.x`, `172.67.x.x`) and **HTTP 200**.

## Home Assistant — `ha.docpass.co.uk`

The tunnel **ingress rule on the Pi is not enough**. Public DNS must exist too.

### Symptom: `NXDOMAIN`

```bash
nslookup ha.docpass.co.uk
# server can't find ha.docpass.co.uk: NXDOMAIN
```

**Fix:** Add `ha.docpass.co.uk` as a **Public Hostname** in the Cloudflare tunnel dashboard (service `http://192.168.1.214:8123`). Wait a minute, then:

```bash
nslookup ha.docpass.co.uk 1.1.1.1
curl -I https://ha.docpass.co.uk
```

### Symptom: HTTP 400 from Cloudflare with `--resolve`

```bash
curl -I https://ha.docpass.co.uk --resolve ha.docpass.co.uk:443:104.21.52.100
# HTTP/2 400
```

This means Cloudflare received a request for a hostname it does not route for that tunnel yet. Add the public hostname (and DNS CNAME) in the dashboard — the local `config.yml` alone does not register the hostname at the edge.

### Local LAN access via Pi-hole

If devices on your LAN use Pi-hole (`192.168.1.160`) and you want `ha.docpass.co.uk` to resolve locally without hairpin NAT:

1. Pi-hole **Local DNS** → add `ha.docpass.co.uk` → `192.168.1.214` (Home Assistant IP), **or**
2. Let Pi-hole forward to Cloudflare (works once the public CNAME exists)

Reload Pi-hole DNS after changes:

```bash
docker exec pihole pihole reloaddns
```

## Troubleshooting

### `unexpected EOF` in `journalctl -u cloudflared`

```
error="unexpected EOF" originService=http://127.0.0.1:8000
```

Usually means `cloudflared` connected to DocPass but the origin closed the connection early. Common causes:

- **Deploy in progress** — container was restarting; wait for deploy to finish
- **Stale tunnel connection** — restart after DocPass is healthy:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/static/manifest.webmanifest
sudo systemctl restart cloudflared
```

The deploy script (`deploy/deploy.sh`) runs this restart automatically when `cloudflared.service` is installed.

If errors persist while `curl http://127.0.0.1:8000/` returns **200**, check DocPass container logs:

```bash
sudo docker logs docpass --tail 50
```

### Cloudflare 520 / “Unable to reach origin”

Same fix: confirm DocPass responds locally, then `sudo systemctl restart cloudflared`.

### DocPass down locally

```bash
sudo docker ps -a --filter name=docpass
curl -v http://127.0.0.1:8000/
sudo docker logs docpass --tail 80
```

Redeploy:

```bash
ENV_FILE=/home/raihant/docpass/docpass.env \
DATA_DIR=/home/raihant/docpass/data \
KEYS_DIR=/home/raihant/docpass/keys \
~/docpass/app/deploy/deploy.sh
```

## Security headers without Caddy

When not using Caddy, security headers (HSTS, CSP, etc.) are not added by the reverse proxy. For the pilot, Cloudflare can add some headers under **Rules** → **Transform Rules** → **Modify Response Header**, or you can add middleware in FastAPI later. See `deploy/Caddyfile` for the header values previously served by Caddy.
