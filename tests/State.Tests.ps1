#Requires -Version 5.1
# Offline tests for the run journal and undo ownership rules.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'zc-state.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected error '$Pattern', got '$message'."
}

$pass = 0
$tmp = Join-Path $env:TEMP ('zcode-state-tests-' + [guid]::NewGuid().ToString('N'))

# --- journal round-trip ---
$state = Initialize-ZcLocalStateRoot -Path $tmp
$j = New-ZcJournal -Phase 'connect' -SiteName 'lab' -HostName $env:COMPUTERNAME -RunId 'connect-test-0001'
Save-ZcJournal -Root $state -Journal $j | Out-Null
Add-ZcChange -Root $state -Journal $j -Kind 'portproxy' -Data @{ ListenAddress = '0.0.0.0'; ListenPort = 13306; ConnectAddress = '10.0.0.201'; ConnectPort = 3306 } | Out-Null
$read = Read-ZcJournal -Path (Get-ZcJournalPath -Root $state -RunId 'connect-test-0001')
Assert-True ($read.RunId -eq 'connect-test-0001' -and $read.Phase -eq 'connect') 'Journal identity must round-trip.'
Assert-True (@($read.Changes).Count -eq 1 -and $read.Changes[0].Kind -eq 'portproxy') 'Journal change must round-trip.'
$found = @(Get-ZcJournals -Root $state -RunId 'connect-test-0001' -Phase @('connect'))
Assert-True ($found.Count -eq 1) 'Journal lookup by run id and phase must work.'
$none = @(Get-ZcJournals -Root $state -Phase @('site'))
Assert-True ($none.Count -eq 0) 'Phase filter must exclude other phases.'
$pass++

# --- ownership predicates ---
$change = [pscustomobject]@{ Data = [pscustomobject]@{ ListenAddress = '0.0.0.0'; ListenPort = 13306; ConnectAddress = '10.0.0.201'; ConnectPort = 3306 } }
$row = [pscustomobject]@{ Address = '0.0.0.0'; Listen = 13306; Connect = '10.0.0.201'; Port = 3306 }
$row2 = [pscustomobject]@{ Address = '0.0.0.0'; Listen = 13306; Connect = '10.0.0.202'; Port = 3306 }
Assert-True (Test-ZcProxyOwned $row $change) 'Exact proxy must be owned.'
Assert-True (-not (Test-ZcProxyOwned $row2 $change)) 'Changed proxy must not be owned.'
$rule = [pscustomobject]@{ Description = 'x ZCodeRemoteAccess:run-1 y' }
Assert-True (Test-ZcFirewallOwned $rule 'run-1') 'Marker must prove firewall ownership.'
Assert-True (-not (Test-ZcFirewallOwned $rule 'run-2')) 'Different run must not own a firewall rule.'
$pass++

# netsh-created rules have a GUID Name and the supplied text as DisplayName.
function Get-NetFirewallRule {
    [CmdletBinding()] param([string]$Name, [string]$DisplayName)
    if ($Name) { throw 'not found by Name' }
    if ($DisplayName) { return [pscustomobject]@{ Name = '{GUID-DISPLAY}'; DisplayName = $DisplayName; Description = 'ZCodeRemoteAccess:run-x'; Enabled = 'True' } }
}
$foundByDisplay = Get-ZcFirewallRule 'ZCode-Proxy-Display'
Assert-True ($foundByDisplay -and $foundByDisplay.Name -eq '{GUID-DISPLAY}') 'Firewall lookup must fall back to DisplayName.'
$pass++

# --- undo only removes exact, owned resources ---
$script:TestRunId = 'connect-test-undo'
$journal = [pscustomobject]@{
    Schema = 1; Tool = 'zcode-remote-access-kit'; RunId = $script:TestRunId; Phase = 'connect'
    HostName = $env:COMPUTERNAME; SiteName = 'lab'; CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o'); Status = 'Applied'; Snapshot = [pscustomobject]@{}
    Changes = @(
        [pscustomobject]@{ Kind = 'portproxy'; Data = [pscustomobject]@{ ListenAddress = '0.0.0.0'; ListenPort = 13306; ConnectAddress = '10.0.0.201'; ConnectPort = 3306 } },
        [pscustomobject]@{ Kind = 'portproxy'; Data = [pscustomobject]@{ ListenAddress = '0.0.0.0'; ListenPort = 13307; ConnectAddress = '10.0.0.203'; ConnectPort = 3306 } },
        [pscustomobject]@{ Kind = 'firewall.rule'; Data = [pscustomobject]@{ Name = 'ZCode-Proxy-13306-good' } },
        [pscustomobject]@{ Kind = 'firewall.rule'; Data = [pscustomobject]@{ Name = 'ZCode-Proxy-13307-bad' } }
    )
    UndoResults = @()
}
Save-ZcJournal -Root $state -Journal $journal | Out-Null

