# Oracle Cloud Migration Guide (Render -> OCI) for BOM Relay

This guide walks through moving the BOM relay server from Render free tier to an Oracle Cloud Infrastructure (OCI) Always Free VM.

This repo is already set up to make the migration straightforward:

- Relay is a small stateless Node/WebSocket service (`relay/server.js`)
- Relay is containerized (`relay/Dockerfile`)
- Oracle deploy helper script already exists (`relay/scripts/deploy_oracle.sh`)

## What Changes (and What Doesn't)

What changes:

- Where the relay is hosted (Render -> Oracle VM)
- DNS / TLS termination (`wss://`) if you use a domain
- Relay URLs in the game client (`love2d/src/state/menu.lua`)

What does not need to change:

- Relay protocol
- Relay server code (usually)
- Deck/game logic

## Prerequisites

- Oracle Cloud account (you already have this)
- An OCI VM (Always Free) with a public IP
- SSH key pair
- Optional but recommended: a domain/subdomain (for TLS `wss://`)

## 1. Create an Oracle VM (Always Free)

In OCI Console, create a compute instance.

Recommended choices:

- Image: `Ubuntu 22.04` (commands below assume Ubuntu)
- Shape: `VM.Standard.A1.Flex` (Always Free eligible) or `E2.1.Micro`
- Networking: public subnet + public IPv4
- Add your SSH public key during instance creation

Notes:

- Always Free resources are tied to your OCI home region.
- If A1 shape is unavailable, try another availability domain or try later.

## 2. Open Required Ports (OCI Networking)

Open these in your Security List or NSG:

- `22/tcp` from your IP (SSH)
- `80/tcp` from `0.0.0.0/0` (HTTP, for TLS setup/redirect)
- `443/tcp` from `0.0.0.0/0` (HTTPS / `wss://`)
- `8080/tcp` from `0.0.0.0/0` only if you want temporary direct testing without TLS

The deploy script also reminds you about this:

- `relay/scripts/deploy_oracle.sh`

## 3. SSH into the VM

From PowerShell on your PC:

```powershell
ssh -i C:\path\to\your_private_key ubuntu@YOUR_PUBLIC_IP
```

If you used Oracle Linux instead of Ubuntu, the user is usually `opc`.

## 4. Install Docker + Tools (Ubuntu)

Run on the VM:

```bash
sudo apt update
sudo apt install -y docker.io git curl
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker
docker --version
```

Oracle Linux equivalent (roughly):

```bash
sudo dnf install -y docker git curl
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker
docker --version
```

## 5. Copy the Relay Code to the VM

Option A (recommended):

```bash
git clone <your-repo-url>
cd BOM/relay
```

Option B:

- Upload/copy just the `relay/` folder to the VM
- `cd relay`

## 6. Deploy the Relay on Oracle (Docker)

From `relay/` on the VM:

```bash
chmod +x scripts/deploy_oracle.sh
./scripts/deploy_oracle.sh
```

This script will:

- Build the image
- Replace any old `bom-relay` container
- Start the new container on `PORT` (default `8080`)
- Run a local health check

Relevant script locations:

- `relay/scripts/deploy_oracle.sh:22`
- `relay/scripts/deploy_oracle.sh:30`

Manual equivalent (if needed):

```bash
docker build -t bom-relay .
docker run -d --restart unless-stopped -p 8080:8080 --name bom-relay bom-relay
```

## 7. Verify the Relay is Running

On the VM:

```bash
curl http://127.0.0.1:8080
curl http://127.0.0.1:8080/rooms
```

Expected:

- `/` returns a plain-text status
- `/rooms` returns JSON (usually `[]` when idle)

Temporary remote test (if `8080` is open):

```powershell
curl http://YOUR_PUBLIC_IP:8080
curl http://YOUR_PUBLIC_IP:8080/rooms
```

## 8. Set Up TLS (`wss://`) with a Reverse Proxy (Recommended)

Your multiplayer menu currently uses `https://` and `wss://`, so production use should include TLS.

Why:

- `wss://` is safer for internet traffic
- Your client menu is currently hardcoded to secure URLs

Repo note:

- `relay/README.md` already calls out the TLS recommendation

### Option A: Caddy (simple)

Prerequisites:

