param(
    [switch]$NoAutoStart
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/ryu-calendar-lab/ryu-calendar-lab.github.io.git"
$BaseDir = Join-Path $env:LOCALAPPDATA "ChatGPTCodexBridge"
$RepoDir = Join-Path $BaseDir "queue-repo"
$BridgeScript = Join-Path $RepoDir "codex-bridge\bridge.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDir "ChatGPT Codex Bridge.lnk"

Write-Host "=== ChatGPT Codex Bridge installer ==="

foreach ($cmd in @("git","codex")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "'$cmd' was not found in PATH. Install/configure it first, then run this installer again."
    }
}

Write-Host ("Git:   " + (& git --version))
Write-Host ("Codex: " + (& codex --version))

New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null

if (-not (Test-Path (Join-Path $RepoDir ".git"))) {
    Write-Host "Cloning bridge queue repository..."
    & git clone $RepoUrl $RepoDir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed." }
} else {
    Write-Host "Updating existing bridge queue repository..."
    & git -C $RepoDir fetch origin main --quiet
    & git -C $RepoDir reset --hard origin/main --quiet
}

if (-not (Test-Path $BridgeScript)) {
    throw "Bridge script was not found at $BridgeScript"
}

$ws = New-Object -ComObject WScript.Shell
$shortcut = $ws.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $BridgeScript + '"'
$shortcut.WorkingDirectory = Split-Path $BridgeScript
$shortcut.Description = "Starts the ChatGPT-to-Codex bridge at Windows sign-in"
$shortcut.Save()

Write-Host "Startup shortcut created:"
Write-Host "  $ShortcutPath"

if (-not $NoAutoStart) {
    $existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*ChatGPTCodexBridge*bridge.ps1*" }

    if (-not $existing) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            "-NoLogo","-NoProfile","-ExecutionPolicy","Bypass","-File",$BridgeScript
        )
        Write-Host "Bridge started."
    } else {
        Write-Host "Bridge already appears to be running."
    }
}

Write-Host ""
Write-Host "Installation complete."
Write-Host "Logs:  $BaseDir\logs\bridge.log"
Write-Host "State: $BaseDir\state.json"
Write-Host ""
Write-Host "From now on, ChatGPT can create a task file under codex-bridge/tasks/."
Write-Host "The bridge will detect it and run Codex in the task's target_path."
