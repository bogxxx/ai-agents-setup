# Runs the guard hooks against test/guard-cases.json, and the stop gate tests when node is available.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File copilot/hooks/test-hooks.ps1 [-IncludeSh]
# The POSIX guard runs by default off Windows; on Windows pass -IncludeSh (Git's MSYS sh is slow there).
param([switch]$IncludeSh)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cases = Get-Content -Raw ([IO.Path]::Combine($here, 'test', 'guard-cases.json')) | ConvertFrom-Json
$fakeHome = Join-Path ([IO.Path]::GetTempPath()) ("cantrip-hooktest-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force ([IO.Path]::Combine($fakeHome, 'session-state', 'root-session')) | Out-Null
$env:COPILOT_HOME = $fakeHome
$env:CANTRIP_STATE_DIR = [IO.Path]::Combine($fakeHome, 'guard-state')
$storage = [IO.Path]::Combine($fakeHome, 'storage')
New-Item -ItemType Directory -Force $storage | Out-Null
$env:BB_THREAD_STORAGE = $storage
New-Item -ItemType Directory -Force ([IO.Path]::Combine($fakeHome, 'session-state', 'root-budget')) | Out-Null
$storage = [IO.Path]::Combine($fakeHome, 'storage')
New-Item -ItemType Directory -Force $storage | Out-Null
$env:BB_THREAD_STORAGE = $storage

$psHost = (Get-Process -Id $PID).Path
$runners = @(@{ name = 'ps1'; run = { param($json) $json | & $psHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'cantrip-agent-guard.ps1') } })
$onWindows = $env:OS -eq 'Windows_NT'
$sh = if (-not $onWindows -or $IncludeSh) { Get-Command sh -ErrorAction SilentlyContinue } else { $null }
if ($onWindows -and $IncludeSh -and -not $sh) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $candidate = Join-Path (Split-Path (Split-Path $git.Source)) 'usr\bin\sh.exe'
        if (Test-Path $candidate) { $env:PATH = (Split-Path $candidate) + ';' + $env:PATH; $sh = Get-Command $candidate }
    }
}
if ($sh) {
    $shScript = (Join-Path $here 'cantrip-agent-guard.sh') -replace '\\', '/'
    $runners += @{ name = 'sh'; run = { param($json) $json | & $sh.Source $shScript } }
}

$failures = 0
foreach ($runner in $runners) {
    foreach ($case in $cases) {
        $sessionId = if ($case.s -eq 'root') { 'root-session' } else { 'subagent-1234' }
        $json = @{ sessionId = $sessionId; toolName = $case.t; toolArgs = $case.a } | ConvertTo-Json -Compress -Depth 5
        $out = & $runner.run $json
        $got = if ("$out" -match '"permissionDecision":\s*"deny"') { 'deny' } else { 'allow' }
        if ($got -ne $case.e) {
            $failures++
            Write-Output ("FAIL [{0}] {1} expected {2}, got {3}: {4}" -f $runner.name, $case.id, $case.e, $got, $json)
        }
    }
    # The thread-storage heredoc is only exempt when the hook sees BB_THREAD_STORAGE.
    $a3 = $cases | Where-Object { $_.id -eq 'A3' }
    $json = @{ sessionId = 'root-session'; toolName = $a3.t; toolArgs = $a3.a } | ConvertTo-Json -Compress -Depth 5
    Remove-Item Env:BB_THREAD_STORAGE
    if ("$(& $runner.run $json)" -notmatch '"permissionDecision":\s*"deny"') { $failures++; Write-Output ("FAIL [{0}] A3 without BB_THREAD_STORAGE was allowed" -f $runner.name) }
    $env:BB_THREAD_STORAGE = $storage
    # Read budget: with a budget of 2, the third root view is denied; subagent reads are never counted.
    $env:CANTRIP_READ_BUDGET = '2'
    Remove-Item -Recurse -Force $env:CANTRIP_STATE_DIR -ErrorAction SilentlyContinue
    $view = @{ sessionId = 'root-budget'; toolName = 'view'; toolArgs = @{ path = 'a.py' } } | ConvertTo-Json -Compress
    $sub = @{ sessionId = 'subagent-1234'; toolName = 'view'; toolArgs = @{ path = 'a.py' } } | ConvertTo-Json -Compress
    $got = @($view, $view, $sub, $view) | ForEach-Object { if ("$(& $runner.run $_)" -match '"permissionDecision":\s*"deny"') { 'deny' } else { 'allow' } }
    if (($got -join ',') -ne 'allow,allow,allow,deny') { $failures++; Write-Output ("FAIL [{0}] read budget: {1}" -f $runner.name, ($got -join ',')) }
    Remove-Item Env:CANTRIP_READ_BUDGET
    Remove-Item -Recurse -Force $env:CANTRIP_STATE_DIR -ErrorAction SilentlyContinue
    # The heredoc write to thread storage is exempt only when the hook sees BB_THREAD_STORAGE; without it, it is denied.
    $a3 = $cases | Where-Object { $_.id -eq 'A3' }
    $storageValue = $env:BB_THREAD_STORAGE
    Remove-Item Env:BB_THREAD_STORAGE
    $json = @{ sessionId = 'root-session'; toolName = $a3.t; toolArgs = $a3.a } | ConvertTo-Json -Compress -Depth 5
    if ("$(& $runner.run $json)" -notmatch '"permissionDecision":\s*"deny"') { $failures++; Write-Output ("FAIL [{0}] A3 without BB_THREAD_STORAGE must be denied" -f $runner.name) }
    $env:BB_THREAD_STORAGE = $storageValue
    Write-Output ("[{0}] {1} cases run, plus the read budget and the unset-storage check" -f $runner.name, $cases.Count)
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    & $node.Source ([IO.Path]::Combine($here, 'test', 'stop-gate.test.mjs'))
    if ($LASTEXITCODE -ne 0) { $failures++ }
}

Remove-Item -Recurse -Force $fakeHome
if ($failures) { Write-Output "$failures failure(s)"; exit 1 }
Write-Output 'all hook tests passed'
