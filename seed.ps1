<#
  PR Seeder - keep a Project Reality: BF2 server seeded while you're AFK.

  - Joins exactly like a human: PR Launcher (Steam auto-login) PLAY -> in game MULTIPLAYER -> JOIN INTERNET -> JOIN IP.
    Reconnects automatically when the game exits or you disappear from the server's player list.
  - Once in the server it gets out of your way: low graphics in an 800x600 window, minimized, Idle priority +
    Windows efficiency mode, pinned to the last N cores, and duty-cycle throttled.
  - Stops after N hours / at a clock time / when the server has enough players, then restores your graphics and audio settings.

  Usage:
    seed.ps1 -Player MyName -Server 1.2.3.4            start seeding
    seed.ps1 -Install                                  scheduled task "PRSeeder" + desktop shortcut (no UAC prompt afterwards)
    seed.ps1 -Install -DailyAt 18:00                   same, and start every day at 18:00
    seed.ps1 -Restore                                  only restore graphics/audio settings
  Settings can also live in config.json next to this script (see config.example.json); command-line parameters win.
  Stop: Ctrl+C in the window, or create %LOCALAPPDATA%\PRSeeder\stop.
#>
param(
    [string]$Player,              # your in-game name (without clan tag)
    [string]$Server,              # server IP
    [int]$Port,                   # game port (default 16567)
    [int]$QueryPort,              # GameSpy query port (default 29900)
    [double]$Hours,               # how long to seed (default 6)
    [string]$Until,               # stop at this clock time, e.g. "21:00" (overrides -Hours)
    [int]$StopAtPlayers = -1,     # >0: stop once the server has this many OTHER players
    [int]$Duty = -1,              # % of each 50 ms slice the game may run once joined; 100 = no throttling
    [int]$Cores = -1,             # pin the game to the last N logical cores once joined; 0 = don't pin
    [int]$GraceMin = -1,          # minutes allowed for map loading before "not in server" counts
    [int]$LoginWaitSec = -1,      # wait after opening the launcher (Steam login) before clicking PLAY
    [int]$MenuWaitSec = -1,       # wait after the game window appears for the main menu
    [string]$GameRoot,            # PR install folder (auto-detected from the registry)
    [switch]$NoMinimize,
    [switch]$NoLowGfx,
    [switch]$Install,
    [string]$DailyAt,
    [switch]$Restore
)
$ErrorActionPreference = "Stop"
$TaskName = "PRSeeder"
$Data = Join-Path $env:LOCALAPPDATA "PRSeeder"
$LogFile = Join-Path $Data "seed.log"
$BackupDir = Join-Path $Data "backup"
$StopFlag = Join-Path $Data "stop"
New-Item -ItemType Directory -Force $Data, $BackupDir | Out-Null

# ---------- elevate (PRBF2.exe requires admin) ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
    }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}
$Host.UI.RawUI.WindowTitle = "PR Seeder"

