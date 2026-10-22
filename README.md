# PR Seeder

Keep a **Project Reality: BF2** server seeded while you're AFK — automatic joining, automatic reconnecting, and minimal CPU/GPU use while you sit in the server.

[中文说明](#中文说明)

## What it does

- Joins the way a human does: opens the PR Launcher (Steam auto-login), clicks **PLAY**, then in game **MULTIPLAYER → JOIN INTERNET → JOIN IP**.
- Checks every 20 s whether you're in the server's player list (GameSpy query, falling back to the official server list). If the game crashes or you drop, it rejoins.
- Once you're in: low graphics in an 800×600 window, minimized, Idle priority, Windows 11 efficiency mode, pinned to the last N cores, and duty-cycle throttled.
- Stops after N hours, at a clock time, or when the server has enough other players — then closes the game and restores your original graphics/audio settings.

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (built in)
- Project Reality: BF2 installed, with the launcher set to log in automatically (Steam)
- Run as administrator (the script asks for elevation itself, since PRBF2.exe requires it)
- Don't touch the mouse/keyboard while it's clicking through the menus (about a minute per join)

## Quick start

1. Download this repo (Code → Download ZIP) and unzip it anywhere.
2. Copy `config.example.json` to `config.json` and set at least `Player` (your in-game name, without clan tag) and `Server` (server IP). Check `Port`/`QueryPort` against the server list if they differ from the defaults.
3. Right-click `seed.ps1` → **Run with PowerShell**, or:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\seed.ps1 -Player MyName -Server 1.2.3.4 -Port 16567 -QueryPort 29900
   ```

4. Optional one-click / daily start (no UAC prompt afterwards):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\seed.ps1 -Install -DailyAt 18:00
   ```

   This creates the scheduled task `PRSeeder` and a desktop shortcut **PR Seeder**. Start it any time with `schtasks /run /tn PRSeeder`.

**Stop:** press Ctrl+C in the window, or create the file `%LOCALAPPDATA%\PRSeeder\stop`.
**Restore settings manually:** `seed.ps1 -Restore`.

## Options

| Parameter | Default | Meaning |
|---|---|---|
| `Player` | — | Your in-game name (required) |
| `Server` | — | Server IP (required) |
| `Port` | 16567 | Game port |
| `QueryPort` | 29900 | GameSpy query port |
| `Hours` | 6 | How long to seed |
| `Until` | | Stop at this time, e.g. `"21:00"` (overrides `Hours`) |
| `StopAtPlayers` | 0 | Stop when the server has this many *other* players (0 = off) |
| `Duty` | 40 | % of time the game may run once joined (100 = no throttling) |
| `Cores` | 2 | Pin the game to the last N logical cores (0 = off) |
| `GraceMin` | 3 | Minutes allowed for map loading before "not in server" counts |
| `LoginWaitSec` | 60 | Wait after opening the launcher before clicking PLAY |
| `MenuWaitSec` | 45 | Wait for the main menu after the game window appears |
| `GameRoot` | auto | PR install folder (read from the registry by default) |
| `NoMinimize` | false | Don't minimize the game |
| `NoLowGfx` | false | Keep your graphics/audio settings (resolution is still set to 800×600) |

Command-line parameters override `config.json`.

## Troubleshooting

Logs and failure screenshots are in `%LOCALAPPDATA%\PRSeeder` (`seed.log`, `shot_*.png`).

- **Clicks land in the wrong place** — the menu coordinates assume an 800×600 game window, which the script sets for you. Make sure no other window covers the game while it's joining.
- **"PLAY button not found"** — the launcher wasn't logged in yet; raise `LoginWaitSec`.
- **Slow PC** — raise `MenuWaitSec`.

Debug mode: write commands into `%LOCALAPPDATA%\PRSeeder\mode` (one per line: `play`, `click X Y`, `dblclick X Y`, `key KEYS`, `wait SECONDS`, `lowgfx`, `restore`, `kill`, `uia-dump`), then run the script; it executes them and exits.

## Notes

- Why not `PRLauncher.exe +join prbf2://ip:port`? With Steam accounts it lands in the main menu with "failed to connect", and the launcher is single-instance. Clicking through JOIN IP is the reliable route.
- Throttling works by briefly suspending the game process many times per second. This is a client-side resource trick only; it doesn't modify the game or touch network traffic. Check your server's rules about AFK seeding.

---

## 中文说明

PR（Project Reality: BF2）暖服挂机脚本：自动进服、掉线自动重连，进服后尽量少占电脑资源。

**用法**

1. 下载本仓库（Code → Download ZIP）解压到任意位置。
2. 把 `config.example.json` 复制成 `config.json`，至少填 `Player`（游戏名，不带战队标签）和 `Server`（服务器 IP）；端口和默认值不同就改 `Port`/`QueryPort`。
3. 右键 `seed.ps1` → 用 PowerShell 运行（会自动请求管理员权限）。
4. 可选：`seed.ps1 -Install -DailyAt 18:00` 建计划任务 `PRSeeder` 和桌面快捷方式，以后一键启动不弹 UAC，并每天定时开始。

**停止**：窗口里按 Ctrl+C，或创建文件 `%LOCALAPPDATA%\PRSeeder\stop`。日志和失败截图也在这个目录。

**原理**：启动器（需 Steam 自动登录）点 PLAY → 游戏里 MULTIPLAYER → JOIN INTERNET → JOIN IP；每 20 秒查一次服务器玩家列表，不在就重连。进服后低画质 800×600、最小化、Idle 优先级、效率模式、限核、按占空比节流；结束时自动还原你的画质/声音设置。进服点击菜单的约一分钟里请不要动鼠标键盘。

## License

MIT
