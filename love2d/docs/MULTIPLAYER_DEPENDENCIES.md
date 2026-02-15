# Multiplayer Dependencies Checklist

Use this checklist when setting up LAN/online multiplayer.

## Required for all players

1. **LÖVE 11.x** (to run the game client UI).

## Required for hosting (authoritative websocket host)

1. **Lua** available as `lua` in terminal.
2. **LuaRocks** available as `luarocks` in terminal.
3. One websocket host backend:
   - `websocket.server.sync` (from the `websocket` rock), **or**
   - `websocket.server_copas` + `copas` (from the `lua-websockets` rock and dependencies).

## Typical install commands (Windows PowerShell)

From the `love2d` folder:

```powershell
.\install_multiplayer_dependencies.ps1
```

If LuaRocks cannot find your Lua in PATH:

```powershell
.\install_multiplayer_dependencies.ps1 -LuaVersion 5.3 -LuaExePath "C:\path\to\lua.exe"
```

## Verify installation

Client module:

```powershell
lua -e "require('websocket')"
```

Host backend (either command may work):

```powershell
lua -e "require('websocket.server.sync')"
lua -e "require('websocket.server_copas'); require('copas')"
```