function Get-ZcProxyRows {
    return @(
        [pscustomobject]@{ Address = '0.0.0.0'; Listen = 13306; Connect = '10.0.0.201'; Port = 3306 },
        [pscustomobject]@{ Address = '0.0.0.0'; Listen = 13307; Connect = '10.0.0.202'; Port = 3306 }
    )
}
function Get-ZcFirewallRule([string]$Name) {
    if ($Name -like '*bad*') { return [pscustomobject]@{ Name = $Name; Description = 'other'; Enabled = 'True' } }
    return [pscustomobject]@{ Name = $Name; Description = ('ZCodeRemoteAccess:' + $script:TestRunId); Enabled = 'True' }
}
$script:RemovedRules = New-Object System.Collections.ArrayList
function Remove-NetFirewallRule {
    [CmdletBinding()] param([string]$Name)
    [void]$script:RemovedRules.Add($Name)
}
$script:NativeCalls = New-Object System.Collections.ArrayList
function Invoke-ZcNative {
    param([string]$FilePath, [string[]]$Arguments)
    [void]$script:NativeCalls.Add($FilePath + ' ' + ($Arguments -join ' '))
    return [pscustomobject]@{ Output = ''; ExitCode = 0 }
}

$dry = Invoke-ZcUndoJournal -Root $state -Journal $journal -DryRun
$statuses = @($dry.Results | ForEach-Object { $_.Kind + ':' + $_.Status })
Assert-True (@($dry.Results | Where-Object { $_.Kind -eq 'portproxy' -and $_.Status -eq 'Planned' }).Count -eq 1) 'Exact proxy must be planned for removal.'
Assert-True (@($dry.Results | Where-Object { $_.Kind -eq 'portproxy' -and $_.Status -eq 'Error' }).Count -eq 1) 'Changed proxy must block removal.'
Assert-True (@($dry.Results | Where-Object { $_.Kind -eq 'firewall.rule' -and $_.Status -eq 'Planned' }).Count -eq 1) 'Owned firewall must be planned for removal.'
Assert-True (@($dry.Results | Where-Object { $_.Kind -eq 'firewall.rule' -and $_.Status -eq 'Error' }).Count -eq 1) 'Unmarked firewall must not be removed.'
Assert-True ($script:RemovedRules.Count -eq 0) 'Dry run must not delete anything.'
$pass += 4

$actual = Invoke-ZcUndoJournal -Root $state -Journal $journal
Assert-True (@($actual.Results | Where-Object { $_.Kind -eq 'portproxy' -and $_.Status -eq 'Removed' }).Count -eq 1) 'Exact proxy must be removed.'
Assert-True (@($actual.Results | Where-Object { $_.Kind -eq 'portproxy' -and $_.Status -eq 'Error' }).Count -eq 1) 'Changed proxy must remain and report an error.'
Assert-True ($script:RemovedRules.Count -eq 1 -and $script:RemovedRules[0] -eq 'ZCode-Proxy-13306-good') 'Only the owned firewall may be deleted.'
Assert-True (@($script:NativeCalls | Where-Object { $_ -match 'listenport=13306' }).Count -eq 1) 'Exact proxy deletion must be attempted.'
Assert-True (@($script:NativeCalls | Where-Object { $_ -match 'listenport=13307' }).Count -eq 0) 'Changed proxy must not be deleted.'
$saved = Read-ZcJournal -Path (Get-ZcJournalPath -Root $state -RunId $script:TestRunId)
Assert-True ($saved.Status -eq 'UndoPartial') 'Partial undo must be recorded as UndoPartial.'
$pass += 5

$historyCount = @($saved.UndoResults).Count
$again = Invoke-ZcUndoJournal -Root $state -Journal $saved
Assert-True ($script:RemovedRules.Count -eq 1 -and @($script:NativeCalls | Where-Object { $_ -match 'listenport=13306' }).Count -eq 1) 'Retry must not replay resources already removed by this run.'
Assert-True (@($saved.UndoResults).Count -gt $historyCount -and @($saved.Changes).Count -eq 4) 'Retry must append undo history while retaining all ownership records.'
$pass += 2