function Log($msg, $color = "Gray") {
    $line = "{0:MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ---------- settings: command line > config.json > defaults ----------
$Defaults = @{
    Player = ""; Server = ""; Port = 16567; QueryPort = 29900; Hours = 6; Until = ""; StopAtPlayers = 0
    Duty = 40; Cores = 2; GraceMin = 3; LoginWaitSec = 60; MenuWaitSec = 45; GameRoot = ""
    NoMinimize = $false; NoLowGfx = $false
}
$cfg = @{}
$ConfigFile = Join-Path $PSScriptRoot "config.json"
if (Test-Path $ConfigFile) {
    (Get-Content $ConfigFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value }
}
foreach ($k in $Defaults.Keys) {
    $cur = Get-Variable -Name $k -ValueOnly
    $given = $PSBoundParameters.ContainsKey($k)
    if (-not $given) {
        $v = if ($cfg.ContainsKey($k)) { $cfg[$k] } else { $Defaults[$k] }
        if ($cur -is [switch]) { $v = [switch][bool]$v }
        Set-Variable -Name $k -Value $v
    }
}
if (-not $GameRoot) {
    $GameRoot = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Project Reality\Project Reality: BF2" -ErrorAction SilentlyContinue).InstallDir
}
if (-not $GameRoot -or -not (Test-Path (Join-Path $GameRoot "PRBF2.exe"))) {
    Log "Can't find Project Reality. Pass -GameRoot 'D:\Path\To\PR' or set GameRoot in config.json." Red
    Read-Host "Press Enter to exit"; exit 1
}
$Exe = Join-Path $GameRoot "PRBF2.exe"
$Launcher = Join-Path $GameRoot "mods\pr\bin\PRLauncher.exe"

function Get-Game { Get-Process -Name "PRBF2" -ErrorAction SilentlyContinue | Select-Object -First 1 }
function Get-Launcher {   # the oldest one = the logged-in main instance
    Get-Process -Name "PRLauncher" -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
}

# ---------- install: scheduled task + desktop shortcut ----------
if ($Install) {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 24)
    $task = @{ TaskName = $TaskName; Action = $action; Principal = $principal; Settings = $settings; Force = $true }
    if ($DailyAt) { $task.Trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt }
    Register-ScheduledTask @task | Out-Null
    $lnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "PR Seeder.lnk"
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $sc.TargetPath = "$env:WINDIR\System32\schtasks.exe"
    $sc.Arguments = "/run /tn $TaskName"
    $sc.IconLocation = "$Exe,0"
    $sc.WindowStyle = 7
    $sc.Save()
    Log "Installed: scheduled task $TaskName$(if ($DailyAt) { " (daily at $DailyAt)" }) and desktop shortcut 'PR Seeder'. It uses config.json next to this script." Green
    Start-Sleep -Seconds 3; exit
}

# ---------- graphics/audio: back up -> lower -> restore at the end ----------
$ProfDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "ProjectReality\Profiles"
$userId = (Select-String -Path (Join-Path $ProfDir "Global.con") -Pattern 'setDefaultUser "(\d+)"').Matches[0].Groups[1].Value
$ProfDir = Join-Path $ProfDir $userId
# The in-game clicks below are 800x600 client coordinates, so the resolution is always forced, even with -NoLowGfx.
$Patches = @{ "Video.con" = @{ 'setResolution \S+' = 'setResolution 800x600@60Hz' } }
if (-not $NoLowGfx) {
    $Patches["Video.con"] += @{
        'setTerrainQuality \S+' = 'setTerrainQuality 0'; 'setGeometryQuality \S+' = 'setGeometryQuality 0'
        'setLightingQuality \S+' = 'setLightingQuality 0'; 'setDynamicLightingQuality \S+' = 'setDynamicLightingQuality 0'
        'setDynamicShadowsQuality \S+' = 'setDynamicShadowsQuality 0'; 'setEffectsQuality \S+' = 'setEffectsQuality 0'
        'setTextureQuality \S+' = 'setTextureQuality 0'; 'setTextureFilteringQuality \S+' = 'setTextureFilteringQuality 0'
        'setViewDistanceScale \S+' = 'setViewDistanceScale 0.5'
    }
    $Patches["Audio.con"] = @{
        'setVoipEnabled \S+' = 'setVoipEnabled 0'; 'setSoundQuality \S+' = 'setSoundQuality "Low"'
        'setEnableEAX \S+' = 'setEnableEAX 0'; 'setProvider \S+' = 'setProvider "software"'
        'setEffectsVolume \S+' = 'setEffectsVolume 0'; 'setMusicVolume \S+' = 'setMusicVolume 0'; 'setHelpVoiceVolume \S+' = 'setHelpVoiceVolume 0'
    }
    $Patches["General.con"] = @{ 'setViewIntroMovie \S+' = 'setViewIntroMovie 0' }
}
function Restore-Settings {
    foreach ($f in "Video.con", "Audio.con", "General.con") {
        $b = Join-Path $BackupDir $f
        if (Test-Path $b) { Copy-Item $b (Join-Path $ProfDir $f) -Force; Remove-Item $b }
    }
}
function Apply-LowSettings {
    Restore-Settings   # if the last run didn't exit cleanly, put the originals back before backing up again
    foreach ($f in $Patches.Keys) {
        $p = Join-Path $ProfDir $f
        if (-not (Test-Path $p)) { continue }
        Copy-Item $p (Join-Path $BackupDir $f) -Force
        $txt = [IO.File]::ReadAllText($p)
        foreach ($kv in $Patches[$f].GetEnumerator()) { $txt = $txt -replace $kv.Key, $kv.Value }
        [IO.File]::WriteAllText($p, $txt)
    }
}
if ($Restore) { Restore-Settings; Log "Graphics/audio settings restored" Green; exit }

