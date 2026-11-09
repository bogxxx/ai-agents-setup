# preToolUse guard for the cantrip orchestrator.
# - Every agent in the session: `task` may only launch cantrip agents.
# - The orchestrator itself (root session): no file edits and no mutating shell commands; delegate them to a worker.
$ErrorActionPreference = 'Stop'
$allowedAgents = @('explorer', 'planner', 'worker', 'reviewer')
$editTools = @('edit', 'create', 'apply_patch', 'str_replace_editor', 'str_replace', 'write', 'multi_edit', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit')
$shellTools = @('powershell', 'bash', 'write_powershell', 'write_bash', 'Bash')
$readTools = @('view', 'grep', 'glob', 'rg', 'Read', 'Grep', 'Glob')
$readBudget = if ($env:CANTRIP_READ_BUDGET) { [int]$env:CANTRIP_READ_BUDGET } else { 30 }
$mutating = @(
    '\bgit\b[^;|&\r\n]*?\s(commit|merge|rebase|cherry-pick|revert|push|pull|reset|restore|checkout|switch|stash|am|apply|add|rm|mv|clean|tag|init|clone)\b',
    '\bgit\b[^;|&\r\n]*?\sworktree\s+(add|remove|move|prune)\b',
    '\bgit\b[^;|&\r\n]*?\sbranch\s+(-[dDmMcCf]|--(delete|move|copy|force))',
    '\bgh\s+(pr|issue)\s+(create|edit|merge|close|reopen|comment|review|ready|delete|lock|transfer|checkout)\b',
    '\bgh\s+(release|repo|label|workflow|run|secret|variable)\s+(create|delete|edit|upload|enable|disable|run|rerun|cancel|set|clone|fork)\b',
    '\bgh\s+api\b[^;|\r\n]*(-X|--method)\s*(POST|PUT|PATCH|DELETE)',
    '\b(Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item|Rename-Item|Clear-Content|Export-Csv|Export-Clixml|Expand-Archive|Compress-Archive|Set-ItemProperty)\b',
    '\[(System\.)?IO\.(File|Directory)\]::(Write|Append|Delete|Move|Copy|Create|Replace)',
    '-OutFile\b',
    '(?m)(^|[;&|(]\s*)\s*(rm|mv|cp|touch|mkdir|rmdir|tee|truncate|ln|del|copy|move|ren|md|rd)\s',
    '\bsed\s+-i', '\bperl\s+-\w*i',
    '(^|[^0-9&=>\-])>>?(?!\s*(\$null|/dev/null|nul\b|&))\s*\S',
    '\s--fix\b', '\s--write\b',
    '\bruff\s+format\b(?![^;|\r\n]*--(check|diff))',
    '\bblack\b(?![^;|\r\n]*--check)',
    '\b(uv\s+(add|remove|lock)|uv\s+pip\s+install|pip3?\s+install|npm\s+(install|i|ci|uninstall|update)|pnpm\s+(add|install|remove)|yarn\s+(add|install|remove)|bun\s+(add|install|remove))\b',
    '\barchgate\b[^;|\r\n]*\s(init|adr\s+(create|update|import))\b',
    # Thread storage is writable through the here-string form below, so it may only be read: never redefined or executed.
    '(?i)\$env:BB_THREAD_STORAGE\s*=',
    '(?im)(^|[^a-z0-9_-])(sh|bash|zsh|dash|ksh|source|eval|exec|python3?|node|perl|ruby|pwsh|powershell|iex|invoke-expression)[ \t][^;|&\r\n]*BB_THREAD_STORAGE',
    '(?im)(^|[;&|(])[ \t]*\.[ \t]+[^;|&\r\n]*BB_THREAD_STORAGE',
    '(?im)(^|[;&|(])[ \t]*(&[ \t]*)?"?\$\{?(env:)?BB_THREAD_STORAGE',
    '(?i)BB_THREAD_STORAGE[^;&\r\n]*\|[ \t]*(sh|bash|zsh|dash|ksh|pwsh|powershell|iex|invoke-expression)([^a-z]|$)',
    '(?im)(^|[^a-z])(alias|function|hash)[ \t]',
    '(?im)(^|[^a-z])export[ \t]+-f\b',
    '\(\)[ \t]*\{',
    '(?im)(^|[ ;&|(])PATH=',
    '(?i)\$env:PATH\s*=',
    '(?i)\b(Set-Alias|New-Alias|Set-Item)\b'
)
$assignmentHint = 'To hand over an assignment, write it with cat > "$BB_THREAD_STORAGE/<name>.md" <<''EOF'', the text, then EOF on its own line, then run bb plugin run role-picker spawn <role> --assignment-file "$BB_THREAD_STORAGE/<name>.md".'

# Data that never runs is not scanned: the body of a quoted heredoc piped into role-picker (spawn/ask),
# and a quoted heredoc written to "$BB_THREAD_STORAGE/<name>.md|txt". Bash forms apply to the bash tool,
# PowerShell here-strings to the powershell tool. Headers and every other line are scanned; anything
# that does not parse exactly (or follows an unbalanced quote, paren, continuation or other heredoc) is scanned.
# Keep in step with the awk program in cantrip-agent-guard.sh.
function Get-GuardScanText([string]$text, [bool]$shForms, [bool]$psForms, [bool]$storeOk) {
    $args_ = '([ \t][^;&|<>$`()#''"\\]*)?$'
    $rp = 'bb[ \t]+plugin[ \t]+run[ \t]+role-picker[ \t]+(spawn|ask)' + $args_
    $e1sh = '^[ \t]*' + $rp
    $e3sh = '^[ \t]*cat[ \t]+>[ \t]*"\$BB_THREAD_STORAGE/[A-Za-z0-9_][A-Za-z0-9._-]*\.(md|txt)"[ \t]*$'
    $e1ps = '^\|[ \t]*' + $rp
    $e3ps = '^\|[ \t]*set-content[ \t]+-literalpath[ \t]+"\$env:bb_thread_storage\\[a-z0-9_][a-z0-9._-]*\.(md|txt)"([ \t]+-encoding[ \t]+utf8)?[ \t]*$'
    $out = New-Object System.Collections.Generic.List[string]
    $buf = New-Object System.Collections.Generic.List[string]
    $st = 0; $tag = ''; $bad = $false
    foreach ($line in (($text -replace "`r", '') -split "`n")) {
        if ($st -eq 1) {
            if ($line -ceq $tag) { $st = 0; $buf.Clear() } else { $buf.Add($line) }
            continue
        }
        if ($st -eq 2) {
            if (-not $line.StartsWith("'@")) { $buf.Add($line); continue }
            $st = 0
            $rest = $line.Substring(2).ToLowerInvariant() -replace '^[ \t]+', ''
            if ($rest -cmatch $e1ps) { $buf.Clear(); $out.Add($rest.Substring(1)); continue }
            if ($storeOk -and $rest -cmatch $e3ps) { $buf.Clear(); continue }
            $out.AddRange($buf); $buf.Clear(); $out.Add($line); $bad = $true; continue
        }
        if (-not $bad -and $psForms -and ($line -replace '^[ \t]+|[ \t]+$', '') -ceq "@'") {
            $buf.Clear(); $buf.Add($line); $st = 2; continue
        }
        if (-not $bad -and $shForms -and $line -cmatch '<<[ \t]*''([A-Za-z_][A-Za-z0-9_]*)''[ \t]*$') {
            $head = $line.Substring(0, $line.Length - $Matches[0].Length)
            $tag = $Matches[1]
            if ($head -cmatch $e1sh) { $out.Add($head); $buf.Clear(); $st = 1; continue }
            if ($storeOk -and $head -cmatch $e3sh -and $head -notmatch '\.\.') { $buf.Clear(); $buf.Add($line); $st = 1; continue }
        }
        $count = { param($pattern) ([regex]::Matches($line, $pattern)).Count }
        if ($line -match '<<|\\|`$' -or (& $count "'") % 2 -or (& $count '"') % 2 -or (& $count '`') % 2 -or (& $count '\(') -ne (& $count '\)')) { $bad = $true }
        $out.Add($line)
    }
    if ($st) { $out.AddRange($buf) }
    return ($out -join "`n")
}

function Deny([string]$reason) {
    @{ permissionDecision = 'deny'; permissionDecisionReason = $reason } | ConvertTo-Json -Compress
    exit 0
}

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
} catch {
    exit 0
}

