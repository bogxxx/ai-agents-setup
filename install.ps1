# Installs the GitHub Copilot part of the agent setup on Windows.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }
$agents = Join-Path $copilotHome 'agents'
$cantrip = Join-Path $copilotHome 'cantrip'
New-Item -ItemType Directory -Force $agents, $cantrip | Out-Null
Copy-Item (Join-Path $here 'copilot\agents\*.agent.md') $agents -Force
Copy-Item (Join-Path $here 'copilot\copilot-instructions.md') $copilotHome -Force
foreach ($f in 'cantrip-agent-guard.ps1', 'cantrip-agent-guard.sh', 'archgate-stop-gate.mjs') {
    Copy-Item (Join-Path $here "copilot\hooks\$f") $cantrip -Force
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warning 'node is not on PATH: the Archgate stop gate (agentStop hook) will not run.'
}
if (-not ((Get-Command archgate -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.archgate\bin\archgate.exe')))) {
    Write-Warning 'Archgate CLI not found: install it with: irm https://cli.archgate.dev/install-windows | iex  (then run: archgate login)'
}
Write-Output "installed to $copilotHome; restart Copilot sessions to load the agents"
