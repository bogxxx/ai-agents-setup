# preToolUse guard for the orchestrator: the task tool may only launch cantrip agents.
$ErrorActionPreference = 'Stop'
$allowed = @('explorer', 'planner', 'worker', 'reviewer')
try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
} catch {
    exit 0
}

$calls = @()
if ($payload.toolName) { $calls += [pscustomobject]@{ name = $payload.toolName; args = $payload.toolArgs } }
elseif ($payload.tool_name) { $calls += [pscustomobject]@{ name = $payload.tool_name; args = $payload.tool_input } }
if ($payload.toolCalls) { $calls += $payload.toolCalls }

foreach ($call in $calls) {
    if ($call.name -notin @('task', 'Task', 'Agent')) { continue }
    $toolArgs = $call.args
    if ($toolArgs -is [string]) { try { $toolArgs = $toolArgs | ConvertFrom-Json } catch { $toolArgs = $null } }
    $agentType = if ($toolArgs) { [string]$toolArgs.agent_type } else { '' }
    if ($agentType -notin $allowed) {
        $reason = "Forbidden agent_type '$agentType'. The orchestrator may only delegate to cantrip agents: $($allowed -join ', '). Built-in and default agents are not allowed. Delegate to the matching cantrip role; run verification commands with your own shell tool."
        @{ permissionDecision = 'deny'; permissionDecisionReason = $reason } | ConvertTo-Json -Compress
        exit 0
    }
}
exit 0
