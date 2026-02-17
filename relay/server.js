const { WebSocketServer } = require("ws");
const http = require("http");
const crypto = require("crypto");

const PORT = parseInt(process.env.PORT, 10) || 8080;
const ROOM_EXPIRY_MS = 5 * 60 * 1000; // 5 minutes

// rooms: Map<code, { host: ws, joiner: ws|null, timer: timeout }>
const rooms = new Map();

function generateCode() {
  // 6-char alphanumeric, retry on collision
  for (let i = 0; i < 10; i++) {
    const code = crypto.randomBytes(3).toString("hex").toUpperCase().slice(0, 6);
    if (!rooms.has(code)) return code;
  }
  return null;
}

function cleanupRoom(code) {
  const room = rooms.get(code);
  if (!room) return;
  clearTimeout(room.timer);
  rooms.delete(code);
  console.log(`[relay] room ${code} cleaned up (${rooms.size} active)`);
}

const server = http.createServer((_req, res) => {
  if (_req.method === "GET" && _req.url === "/rooms") {
    const waiting = [];
    for (const [code, room] of rooms) {
      if (room.status === "waiting") {
        waiting.push({ code, hostName: room.hostName, createdAt: room.createdAt });
      }
    }
    const body = JSON.stringify(waiting);
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET",
    });
    res.end(body);
    return;
  }
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(`BOM Relay — ${rooms.size} active rooms\n`);
});

const wss = new WebSocketServer({ server, perMessageDeflate: false });

// Compatibility: some Lua websocket clients incorrectly look up the accept
// header as "Sec-Websocket-Accept" (lower-case "s" in Socket) instead of the
// RFC casing "Sec-WebSocket-Accept".
//
// We rewrite the generated accept header to the legacy casing and also keep a
// standard-cased copy for stricter clients.
wss.on("headers", (headers) => {
  let acceptValue = null;
  let standardHeaderIndex = -1;

  for (let i = 0; i < headers.length; i += 1) {
    const match = /^Sec-WebSocket-Accept:\s*(.+)$/i.exec(headers[i]);
    if (match) {
      acceptValue = match[1];
      standardHeaderIndex = i;
      break;
    }
  }

  if (!acceptValue) return;

  // Put the legacy-cased header where ws would normally emit the standard one.
  if (standardHeaderIndex >= 0) {
    headers[standardHeaderIndex] = `Sec-Websocket-Accept: ${acceptValue}`;
  } else {
    headers.push(`Sec-Websocket-Accept: ${acceptValue}`);
  }

  // Keep an RFC-cased copy for interoperability.
  const hasStandardCasing = headers.some((header) => /^Sec-WebSocket-Accept:/i.test(header));
  if (!hasStandardCasing) {
    headers.push(`Sec-WebSocket-Accept: ${acceptValue}`);
  }
});

wss.on("connection", (ws, req) => {
  const path = req.url;
  if (path === "/host" || path.startsWith("/host?")) {
    const url = new URL(path, "http://localhost");
    const hostName = url.searchParams.get("name") || "Player";
    handleHost(ws, hostName);
  } else if (path.startsWith("/join/")) {
    const code = path.slice(6).toUpperCase();
    handleJoin(ws, code);
  } else {
    ws.close();
  }
});

function handleHost(ws, hostName) {
  const code = generateCode();
  if (!code) {
    ws.send(JSON.stringify({ type: "error", message: "server_full" }));
    ws.close();
    return;
  }

  const timer = setTimeout(() => {
    console.log(`[relay] room ${code} expired (no joiner)`);
    ws.send(JSON.stringify({ type: "error", message: "room_expired" }));
    ws.close();
    cleanupRoom(code);
  }, ROOM_EXPIRY_MS);

  const room = { host: ws, joiner: null, timer, hostName, status: "waiting", createdAt: Date.now() };
  rooms.set(code, room);

  ws.send(JSON.stringify({ type: "room_created", room: code }));
  console.log(`[relay] room ${code} created (${rooms.size} active)`);

  ws.on("message", (data) => {
    if (room.joiner && room.joiner.readyState === 1) {
      room.joiner.send(data.toString());
    }
  });

  ws.on("close", () => {
    if (room.joiner && room.joiner.readyState === 1) {
      room.joiner.send(JSON.stringify({ type: "peer_disconnected" }));
      room.joiner.close();
    }
    cleanupRoom(code);
  });
}

function handleJoin(ws, code) {
  const room = rooms.get(code);
  if (!room) {
    ws.send(JSON.stringify({ type: "error", message: "room_not_found" }));
    ws.close();
    return;
  }
  if (room.joiner) {
    ws.send(JSON.stringify({ type: "error", message: "room_full" }));
    ws.close();
    return;
  }

  // Pair them
  room.joiner = ws;
  room.status = "playing";
  clearTimeout(room.timer);

  room.host.send(JSON.stringify({ type: "peer_joined" }));
  ws.send(JSON.stringify({ type: "joined", room: code }));
  console.log(`[relay] room ${code} paired`);

  ws.on("message", (data) => {
    if (room.host && room.host.readyState === 1) {
      room.host.send(data.toString());
    }
  });

  ws.on("close", () => {
    if (room.host && room.host.readyState === 1) {
      room.host.send(JSON.stringify({ type: "peer_disconnected" }));
      room.host.close();
    }
    cleanupRoom(code);
  });
}

server.listen(PORT, () => {
  console.log(`[relay] listening on port ${PORT}`);
});
