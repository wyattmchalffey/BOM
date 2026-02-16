# Windows Multiplayer Setup (Non-Technical Guide)

This guide is written for players and testers who want to run the game on Windows without needing programming knowledge.

---

## What you need first

1. A Windows PC.
2. The game folder (`love2d`) from this repository.
3. LÖVE 11.x installed from https://love2d.org/.
4. (Only if hosting online/LAN from your PC) Lua installed and available as `lua` in Command Prompt/PowerShell.

---

## Part A — Run the game normally (single-player/local mode)

1. Open the `love2d` folder.
2. Double-click `run.bat`.
3. If asked about LÖVE not found, install LÖVE and try again.

That is it.

---

## Part B — Join a multiplayer match as a player

### 1) Open PowerShell in the `love2d` folder

- In File Explorer, go to the `love2d` folder.
- Click the address bar, type `powershell`, then press Enter.

### 2) Run one command

If someone gave you a server address (for example `ws://192.168.1.25:8080`), paste this and press Enter:

```powershell
.\run_multiplayer.ps1 -Mode websocket -Url "ws://192.168.1.25:8080" -PlayerName "YourName" -MatchId "test-match"
```

What to change:
- Replace `ws://192.168.1.25:8080` with the host address they gave you.
- Replace `YourName` with your player name.
- Replace `test-match` with the match id you were given.

If it opens the game window, you are connected (or attempting to connect).

---

## Part C — Host a LAN match from your PC (simple local network test)

Use this if players are on the same home/office network.

### 1) Open PowerShell in the `love2d` folder

(same method as above)

### 2) Install multiplayer dependencies (first time only)

```powershell
.\install_multiplayer_dependencies.ps1
```

If LuaRocks cannot find your Lua in PATH, run with explicit values:

```powershell
.\install_multiplayer_dependencies.ps1 -LuaVersion 5.3 -LuaExePath "C:\path\to\lua.exe"
```

### 3) Start the host

```powershell
# PowerShell
.\run_websocket_host.ps1 -Host 0.0.0.0 -Port 8080 -MatchId "lan-test"

# If the .ps1 file opens in Notepad instead of running, use:
run_websocket_host.bat -Host 0.0.0.0 -Port 8080 -MatchId "lan-test"
```

Leave this window open.

### 4) Find your local IP address

In a new PowerShell window, run:

```powershell
ipconfig
```

Look for `IPv4 Address` (example: `192.168.1.25`).

### 5) Tell players to connect

Each player runs:

```powershell
.\run_multiplayer.ps1 -Mode websocket -Url "ws://YOUR_IP:8080" -PlayerName "PlayerName" -MatchId "lan-test"
```

Replace `YOUR_IP` with your IPv4 address.

---

## Part D — Build a Windows package you can share

1. Open PowerShell in the `love2d` folder.
2. Run:

```powershell
.\build_windows.ps1 -GameName "BattlesOfMasadoria"
```

3. Open `love2d\build\windows\`.
4. You should see:
   - `BattlesOfMasadoria.exe`
   - `BattlesOfMasadoria.love`
   - several `.dll` files
5. Zip that `windows` folder and share it.

---

## Common problems and easy fixes

### “LÖVE not found”
- Install LÖVE 11.x from https://love2d.org/.
- Re-run the same command.

### “Cannot load game at path ...” when using `run.bat`
- Make sure you run `run.bat` from inside the real `love2d` folder (not a shortcut pointing elsewhere).
- Pull the latest files; `run.bat` now normalizes the folder path before launching LÖVE.
- If it still fails, try PowerShell launch instead: `./run.ps1`.

### “Lua not found” when starting host
- Install Lua (version depends on websocket module availability for your LuaRocks setup).
- Ensure `lua` works in PowerShell (`lua -v`).

### “run_websocket_host.ps1 opens in Notepad”
- Open **PowerShell** in the `love2d` folder and run the command there, or
- Use `run_websocket_host.bat ...` from Command Prompt, which launches PowerShell with the right flags.


### “failed to start websocket host: websocket_server_module_not_found”
- This means the websocket **server** Lua module is missing from your Lua install.
- Install LuaRocks (if needed), then run: `luarocks install lua-websockets` (recommended)
- If `luarocks install websocket` fails with Git clone/repository errors, use `lua-websockets` instead
- If you get “No results ... for your Lua version”, check supported versions: `luarocks install lua-websockets --check-lua-versions`
- Install for a Lua version you actually have (example): `luarocks --lua-version=5.3 install lua-websockets`
- If you get “Could not find Lua 5.3 in PATH”, set Lua path first: `luarocks --lua-version=5.3 --local config variables.LUA C:\path\to\lua.exe`
- Verify backend module visibility in the same shell (either one works):
  - `lua -e "require('websocket.server.sync')"`
  - `lua -e "require('websocket.server_copas'); require('copas')"`
- Start host again: `run_websocket_host.bat -Host 0.0.0.0 -Port 8080 -MatchId "match1"`

### “attempt to index upvalue 'ssl' (a nil value)” when using `wss://`
- This means your Lua runtime is missing SSL support (`ssl` / LuaSec).
- Install LuaSec in the same Lua version used by the game:
  - `luarocks install luasec`
  - (or versioned) `luarocks --lua-version=5.3 install luasec`
- If install fails with `openssl/ssl.h` / `OPENSSL_DIR` errors:
  1. Install OpenSSL (Win64), for example with winget:
     - `winget install ShiningLight.OpenSSL.Light`
  2. Match OpenSSL bitness to your Lua runtime:
     - Lua in `C:\Program Files (x86)\...` is usually **32-bit** → use `OpenSSL-Win32`
     - Lua in `C:\Program Files\...` is usually **64-bit** → use `OpenSSL-Win64`
  3. Re-run installer with OpenSSL path:
     - `./install_multiplayer_dependencies.ps1 -OpenSSLDir "C:\Program Files\OpenSSL-Win32"`
     - or install directly: `$env:OPENSSL_DIR="C:\Program Files\OpenSSL-Win32"; luarocks install luasec`
- Verify in the same shell:
  - `lua -e "require('ssl'); print('ssl ok')"`
- Then retry Host/Join with your `wss://...onrender.com` relay URL.

### Players cannot connect
- Confirm host used `run_websocket_host.ps1` and kept the window open.
- Confirm everyone uses the same port (`8080` unless changed).
- Confirm everyone uses the same match id.
- Temporarily allow the app through Windows Firewall.

### Online (internet) hosting does not work
- Router port-forwarding and firewall setup are required.
- Prefer using a secure `wss://` endpoint via a reverse proxy.

---

## One-line cheat sheet

- Play local: `run.bat`
- Join server: `.\run_multiplayer.ps1 -Mode websocket -Url "ws://HOST:8080" -PlayerName "Me" -MatchId "match1"`
- Install deps: `.\install_multiplayer_dependencies.ps1`
- Host LAN (PowerShell): `.\run_websocket_host.ps1 -Host 0.0.0.0 -Port 8080 -MatchId "match1"`
- Host LAN (Command Prompt-safe): `run_websocket_host.bat -Host 0.0.0.0 -Port 8080 -MatchId "match1"`
- Build package: `.\build_windows.ps1 -GameName "BattlesOfMasadoria"`
