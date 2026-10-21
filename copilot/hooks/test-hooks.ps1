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
            Write-Output ("FAIL [{0}] expected {1}, got {2}: {3}" -f $runner.name, $case.e, $got, $json)
        }
    }
    Write-Output ("[{0}] {1} cases run" -f $runner.name, $cases.Count)
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    & $node.Source ([IO.Path]::Combine($here, 'test', 'stop-gate.test.mjs'))
    if ($LASTEXITCODE -ne 0) { $failures++ }
}

Remove-Item -Recurse -Force $fakeHome
if ($failures) { Write-Output "$failures failure(s)"; exit 1 }
Write-Output 'all hook tests passed'
