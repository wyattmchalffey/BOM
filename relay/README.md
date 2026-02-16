# BOM Relay Server

Relay server for Battles of Masadoria internet play. Pairs a host and joiner via room codes and forwards websocket frames bidirectionally.

## Local Development

```bash
npm install
node server.js          # listens on :8080
```

## Deploy to Render (Docker)

If your repo root is `BOM/` and the relay lives in `relay/`, use a **Render Web Service** with Docker and set:

- **Root Directory**: `relay`
- **Dockerfile Path**: `Dockerfile`

If you leave **Root Directory** blank (repo root), set:

- **Dockerfile Path**: `relay/Dockerfile`

Do **not** set Dockerfile path to just `relay` (that is a directory, which causes `failed to read dockerfile ... relay: is a directory`).

### Render environment variables

- No custom env vars are required.
- Render provides `PORT` automatically; the relay reads `process.env.PORT` and falls back to `8080` locally.

## Deploy to Oracle Cloud Free Tier

### 1. Provision a VM

- Create an "Always Free" ARM Ampere A1 instance (1 OCPU, 6 GB RAM is plenty)
- Use Oracle Linux or Ubuntu 22.04 minimal image
- In the VCN security list, add an ingress rule for TCP port 8080 (source 0.0.0.0/0)

### 2. Install Docker

```bash
# Ubuntu
sudo apt update && sudo apt install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### 3. Build and Run

```bash
# Copy relay/ directory to the VM, then:
cd relay
./scripts/deploy_oracle.sh
```

(Manual equivalent, if preferred)

```bash
docker build -t bom-relay .
docker run -d --restart unless-stopped -p 8080:8080 --name bom-relay bom-relay
```

### 4. Test

```bash
curl http://<VM_PUBLIC_IP>:8080
# Should print: BOM Relay — 0 active rooms
```

### 5. Use in Game

If your VM has a host firewall enabled (for example `ufw`), allow the relay port there too:

```bash
sudo ufw allow 8080/tcp
```


- Host Game: set Relay URL to `ws://<VM_PUBLIC_IP>:8080`
- Join Game: set Relay URL to `ws://<VM_PUBLIC_IP>:8080` and enter the room code shown on the host screen

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT`   | `8080`  | Listen port |