if (-not $Player -or -not $Server) {
    Log "Set your in-game name and the server IP: seed.ps1 -Player MyName -Server 1.2.3.4 (or put them in config.json)." Red
    Read-Host "Press Enter to exit"; exit 1
}

# ---------- debug/remote mode: a scheduled task can't take arguments, so commands go in a mode file (one per line, deleted after use) ----------
#   play | click X Y | dblclick X Y | key KEYS | wait SECONDS | lowgfx | restore | kill | uia-dump
#   coordinates are game-window client coordinates (800x600)
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class PRUI {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, IntPtr e);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static void Click(IntPtr h, int x, int y, int times) {
        SetProcessDPIAware();
        ShowWindow(h, 9); SetForegroundWindow(h); System.Threading.Thread.Sleep(300);
        POINT p = new POINT(); p.X = x; p.Y = y; ClientToScreen(h, ref p);
        SetCursorPos(p.X, p.Y); System.Threading.Thread.Sleep(150);
        for (int i = 0; i < times; i++) {
            mouse_event(2, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(60);
            mouse_event(4, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(90);
        }
    }
}
"@
function Invoke-LauncherPlay {
    if (-not (Get-Launcher)) {
        Start-Process -FilePath $Launcher -WorkingDirectory (Split-Path $Launcher) | Out-Null
        Log "Opened the launcher, waiting $LoginWaitSec s for login" Cyan
        Start-Sleep -Seconds $LoginWaitSec
    }
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $main = Get-Launcher
    $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $main.Id)
    $win = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $cond)
    $idc = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, "uxMainLaunch")
    $btn = if ($win) { $win.FindFirst([Windows.Automation.TreeScope]::Descendants, $idc) }
    if (-not $btn) { Log "PLAY button not found in the launcher (not logged in yet?)" Red; return $false }
    $btn.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Log "Clicked launcher PLAY" Cyan
    return $true
}
$ModeFile = Join-Path $Data "mode"
if (Test-Path $ModeFile) {
    $cmds = Get-Content $ModeFile; Remove-Item $ModeFile
    foreach ($line in $cmds) {
        $a = -split $line; if (-not $a) { continue }
        Log "remote: $line" DarkCyan
        switch ($a[0]) {
            "play"     { [void](Invoke-LauncherPlay) }
            "click"    { $g = Get-Game; if ($g) { [PRUI]::Click($g.MainWindowHandle, [int]$a[1], [int]$a[2], 1) } }
            "dblclick" { $g = Get-Game; if ($g) { [PRUI]::Click($g.MainWindowHandle, [int]$a[1], [int]$a[2], 2) } }
            "key"      { $g = Get-Game; if ($g) { [void][PRUI]::SetForegroundWindow($g.MainWindowHandle); Start-Sleep -Milliseconds 200
                            Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.SendKeys]::SendWait(($a[1..($a.Count-1)] -join ' ')) } }
            "wait"     { Start-Sleep -Seconds ([int]$a[1]) }
            "lowgfx"   { Apply-LowSettings }
            "restore"  { Restore-Settings }
            "kill"     { Get-Process -Name "PRBF2", "PRLauncher" -ErrorAction SilentlyContinue | Stop-Process -Force }
            "uia-dump" {
                Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
                $out = New-Object Collections.Generic.List[string]
                $walker = [Windows.Automation.TreeWalker]::RawViewWalker
                function Dump($el, $depth) {
                    if ($depth -gt 14 -or $out.Count -gt 3000) { return }
                    $c = $el.Current
                    $out.Add(("{0}{1} name='{2}' id='{3}' class='{4}'" -f ("  " * $depth), $c.ControlType.ProgrammaticName, $c.Name, $c.AutomationId, $c.ClassName))
                    $ch = $walker.GetFirstChild($el)
                    while ($ch) { Dump $ch ($depth + 1); $ch = $walker.GetNextSibling($ch) }
                }
                foreach ($p in Get-Process -Name "PRLauncher" -ErrorAction SilentlyContinue) {
                    $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
                    foreach ($w in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $cond)) { Dump $w 0 }
                }
                $out | Set-Content (Join-Path $Data "uia.txt") -Encoding UTF8
            }
        }
    }
    Log "remote: done" DarkCyan
    exit
}

