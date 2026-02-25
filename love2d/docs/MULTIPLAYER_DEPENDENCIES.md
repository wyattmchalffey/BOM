# Multiplayer Dependencies Checklist (Current)

Use this checklist for LAN/online multiplayer setup on current builds.

## Version Compatibility

Both players should be on the same build:

- `protocol_version = 2`
- `rules_version = 0.1.1`
- `content_version = 0.1.1`

## Required For All Players

1. LÖVE 11.x (to run the game client)

## Required For Websocket Multiplayer Clients (`ws://` / `wss://`)

The client runtime needs a websocket Lua module usable by the game's provider wrapper.

Minimum verification:

```powershell
lua -e "require('websocket')"
```

For secure relay/host endpoints (`wss://...`), client Lua also needs SSL (LuaSec):

```powershell
lua -e "require('ssl'); print('ssl ok')"
```

## Required For Hosting An Authoritative Websocket Host

1. Lua available as `lua`
2. LuaRocks available as `luarocks`
3. One websocket server backend:
   - `websocket.server.sync`, or
   - `websocket.server_copas` + `copas`

Verification:

```powershell
lua -e "require('websocket.server.sync')"
lua -e "require('websocket.server_copas'); require('copas')"
```

Either host backend path is acceptable.

## Recommended Windows Install Path

From `love2d/`:

```powershell
.\install_multiplayer_dependencies.ps1
```

If LuaRocks cannot find your Lua in PATH:

```powershell
.\install_multiplayer_dependencies.ps1 -LuaVersion 5.3 -LuaExePath "C:\path\to\lua.exe"
```

If LuaSec/OpenSSL setup is needed:

```powershell
.\install_multiplayer_dependencies.ps1 -OpenSSLDir "C:\Program Files\OpenSSL-Win64"
```

(Use the `Win32` path for 32-bit Lua.)

## Notes

- The game supports `headless` mode without websocket runtime modules (local authoritative boundary only).
- Remote websocket modes need matching client websocket modules on each machine.
- See `WINDOWS_MULTIPLAYER_SETUP_NON_TECHNICAL.md` for step-by-step tester instructions.
