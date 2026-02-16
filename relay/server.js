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
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(`BOM Relay — ${rooms.size} active rooms\n`);
});

const wss = new WebSocketServer({ server, perMessageDeflate: false });

// Compatibility: some Lua websocket clients incorrectly look up the accept
// header as "Sec-Websocket-Accept" (lower-case "s" in Socket) instead of the
// RFC casing "Sec-WebSocket-Accept". Mirror the header so both casings exist.
wss.on("headers", (headers) => {
  let acceptValue = null;
  for (const header of headers) {
    const match = /^Sec-WebSocket-Accept:\s*(.+)$/i.exec(header);
    if (match) {
      acceptValue = match[1];
      break;
    }
  }

  if (!acceptValue) return;

  const hasLegacyCasing = headers.some((header) => /^Sec-Websocket-Accept:/i.test(header));
  if (!hasLegacyCasing) {
    headers.push(`Sec-Websocket-Accept: ${acceptValue}`);
  }
});

wss.on("connection", (ws, req) => {
  const path = req.url;
  if (path === "/host") {
    handleHost(ws);
  } else if (path.startsWith("/join/")) {
    const code = path.slice(6).toUpperCase();
    handleJoin(ws, code);
  } else {
    ws.close();
  }
});

function handleHost(ws) {
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

  const room = { host: ws, joiner: null, timer };
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