# ---------- native helpers: throttling / efficiency mode / minimize ----------
Add-Type -TypeDefinition @"
using System; using System.Threading; using System.Runtime.InteropServices;
public static class PRW {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool SetProcessInformation(IntPtr h, int cls, ref PPTS info, int size);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    public delegate bool CtrlHandler(int type);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(CtrlHandler h, bool add);
    [StructLayout(LayoutKind.Sequential)] struct PPTS { public uint Version, ControlMask, StateMask; }

    static readonly object gate = new object();
    static IntPtr h = IntPtr.Zero; static bool running, suspended; static Thread t;
    static CtrlHandler keep = new CtrlHandler(OnCtrl);
    static bool OnCtrl(int type) { Stop(); return false; }   // never leave the game frozen on window close / Ctrl+C
    static PRW() { SetConsoleCtrlHandler(keep, true); timeBeginPeriod(1); }

    public static void Start(int pid, int onMs, int offMs) {
        Stop();
        h = OpenProcess(0x0800 | 0x0200, false, pid);   // SUSPEND_RESUME | SET_INFORMATION
        if (h == IntPtr.Zero || offMs <= 0) return;
        running = true;
        t = new Thread(() => {
            while (true) {
                Thread.Sleep(onMs);
                lock (gate) { if (!running) return; NtSuspendProcess(h); suspended = true; }
                Thread.Sleep(offMs);
                lock (gate) { NtResumeProcess(h); suspended = false; if (!running) return; }
            }
        });
        t.IsBackground = true; t.Start();
    }
    public static void Stop() {
        lock (gate) {
            running = false;
            if (h != IntPtr.Zero) { if (suspended) { NtResumeProcess(h); suspended = false; } CloseHandle(h); h = IntPtr.Zero; }
        }
    }
    public static void Resume(int pid) {   // on takeover: a previous instance that was killed may have left the game suspended
        IntPtr p = OpenProcess(0x0800, false, pid); if (p == IntPtr.Zero) return;
        for (int i = 0; i < 3; i++) NtResumeProcess(p);
        CloseHandle(p);
    }
    public static bool Eco(int pid) {   // Windows 11 efficiency mode (EcoQoS)
        IntPtr p = OpenProcess(0x0200, false, pid); if (p == IntPtr.Zero) return false;
        PPTS s = new PPTS(); s.Version = 1; s.ControlMask = 1; s.StateMask = 1;
        bool ok = SetProcessInformation(p, 4, ref s, Marshal.SizeOf(typeof(PPTS)));
        CloseHandle(p); return ok;
    }
}
"@

