#Requires -Version 5.1
# Offline tests for 01-jump-setup.ps1: Join-Tailnet auth-key retry/fallback and
# the install result verdict. Extracts only those functions and mocks every
# dependency; no native/remote access.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) '01-jump-setup.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw ($parseErrors | Out-String) }
$bytes = [IO.File]::ReadAllBytes($source)
if (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) { throw '01-jump-setup.ps1 must remain ASCII for PS 5.1.' }

foreach ($name in @('Join-Tailnet', 'Test-ZcTailscaleInstall')) {
    $def = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (@($def).Count -ne 1) { throw "Expected exactly one $name function." }
    . ([scriptblock]::Create($def[0].Extent.Text))
}

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT: $Message" } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $msg = ''
    try { & $Action | Out-Null } catch { $msg = $_.Exception.Message }
    if (-not ($msg -match $Pattern)) { throw "Expected error '$Pattern', got '$msg'." }
}

# --- mocks (override every dependency of the extracted functions) ---
$script:calls = New-Object System.Collections.ArrayList
$script:queue = New-Object System.Collections.Queue
$script:health = $null
function Write-Step([string]$m) { [void]$script:calls.Add("step:$m") }
function Write-Warn2([string]$m) { [void]$script:calls.Add("warn:$m") }
function Write-Ok([string]$m) { [void]$script:calls.Add("ok:$m") }
function Add-SiteChange([string]$kind, $data) { [void]$script:calls.Add("change:$kind|joined=$($data.JoinedByTool)|node=$($data.NodeName)") }
function Get-TailscaleIp { return '100.64.0.99' }
function Get-TailscaleHealth { return $script:health }
function Stop-TailscaleIpn { [void]$script:calls.Add('stopipn') }
function Enable-TailscaleTlsMlkemWorkaround { [void]$script:calls.Add('workaround') }
function Invoke-TailscaleAsSystem { param([string[]]$TailArgs, [int]$TimeoutSec, [string]$AuthKey) [void]$script:calls.Add('system'); return [pscustomobject]@{ Text = ''; ExitCode = 0 } }
function Invoke-TsWithEnvKey { param([string[]]$TailArgs, [string]$Key, [int]$TimeoutSec) [void]$script:calls.Add('envkey'); return $script:queue.Dequeue() }
function Invoke-Ts { param([string[]]$TailArgs, [int]$TimeoutSec) [void]$script:calls.Add('ts:' + ($TailArgs -join ' ')); return $script:queue.Dequeue() }
$script:Journal = @{ Snapshot = @{ Tailscale = @{ BackendState = 'Stopped' } } }

function Reset-Test { $script:calls.Clear(); $script:queue.Clear(); $script:health = $null }
function Add-Resp([string]$text, [int]$code) { $script:queue.Enqueue([pscustomobject]@{ Text = $text; ExitCode = $code }) }
function Count-Calls([string]$like) { return @($script:calls | Where-Object { $_ -like $like }).Count }

$interactive = "`nTo authenticate, visit:`n`n`thttps://login.tailscale.com/a/abc123`n`nEOF`n"
$pass = 0

# 1. Interactive fallback (env key ignored) -> stop IPN, retry env, then --authkey -> success
Reset-Test
Add-Resp $interactive 1
Add-Resp $interactive 1
Add-Resp '' 0
Join-Tailnet -Key 'tskey-auth-test' -Routes @()
Assert-True ((Count-Calls 'envkey') -eq 2) 'Expected two env-key attempts before --authkey.'
Assert-True ((Count-Calls 'stopipn') -eq 2) 'Expected the IPN to be stopped twice.'
Assert-True ((Count-Calls 'ts:*--authkey*') -eq 1) 'Interactive fallback must trigger the --authkey path.'
Assert-True (@($script:calls) -contains 'ok:tailnet joined.') 'Expected join success after --authkey.'
Assert-True ((Count-Calls 'change:tailscale.join*') -eq 1) 'Expected a tailscale.join journal entry.'
$pass++