# --- tailscale logout must precede uninstall ---
$tsJournal = [pscustomobject]@{
    Schema = 1; Tool = 'zcode-remote-access-kit'; RunId = 'site-ts-order'; Phase = 'site'
    HostName = $env:COMPUTERNAME; SiteName = 'lab'; CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o'); Status = 'Applied'; Snapshot = [pscustomobject]@{}
    Changes = @(
        [pscustomobject]@{ Kind = 'tailscale.install'; Data = [pscustomobject]@{ InstalledBefore = $false; ProductCode = '{TEST}' } },
        [pscustomobject]@{ Kind = 'tailscale.join'; Data = [pscustomobject]@{ JoinedByTool = $true; NodeName = 'test'; NodeIp = '100.64.0.1' } }
    )
    UndoResults = @()
}
$tsPlan = Invoke-ZcUndoJournal -Root $state -Journal $tsJournal -DryRun -RemoveTailscale -UnjoinTailscale
$tsKinds = @($tsPlan.Results | ForEach-Object { [string]$_.Kind })
Assert-True ($tsKinds.IndexOf('tailscale.join') -lt $tsKinds.IndexOf('tailscale.install')) 'Tailscale logout must be planned before uninstall.'
$pass++

# --- registry.tailscale-env restore (mocked registry; never touches the real service) ---
$script:Reg = @{ 'HKLM:\TEST\Tailscale' = @{ Environment = @('GODEBUG=tlsmlkem=0') } }
function Get-ZcRegState {
    param([string]$Path, [string]$Name)
    if ($script:Reg.ContainsKey($Path) -and $script:Reg[$Path].ContainsKey($Name)) {
        return [pscustomobject]@{ Exists = $true; Value = $script:Reg[$Path][$Name] }
    }
    return [pscustomobject]@{ Exists = $false; Value = $null }
}
function Set-ZcRegState {
    param([string]$Path, [string]$Name, $Value, [bool]$Exists)
    if ($Exists) {
        if (-not $script:Reg.ContainsKey($Path)) { $script:Reg[$Path] = @{} }
        $script:Reg[$Path][$Name] = $Value
    } else {
        if ($script:Reg.ContainsKey($Path)) { $script:Reg[$Path].Remove($Name) }
    }
}
$envJournal = [pscustomobject]@{
    Schema = 1; Tool = 'zcode-remote-access-kit'; RunId = 'site-env-test'; Phase = 'site'
    HostName = $env:COMPUTERNAME; SiteName = 'lab'; CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o'); Status = 'Applied'; Snapshot = [pscustomobject]@{}
    Changes = @(
        [pscustomobject]@{ Kind = 'registry.tailscale-env'; Data = [pscustomobject]@{ Path = 'HKLM:\TEST\Tailscale'; Name = 'Environment'; ExistedBefore = $false; ValueBefore = @(); ValueSet = @('GODEBUG=tlsmlkem=0') } }
    )
    UndoResults = @()
}
$envDry = Invoke-ZcUndoJournal -Root $state -Journal $envJournal -DryRun
Assert-True (@($envDry.Results | Where-Object { $_.Kind -eq 'registry.tailscale-env' -and $_.Status -eq 'Planned' }).Count -eq 1) 'GODEBUG env change must be planned for restore.'
$envActual = Invoke-ZcUndoJournal -Root $state -Journal $envJournal
Assert-True (@($envActual.Results | Where-Object { $_.Kind -eq 'registry.tailscale-env' -and $_.Status -eq 'Restored' }).Count -eq 1) 'GODEBUG env change must be restored.'
Assert-True (-not $script:Reg['HKLM:\TEST\Tailscale'].ContainsKey('Environment')) 'Environment must be removed when it did not exist before.'
$pass += 3