# ---------- server query: ask the server's GameSpy port directly, fall back to the official server list ----------
$NameBytes = [Text.Encoding]::ASCII.GetBytes($Player)
function Test-Contains([byte[]]$hay, [byte[]]$needle) {
    for ($i = 0; $i -le $hay.Length - $needle.Length; $i++) {
        $j = 0; while ($j -lt $needle.Length -and $hay[$i + $j] -eq $needle[$j]) { $j++ }
        if ($j -eq $needle.Length) { return $true }
    }
    return $false
}
function Query-Server {
    $udp = New-Object Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = 3000
        $pkt = [byte[]](0xFE, 0xFD, 0x00, 0x50, 0x52, 0x57, 0x4D, 0xFF, 0xFF, 0xFF, 0x01)
        [void]$udp.Send($pkt, $pkt.Length, $Server, $QueryPort)
        $buf = New-Object IO.MemoryStream
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        try { while ($true) { $d = $udp.Receive([ref]$ep); $buf.Write($d, 0, $d.Length); $udp.Client.ReceiveTimeout = 800 } } catch {}
        $all = $buf.ToArray()
        if ($all.Length -gt 0) {
            $s = [Text.Encoding]::GetEncoding(28591).GetString($all)
            $n = if ($s -match "numplayers\x00(\d+)\x00") { [int]$Matches[1] } else { -1 }
            return @{ ok = $true; me = (Test-Contains $all $NameBytes); players = $n; via = "direct" }
        }
    } catch {} finally { $udp.Close() }
    try {
        $r = Invoke-RestMethod "https://servers.realitymod.com/api/ServerInfo" -TimeoutSec 15
        foreach ($sv in $r.servers) {
            if ($sv.players | Where-Object { $_.name.Trim() -like "*$Player" }) {
                return @{ ok = $true; me = $true; players = [int]$sv.properties.numplayers; via = "server list" }
            }
        }
        return @{ ok = $true; me = $false; players = -1; via = "server list" }
    } catch { return @{ ok = $false } }
}

