# Windows Multiplayer Setup (Non-Technical Guide)

For players/testers who want to run Siegecraft on Windows without programming knowledge.

## What You Need

1. A Windows PC
2. The `love2d` game folder from this repository (or a built `windows` package)
3. LÖVE 11.x installed from <https://love2d.org/>
4. If you are hosting a websocket match: Lua (and usually LuaRocks) installed

## Important: Match Compatibility

Both players should use the same game build/version. If one player is on an older build, multiplayer connection may fail immediately.

## Part A - Run The Game (Local / Single Machine)

1. Open the `love2d` folder.
2. Double-click `run.bat` (or run `run.ps1` from PowerShell).
3. If LÖVE is not found, install LÖVE and try again.

## Part B - Join A Multiplayer Match

### 1) Open PowerShell In The `love2d` Folder

- In File Explorer, open the `love2d` folder.
- Click the address bar, type `powershell`, press Enter.

### 2) Run The Join Command

If someone gave you a server address (example `ws://192.168.1.25:8080`), run:

```powershell
.\run_multiplayer.ps1 -Mode websocket -Url "ws://192.168.1.25:8080" -PlayerName "YourName" -MatchId "test-match"
```

Change these values:

- `ws://192.168.1.25:8080` -> the host/relay URL you were given
- `YourName` -> your display name
- `test-match` -> the match ID you were given

## Part C - Host A LAN Match (Simple Local Network Test)

Use this when players are on the same home/office network.

### 1) Install Multiplayer Dependencies (First Time Only)

From PowerShell in the `love2d` folder:

```powershell
.\install_multiplayer_dependencies.ps1
```

If LuaRocks cannot find your Lua:

```powershell
.\install_multiplayer_dependencies.ps1 -LuaVersion 5.3 -LuaExePath "C:\path\to\lua.exe"
```

### 2) Start The Host

```powershell
.\run_websocket_host.ps1 -Host 0.0.0.0 -Port 8080 -MatchId "lan-test"
```

If `.ps1` files open in Notepad instead of running:

```powershell
run_websocket_host.bat -Host 0.0.0.0 -Port 8080 -MatchId "lan-test"
```

Leave the host window open.

### 3) Find Your Local IP Address

In a new PowerShell window:

```powershell
ipconfig
```

Find `IPv4 Address` (example: `192.168.1.25`).

### 4) Tell Players How To Join

They run:

```powershell
.\run_multiplayer.ps1 -Mode websocket -Url "ws://YOUR_IP:8080" -PlayerName "PlayerName" -MatchId "lan-test"
```

Replace `YOUR_IP` with your IPv4 address.

## Part D - In-Game Settings / Replay Export

During a match:

- Press `Esc` (when no selection/prompt is active) to open the in-game settings menu
- You can:
  - Export the replay JSON
  - Change SFX volume
  - Toggle fullscreen
  - Return to menu

Replay files are saved under the game's LÖVE save folder in a `replays` subfolder.

## Part E - Build A Windows Package To Share

From PowerShell in the `love2d` folder:

```powershell
.\build_windows.ps1 -GameName "Siegecraft"
```

Then open `love2d\build\windows\` and zip/share the folder contents.

## Common Problems (Quick Fixes)

### "LOVE not found"

- Install LÖVE 11.x from <https://love2d.org/>
- Retry the same command

### "Lua not found" (when starting host)

- Install Lua
- Confirm it works in PowerShell:

```powershell
lua -v
```

### "failed to start websocket host: websocket_server_module_not_found"

- Install websocket host dependencies:

```powershell
luarocks install lua-websockets
```

- Verify:

```powershell
lua -e "require('websocket.server.sync')"
```

or

```powershell
lua -e "require('websocket.server_copas'); require('copas')"
```

### `wss://` connection fails with SSL/LuaSec errors

- Install LuaSec for the same Lua version used by the game runtime:

```powershell
luarocks install luasec
```

- Verify:

```powershell
lua -e "require('ssl'); print('ssl ok')"
```

## One-Line Cheat Sheet

- Play local: `run.bat`
- Join multiplayer: `.\run_multiplayer.ps1 -Mode websocket -Url "ws://HOST:8080" -PlayerName "Me" -MatchId "match1"`
- Install host deps: `.\install_multiplayer_dependencies.ps1`
- Host LAN: `.\run_websocket_host.ps1 -Host 0.0.0.0 -Port 8080 -MatchId "match1"`
- Build package: `.\build_windows.ps1 -GameName "Siegecraft"`