# --- 02 connect journal (remote body with mocks) ---
$s02path = Join-Path $root '02-connect-site.ps1'
$tokens = $null; $parseErrors = $null
$ast02 = [Management.Automation.Language.Parser]::ParseFile($s02path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
foreach ($name in @('Assert-ForwardMappings', 'Get-ForwardingScriptBlock')) {
    $def = @($ast02.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($def.Count -ne 1) { throw "Expected one function: $name" }
    . ([scriptblock]::Create($def[0].Extent.Text))
}
$body02 = Get-ForwardingScriptBlock
$script:Rows02 = @()
function netsh.exe {
    [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NativeArguments)
    $global:LASTEXITCODE = 0
    $flat = $NativeArguments -join ' '
    $values = @{}
    foreach ($arg in $NativeArguments) { if ($arg -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
    if ($flat -eq 'interface portproxy show v4tov4') {
        foreach ($row in $script:Rows02) { '{0} {1} {2} {3}' -f $row.Address, $row.Listen, $row.Connect, $row.Port }
        return
    }
    if ($flat -like 'advfirewall firewall show rule *') { return "Rule Name: $($values.name)" }
    if ($flat -like 'interface portproxy add v4tov4 *') {
        $script:Rows02 += [pscustomobject]@{ Address = $values.listenaddress; Listen = [int]$values.listenport; Connect = $values.connectaddress; Port = [int]$values.connectport }
        return 'Ok.'
    }
    return 'Ok.'
}
function Get-NetTCPConnection { [CmdletBinding()] param([string]$State) return @() }
# The test process uses a filtered admin token; mock the ACL command so the
# journal writer remains testable without locking the test account out.
function icacls.exe { $global:LASTEXITCODE = 0; return 'mocked' }
$tmp02 = Join-Path $env:TEMP ('zcode-connect-journal-' + [guid]::NewGuid().ToString('N'))
$mapping = [pscustomobject]@{ Listen = 13306; Connect = '10.0.0.201'; Port = 3306; Label = 'MySQL' }
$json02 = ConvertTo-Json -InputObject @($mapping) -Compress
$validation02 = ${function:Assert-ForwardMappings}.ToString()
$result02 = @(& $body02 $json02 $false $validation02 'connect-journal-test' 'lab' $tmp02 $true)
$journalPath = Join-Path $tmp02 'runs\connect-journal-test.json'
Assert-True (Test-Path -LiteralPath $journalPath) '02 must write the connect journal.'
$j02 = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($j02.Phase -eq 'connect' -and $j02.Status -eq 'Applied' -and $j02.HostName -eq $env:COMPUTERNAME) 'Connect journal metadata must be correct.'
Assert-True (@($j02.Changes).Count -eq 2) 'Connect journal must contain proxy and firewall changes.'
Assert-True ($j02.Changes[0].Kind -eq 'portproxy' -and [int]$j02.Changes[0].Data.ListenPort -eq 13306) 'Connect journal must record the proxy tuple.'
Assert-True ($j02.Changes[1].Kind -eq 'firewall.rule' -and $j02.Changes[1].Data.Description -match 'ZCodeRemoteAccess:connect-journal-test') 'Connect journal must record the firewall marker.'
Assert-True ($result02[0].Status -eq 'created') 'Connect engine must still report the created mapping.'
$pass += 5
icacls.exe $tmp02 /reset 2>$null | Out-Null
Remove-Item -LiteralPath $tmp02 -Recurse -Force -ErrorAction SilentlyContinue

# --- source guards ---
function Read-Source([string]$Name) { return Get-Content -LiteralPath (Join-Path $root $Name) -Raw }
$s01 = Read-Source '01-jump-setup.ps1'
$s02 = Read-Source '02-connect-site.ps1'
$s03 = Read-Source '03-undo.ps1'
$sState = Read-Source 'zc-state.ps1'
foreach ($pair in @(@('01', '01-jump-setup.ps1'), @('02', '02-connect-site.ps1'), @('03', '03-undo.ps1'), @('state', 'zc-state.ps1'))) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $root $pair[1]))
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
    Assert-True ($nonAscii -eq 0) ("{0} must remain ASCII for PS 5.1." -f $pair[0])
}
Assert-True ($s01 -match 'New-LocalUser') '01 must create the ops account without net user.'
Assert-True ($s01 -match 'TS_AUTHKEY') '01 must pass the auth key through the environment first.'
Assert-True ($s01 -match 'Get-AuthenticodeSignature') '01 must verify the installer signature.'
Assert-True ($s01 -match 'Invoke-TsWithEnvKey') '01 must try the environment auth key before any fallback.'
Assert-True ($s01 -match 'auth key is visible to local administrators') '01 must warn when using the --authkey fallback.'
Assert-True ($s01 -match 'Invoke-ZcUndoJournal') '01 must support failure rollback through the journal.'
Assert-True ($s01 -notmatch 'net user \$User \$Password') '01 must not put the password on a command line.'
Assert-True ($s01 -notmatch 'ZCodeTailscaleOnce') '01 must not use the old fixed task name.'
Assert-True ($s01 -notmatch 'zcode-ts-system') '01 must not use old fixed TEMP files.'
Assert-True ($s02 -match 'description=' -and $s02 -match 'ZCodeRemoteAccess') '02 must mark created firewall rules with the run id.'
Assert-True ($s02 -match 'Add-ConnectChange') '02 must journal created forwarding rules.'
Assert-True ($s03 -match 'UNDO' -and $s03 -match 'DryRun') '03 must default to a reviewed undo.'
Assert-True ($s01 -match 'WinRmBroadRulesRemaining') '01 must report pre-existing broad WinRM rules honestly.'
Assert-True (-not $s01.Contains('Join-Path $env:TEMP ''tailscale-setup-latest.exe''')) '01 must not use a fixed TEMP installer path.'
$pass += 14

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "PASS: $pass offline state/undo checks (PowerShell $($PSVersionTable.PSVersion)); no native or remote access executed."