- A domain/subdomain (example: `relay.yourdomain.com`)
- DNS `A` record pointing to your Oracle VM public IP

Create a `Caddyfile` on the VM:

```caddy
relay.yourdomain.com {
  reverse_proxy 127.0.0.1:8080
}
```

Run Caddy in Docker:

```bash
docker run -d --name bom-caddy --restart unless-stopped \
  -p 80:80 -p 443:443 \
  -v $PWD/Caddyfile:/etc/caddy/Caddyfile \
  -v caddy_data:/data \
  -v caddy_config:/config \
  caddy:2
```

Verify:

```bash
curl https://relay.yourdomain.com
curl https://relay.yourdomain.com/rooms
```

### Option B: No TLS (temporary testing only)

You can use direct `ws://` + `http://` to the VM IP and port `8080` for testing.

Example:

- `http://YOUR_PUBLIC_IP:8080/rooms`
- `ws://YOUR_PUBLIC_IP:8080`
- `ws://YOUR_PUBLIC_IP:8080/join/<ROOMCODE>`

Do not leave this as your public production setup.

## 9. Update Game Client URLs (Render -> Oracle)

The relay URLs are currently hardcoded to Render in `love2d/src/state/menu.lua`:

- `love2d/src/state/menu.lua:1606` (`https://bom-hbfv.onrender.com/rooms`)
- `love2d/src/state/menu.lua:1615` (`wss://bom-hbfv.onrender.com`)
- `love2d/src/state/menu.lua:1629` (`wss://bom-hbfv.onrender.com/join/...`)

Replace them with your Oracle relay domain (recommended):

- `https://relay.yourdomain.com/rooms`
- `wss://relay.yourdomain.com`
- `wss://relay.yourdomain.com/join/<ROOMCODE>`

Or temporary direct IP testing (no TLS):

- `http://YOUR_PUBLIC_IP:8080/rooms`
- `ws://YOUR_PUBLIC_IP:8080`
- `ws://YOUR_PUBLIC_IP:8080/join/<ROOMCODE>`

## 10. Test Host / Join End-to-End

Suggested test flow before cutover:

1. Keep Render running
2. Bring Oracle relay up
3. Confirm `/` and `/rooms` work
4. Build/run a local client pointing to Oracle
5. Create a room (host)
6. Join from a second client
7. Verify gameplay frames flow both directions

If all good, then switch your main build to Oracle URLs.

## 11. Cutover / Rollback Plan

### Cutover (safe)

1. Deploy and test Oracle relay first
2. Update client URLs to Oracle
3. Release/test
4. Disable Render after confirming live sessions work

### Rollback

If Oracle has issues:

1. Restore the previous Render URLs in `love2d/src/state/menu.lua`
2. Rebuild/redeploy the client
3. Investigate Oracle network/TLS logs

## Troubleshooting

### Can't connect from the internet

Check all of these:

- OCI Security List / NSG allows the port
- VM OS firewall allows the port (`ufw`/`firewalld`)
- Docker container is running: `docker ps`
- Relay logs: `docker logs bom-relay --tail 200`

### `wss://` fails but `ws://` works

Likely TLS/reverse proxy issue:

- DNS not pointing to the VM yet
- Ports `80/443` not open
- Reverse proxy not running
- Certificate issuance failed

### Room list works but hosting/joining fails

Check:

- `/host` and `/join/<ROOM>` reach the same relay instance
- Reverse proxy supports WebSocket upgrade (Caddy does by default)
- No stale container / wrong port mapping

## Optional Improvements (Recommended)

### A. Centralize relay base URL in code

Right now the relay base URLs are hardcoded in multiple places in `love2d/src/state/menu.lua`.

A small refactor to a single `RELAY_BASE_URL` constant (or settings/config) will make future provider moves much easier.

### B. Add heartbeat / keepalive

If you later host on a platform with idle timeouts or aggressive connection cleanup, adding a lightweight heartbeat helps keep sessions stable.

## Repo References

- Relay server: `relay/server.js`
- Relay Dockerfile: `relay/Dockerfile`
- Oracle deploy script: `relay/scripts/deploy_oracle.sh`
- Relay deployment notes: `relay/README.md`
- Hardcoded relay URLs in client: `love2d/src/state/menu.lua`