$calls = @()
if ($payload.toolName) { $calls += [pscustomobject]@{ name = $payload.toolName; args = $payload.toolArgs } }
elseif ($payload.tool_name) { $calls += [pscustomobject]@{ name = $payload.tool_name; args = $payload.tool_input } }
if ($payload.toolCalls) { $calls += $payload.toolCalls }

$sessionId = if ($payload.sessionId) { [string]$payload.sessionId } else { [string]$payload.session_id }
$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }
# Only root sessions have a session-state directory; subagent calls carry their own agent id.
$isRoot = $sessionId -and (Test-Path -LiteralPath (Join-Path (Join-Path $copilotHome 'session-state') $sessionId))

foreach ($call in $calls) {
    $toolArgs = $call.args
    if ($toolArgs -is [string]) { try { $toolArgs = $toolArgs | ConvertFrom-Json } catch { } }

    if ($call.name -in @('task', 'Task', 'Agent')) {
        $agentType = if ($toolArgs -and $toolArgs.PSObject.Properties['agent_type']) { [string]$toolArgs.agent_type } else { '' }
        if ($agentType -notin $allowedAgents) {
            Deny "Forbidden agent_type '$agentType'. The orchestrator may only delegate to cantrip agents: $($allowedAgents -join ', '). Built-in and default agents are not allowed. Delegate to the matching cantrip role; run verification commands with your own shell tool."
        }
        continue
    }

    if (-not $isRoot) { continue }

    if ($call.name -in $readTools) {
        $stateDir = if ($env:CANTRIP_STATE_DIR) { $env:CANTRIP_STATE_DIR } else { Join-Path ([IO.Path]::GetTempPath()) 'cantrip-guard' }
        New-Item -ItemType Directory -Force $stateDir | Out-Null
        $counter = Join-Path $stateDir "$sessionId.reads"
        $reads = 0
        if (Test-Path -LiteralPath $counter) { [int]::TryParse((Get-Content -LiteralPath $counter -Raw).Trim(), [ref]$reads) | Out-Null }
        $reads++
        Set-Content -LiteralPath $counter -Value $reads -NoNewline
        if ($reads -gt $readBudget) {
            Deny "Read budget exhausted ($readBudget view/grep/glob calls this session). Reading code is the explorer's job: delegate the question to an explorer, or ask the worker to report the hunk you need. Use git diff --stat to see what changed."
        }
        continue
    }

    if ($call.name -in $editTools) {
        Deny "The orchestrator does not edit files. Delegate this change to a worker with a self-contained assignment (objective, files, governing ADRs, acceptance criteria)."
    }

    if ($call.name -in $shellTools) {
        $text = ''
        if ($toolArgs -is [string]) { $text = $toolArgs }
        elseif ($toolArgs) {
            foreach ($key in 'command', 'input') { if ($toolArgs.PSObject.Properties[$key]) { $text += "`n" + [string]$toolArgs.$key } }
        }
        $shForms = $call.name -cin @('bash', 'Bash')
        $psForms = $call.name -ceq 'powershell'
        try {
            $scan = Get-GuardScanText $text $shForms $psForms ([bool]$env:BB_THREAD_STORAGE)
        } catch {
            Deny 'The orchestrator could not parse this command, so it cannot tell that it is safe. Run it as a plain command.'
        }
        foreach ($pattern in $mutating) {
            if ($scan -match $pattern) {
                Deny "The orchestrator does not run commands that change the repository or environment (matched: '$($Matches[0].Trim())'). Delegate it to a worker. Your own shell use is limited to Archgate preflight and checks, read-only inspection (git status/diff/log/show), and verification in check mode. $assignmentHint"
            }
        }
        $left = $scan -replace '(?i)--assignment-file[ \t]+"\$\{?(env:)?BB_THREAD_STORAGE\}?[\\/][a-z0-9_$][a-z0-9._$-]*\.(md|txt)"', ''
        if ($left -match '(?i)BB_THREAD_STORAGE|thread-storage') {
            Deny "The orchestrator does not run commands that change the repository or environment (matched: 'BB_THREAD_STORAGE'). Thread storage may only be read, never redefined. $assignmentHint"
        }
    }
}
exit 0