# 2. Non-retryable failure -> no --authkey, throw
Reset-Test
Add-Resp 'invalid auth key: malformed' 1
Assert-Throws { Join-Tailnet -Key 'tskey-auth-test' -Routes @() } 'tailscale up failed'
Assert-True ((Count-Calls 'ts:*--authkey*') -eq 0) 'A non-retryable failure must not attempt --authkey.'
Assert-True ((Count-Calls 'envkey') -eq 1) 'A non-retryable failure must stop after one env-key attempt.'
$pass++

# 3. Immediate success -> single attempt, no IPN stop
Reset-Test
Add-Resp '' 0
Join-Tailnet -Key 'tskey-auth-test' -Routes @()
Assert-True ((Count-Calls 'envkey') -eq 1) 'Immediate success must not retry.'
Assert-True ((Count-Calls 'stopipn') -eq 0) 'Immediate success must not stop the IPN.'
Assert-True (@($script:calls) -contains 'ok:tailnet joined.') 'Expected success.'
$pass++

# 4. IPC-held (already in use) still recovers via stop-IPN + env retry
Reset-Test
Add-Resp 'Tailscale is already in use by another user' 1
Add-Resp '' 0
Join-Tailnet -Key 'tskey-auth-test' -Routes @()
Assert-True ((Count-Calls 'stopipn') -eq 1) 'IPC-held case must stop the IPN once.'
Assert-True ((Count-Calls 'envkey') -eq 2) 'IPC-held case must retry the env key first.'
Assert-True (@($script:calls) -contains 'ok:tailnet joined.') 'Expected success.'
$pass++

# 5. Control-plane TLS reset -> apply ML-KEM workaround, retry --authkey -> success
Reset-Test
Add-Resp 'TIMEOUT' 1
Add-Resp 'TIMEOUT' 1
Add-Resp 'TIMEOUT' 1
$script:health = [pscustomobject]@{
    BackendState = 'NeedsLogin'
    Health = 'Unable to connect to the Tailscale coordination server; fetch control key: read tcp: wsarecv'
    ControlPlaneTlsReset = $true
}
Add-Resp '' 0
Join-Tailnet -Key 'tskey-auth-test' -Routes @()
Assert-True ((Count-Calls 'workaround') -eq 1) 'TLS reset must apply the ML-KEM workaround exactly once.'
Assert-True ((Count-Calls 'ts:*--authkey*') -eq 2) 'TLS reset must retry with --authkey after the workaround.'
Assert-True (@($script:calls) -contains 'ok:tailnet joined.') 'Expected join success after the workaround.'
$pass++

# 6. No TLS-reset health -> no workaround
Reset-Test
Add-Resp 'invalid auth key: malformed' 1
$script:health = [pscustomobject]@{ BackendState = 'NeedsLogin'; Health = 'logged out'; ControlPlaneTlsReset = $false }
Assert-Throws { Join-Tailnet -Key 'tskey-auth-test' -Routes @() } 'tailscale up failed'
Assert-True ((Count-Calls 'workaround') -eq 0) 'A non-TLS failure must not apply the workaround.'
$pass++

# 7-11. Install verdict: a null/blank exit code must not fail a real install
Assert-True ((Test-ZcTailscaleInstall -ExitCode $null -Installed $true -LogOk $false).Ok) 'Null exit code + product present must pass.'
Assert-True ((Test-ZcTailscaleInstall -ExitCode 0 -Installed $true -LogOk $false).Ok) 'Exit 0 must pass.'
Assert-True ((Test-ZcTailscaleInstall -ExitCode 3010 -Installed $true -LogOk $false).Ok) 'Exit 3010 (reboot required) must pass.'
Assert-True ((Test-ZcTailscaleInstall -ExitCode 1603 -Installed $true -LogOk $true).Ok) 'Nonzero exit with MSI log success must pass.'
Assert-True (-not (Test-ZcTailscaleInstall -ExitCode 1603 -Installed $true -LogOk $false).Ok) 'Nonzero exit without log success must fail.'
Assert-True (-not (Test-ZcTailscaleInstall -ExitCode 0 -Installed $false -LogOk $false).Ok) 'Missing product must fail.'
$pass += 6

Write-Host "PASS: $pass offline 01 checks (Join-Tailnet retry + install verdict, PowerShell $($PSVersionTable.PSVersion)); no native or remote access executed."
