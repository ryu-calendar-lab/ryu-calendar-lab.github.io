param(
    [int]$PollSeconds = 15
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/ryu-calendar-lab/ryu-calendar-lab.github.io.git"
$BaseDir = Join-Path $env:LOCALAPPDATA "ChatGPTCodexBridge"
$RepoDir = Join-Path $BaseDir "queue-repo"
$StateFile = Join-Path $BaseDir "state.json"
$LogDir = Join-Path $BaseDir "logs"
$TaskGlob = Join-Path $RepoDir "codex-bridge\tasks\*.json"

New-Item -ItemType Directory -Force -Path $BaseDir,$LogDir | Out-Null

function Write-BridgeLog([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path (Join-Path $LogDir "bridge.log") -Value $line -Encoding UTF8
}

function Load-State {
    if (-not (Test-Path $StateFile)) {
        return @{ tasks = @{} }
    }
    try {
        $raw = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if (-not $raw.ContainsKey("tasks")) { $raw["tasks"] = @{} }
        return $raw
    } catch {
        Write-BridgeLog "state.json could not be read; starting with empty state: $($_.Exception.Message)"
        return @{ tasks = @{} }
    }
}

function Save-State($State) {
    $State | ConvertTo-Json -Depth 8 | Set-Content $StateFile -Encoding UTF8
}

function Sync-QueueRepo {
    if (-not (Test-Path (Join-Path $RepoDir ".git"))) {
        Write-BridgeLog "Cloning queue repository."
        & git clone --quiet $RepoUrl $RepoDir
        if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE" }
    } else {
        & git -C $RepoDir fetch origin main --quiet
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed with exit code $LASTEXITCODE" }
        & git -C $RepoDir reset --hard origin/main --quiet
        if ($LASTEXITCODE -ne 0) { throw "git reset failed with exit code $LASTEXITCODE" }
    }
}

function Invoke-CodexTask($TaskFile, $Task, $State) {
    $id = [string]$Task.id
    $title = [string]$Task.title
    $targetPath = [Environment]::ExpandEnvironmentVariables([string]$Task.target_path)
    $prompt = [string]$Task.prompt

    if ([string]::IsNullOrWhiteSpace($id)) { throw "Task has no id: $($TaskFile.FullName)" }
    if ([string]::IsNullOrWhiteSpace($targetPath)) { throw "Task '$id' has no target_path." }
    if ([string]::IsNullOrWhiteSpace($prompt)) { throw "Task '$id' has no prompt." }
    if ($prompt.Length -gt 24000) { throw "Task '$id' prompt is too long for safe Windows argument passing (max 24000 characters)." }
    if (-not (Test-Path $targetPath -PathType Container)) { throw "Target path does not exist: $targetPath" }

    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) { throw "codex command was not found in PATH." }

    $resultPath = Join-Path $LogDir ("task-{0}.stdout.txt" -f $id)
    $errorPath = Join-Path $LogDir ("task-{0}.stderr.txt" -f $id)

    Write-BridgeLog "Starting task '$id' ($title) in '$targetPath'."

    $taskPrompt = @"
You are running from the ChatGPT-to-Codex Bridge.

Task ID: $id
Task title: $title

Follow the specification below. Work only inside the current project unless the specification explicitly requires otherwise.
Inspect the existing code before modifying it.
Do not delete unrelated user data.
Preserve existing behavior unless the specification explicitly changes it.
Run relevant tests/checks before finishing.
At the end, summarize what changed, tests run, and any remaining issues.

SPECIFICATION
-------------
$prompt
"@

    Push-Location $targetPath
    try {
        & codex exec --full-auto $taskPrompt 1> $resultPath 2> $errorPath
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $status = if ($exit -eq 0) { "completed" } else { "failed" }
    $State.tasks[$id] = @{
        status = $status
        title = $title
        target_path = $targetPath
        finished_at = (Get-Date).ToString("o")
        exit_code = $exit
        stdout = $resultPath
        stderr = $errorPath
    }
    Save-State $State
    Write-BridgeLog "Task '$id' finished with status=$status exit_code=$exit."
}

Write-BridgeLog "Bridge starting. Poll interval: $PollSeconds seconds."

while ($true) {
    try {
        Sync-QueueRepo
        $state = Load-State
        $taskFiles = Get-ChildItem -Path $TaskGlob -File -ErrorAction SilentlyContinue | Sort-Object Name

        foreach ($file in $taskFiles) {
            try {
                $task = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $id = [string]$task.id
                if ([string]::IsNullOrWhiteSpace($id)) {
                    Write-BridgeLog "Skipping malformed task with no id: $($file.FullName)"
                    continue
                }
                if ($state.tasks.ContainsKey($id)) { continue }

                Invoke-CodexTask -TaskFile $file -Task $task -State $state
            } catch {
                Write-BridgeLog "Task processing error for '$($file.Name)': $($_.Exception.Message)"
            }
        }
    } catch {
        Write-BridgeLog "Bridge loop error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $PollSeconds
}