# ---------- game process ----------
function Start-Game {
    # Same as by hand: launcher (logged in) PLAY -> main menu MULTIPLAYER -> JOIN INTERNET -> JOIN IP -> IP/port -> OK
    # (launching with a +join link ends in "failed to connect", so that route isn't used)
    if (Get-Game) { Stop-Game; Start-Sleep -Seconds 3 }
    if (-not (Invoke-LauncherPlay)) {
        Log "Launcher in a bad state, restarting it" Yellow
        Get-Process -Name "PRLauncher" -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 5
        if (-not (Invoke-LauncherPlay)) { return }
    }
    $t0 = Get-Date
    while (-not ($g = Get-Game) -or $g.MainWindowHandle -eq 0) {
        if (((Get-Date) - $t0).TotalSeconds -gt 180) { Log "Game window didn't appear within 3 minutes" Red; return }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds $MenuWaitSec   # wait for the main menu
    Invoke-Steps @(@("click", 30, 445, 4), @("click", 35, 422, 10))   # MULTIPLAYER -> JOIN INTERNET (wait for the server list)
    Join-ByIp
}
function Invoke-Steps($steps) {
    $h = (Get-Game).MainWindowHandle
    Add-Type -AssemblyName System.Windows.Forms
    foreach ($st in $steps) {
        if ($st[0] -eq "click") { [PRUI]::Click($h, $st[1], $st[2], 1); Start-Sleep -Seconds $st[3] }
        else { [void][PRUI]::SetForegroundWindow($h); Start-Sleep -Milliseconds 200; [Windows.Forms.SendKeys]::SendWait($st[1]); Start-Sleep -Seconds $st[2] }
    }
}
function Join-ByIp([switch]$Retry) {
    # Must already be on the JOIN INTERNET server list. Retry = first click OK on the "failed to connect" popup (harmless without one: just selects a row)
    $steps = @()
    if ($Retry) { $steps += , @("click", 538, 355, 2) }
    $steps += @(
        @("click", 20, 468, 3),   # JOIN IP
        @("click", 500, 244, 1), @("key", "{END}{BACKSPACE 25}$Server", 1),
        @("click", 500, 264, 1), @("key", "{END}{BACKSPACE 25}$Port", 1),
        @("click", 516, 314, 1)   # OK
    )
    Invoke-Steps $steps
    Log "JOIN IP ${Server}:$Port sent in game" Cyan
}
function Save-Shot($tag) {   # screenshot on failure, for troubleshooting
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $b = [Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
        [Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
        $f = Join-Path $Data ("shot_{0:MMdd_HHmmss}_$tag.png" -f (Get-Date)); $bmp.Save($f); $bmp.Dispose()
        Get-ChildItem $Data -Filter "shot_*.png" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item
    } catch {}
}
function Stop-Game {
    [PRW]::Stop()
    $g = Get-Game
    if ($g) { Stop-Process -Id $g.Id -Force; $g.WaitForExit(15000) | Out-Null }
}
function Set-Quiet($g) {
    try { $g.PriorityClass = "Idle" } catch {}
    $n = [Environment]::ProcessorCount
    if ($Cores -gt 0 -and $Cores -lt $n) {
        $mask = 0L; for ($i = $n - $Cores; $i -lt $n; $i++) { $mask = $mask -bor (1L -shl $i) }
        try { $g.ProcessorAffinity = [IntPtr]$mask } catch {}
    }
    $eco = [PRW]::Eco($g.Id)
    if (-not $NoMinimize -and $g.MainWindowHandle -ne 0) { [void][PRW]::ShowWindow($g.MainWindowHandle, 6) }
    $on = [int][Math]::Round(50 * [Math]::Min(100, [Math]::Max(5, $Duty)) / 100)
    [PRW]::Start($g.Id, $on, 50 - $on)
    Log "In server -> quiet mode (Idle priority, efficiency mode=$eco, last $Cores cores, duty $Duty%)" Green
}

# ---------- main loop ----------
Remove-Item $StopFlag -ErrorAction SilentlyContinue
Apply-LowSettings
$deadline = (Get-Date).AddHours($Hours)
if ($Until) { $deadline = [datetime]::Today.Add([timespan]::Parse($Until)); if ($deadline -le (Get-Date)) { $deadline = $deadline.AddDays(1) } }
Log "Seeding ${Server}:$Port as $Player until $($deadline.ToString('HH:mm'))$(if ($StopAtPlayers) { " (or $StopAtPlayers other players)" })" Yellow
$quietPid = 0; $miss = 0; $reconnects = 0; $joined = $false; $quick = 0
$g = Get-Game
$launchedAt = if ($g) { Log "Game already running, taking it over"; [PRW]::Resume($g.Id); $g.StartTime } else { Start-Game; Get-Date }
try {
    while ((Get-Date) -lt $deadline -and -not (Test-Path $StopFlag)) {
        Start-Sleep -Seconds 20
        $g = Get-Game
        if (-not $g) {
            Log "Game process is gone, restarting" Yellow
            $quietPid = 0; $joined = $false; $quick = 0; $reconnects++; Start-Game; $launchedAt = Get-Date; continue
        }
        $q = Query-Server
        if (-not $q.ok) { Log "Can't reach the server (network/VPN down?), waiting" DarkYellow; continue }
        if ($q.me) {
            $miss = 0; $joined = $true; $quick = 0
            if ($quietPid -ne $g.Id) { Set-Quiet $g; $quietPid = $g.Id }
            $others = $q.players - 1
            $Host.UI.RawUI.WindowTitle = "PR Seeder | online | $($q.players) players | $reconnects reconnects | $([int]($deadline - (Get-Date)).TotalMinutes) min left"
            if ($StopAtPlayers -gt 0 -and $others -ge $StopAtPlayers) { Log "Server has $others other players, seeding done" Green; break }
        }
        elseif (((Get-Date) - $launchedAt).TotalMinutes -ge $GraceMin) {
            $miss++
            Log "You're not in the server's player list ($($q.via)) ($miss/3)" DarkYellow
            if ($miss -ge 3) {
                $miss = 0; $reconnects++
                if (-not $joined -and $quick -lt 2) {
                    # never got in since this launch -> the game is sitting on the server list, so retry in game instead of restarting
                    $quick++
                    Log "Didn't connect (likely network), retrying JOIN IP in game ($quick/2)" Yellow
                    Save-Shot "fail"
                    Join-ByIp -Retry
                }
                else {
                    Log "Dropped, restarting the game to reconnect" Yellow
                    Save-Shot "drop"
                    Stop-Game; $quietPid = 0; $joined = $false; $quick = 0
                    Start-Sleep -Seconds 5
                    Start-Game
                }
                $launchedAt = Get-Date
            }
        }
    }
    Log "Seeding finished ($reconnects reconnects)" Green
}
finally {
    Stop-Game
    Restore-Settings
    Log "Game closed and settings restored"
}
