# BOM Relay Server

Websocket relay for Siegecraft internet play.

The relay pairs a host and a joiner via room code, then forwards websocket frames in both directions. The game simulation remains authoritative on the host side.

## Local Development

From `relay/`:

```bash
npm install
node server.js
```

Default port: `8080` (or `PORT` from environment).

## Endpoints / Paths

- `GET /` - plain-text status (`BOM Relay - <n> active rooms`)
- `GET /rooms` - JSON list of waiting rooms (`code`, `hostName`, `createdAt`)
- Websocket `/host?name=<PlayerName>` - create a room and wait for joiner
- Websocket `/join/<ROOMCODE>` - join an existing room

## Deployment (Render / Docker)

Recommended Render config using the repository root `Dockerfile`:

- Root Directory: leave blank
- Dockerfile Path: `Dockerfile`

Alternative (subdirectory build) also works:

- Root Directory: `relay`
- Dockerfile Path: `Dockerfile`

Do not set Dockerfile path to `relay` (that is a directory, not a file).

## Render Environment Variables

- No custom env vars required
- Render supplies `PORT`

## Oracle Cloud Free Tier (Docker)

Typical flow:

1. Provision VM (Ubuntu/Oracle Linux)
2. Open TCP `8080` in cloud/network firewall
3. Install Docker
4. Build/run relay container

From `relay/` (after copying repo/relay files to the VM):

```bash
./scripts/deploy_oracle.sh
```

Manual equivalent:

```bash
docker build -t bom-relay .
docker run -d --restart unless-stopped -p 8080:8080 --name bom-relay bom-relay
```

## Security / TLS Note

Internet-facing deployments should generally be served through TLS (`wss://`) via a reverse proxy or managed platform endpoint.

Clients connecting to `wss://` relays need Lua SSL support (`require('ssl')` / LuaSec) in the game runtime environment.

## Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8080` | Relay listen port |
