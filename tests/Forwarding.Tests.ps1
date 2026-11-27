#Requires -Version 5.1
# Offline tests only: parse source, load named function definitions, mock all I/O.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) '02-connect-site.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$names = @('Assert-ForwardMappings', 'New-ForwardMappings', 'Get-ForwardingScriptBlock', 'Set-RemoteForwards', 'Assert-ChannelVerification')
foreach ($name in $names) {
    $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (@($definition).Count -ne 1) { throw "Expected one function: $name" }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$bytes = [IO.File]::ReadAllBytes($source)
if (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) { throw 'Engine must remain ASCII for PS 5.1.' }
$body = Get-ForwardingScriptBlock
if ($body.ToString() -match 'Restart-Service|Win32_Process|Register-ScheduledTask') { throw 'Forbidden service/task operation in remote body.' }

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected error '$Pattern', got '$message'."
}
function New-Mapping([int]$Listen = 13306, [string]$Connect = '10.0.0.201', [int]$Port = 3306) {
    return [pscustomobject]@{ Listen = $Listen; Connect = $Connect; Port = $Port; Label = 'test' }
}
function New-Row([int]$Listen = 13306, [string]$Address = '0.0.0.0', [string]$Connect = '10.0.0.201', [int]$Port = 3306) {
    return [pscustomobject]@{ Listen = $Listen; Address = $Address; Connect = $Connect; Port = $Port }
}
function Reset-Fakes([object[]]$Rows = @(), [object[]]$Listeners = @()) {
    $script:Rows = @($Rows)
    $script:Listeners = @($Listeners)
    $script:Writes = New-Object System.Collections.ArrayList
    $script:Reads = 0
    $script:Firewalls = @{}
    $script:FailOn = ''
    $script:BadReadback = $false
}
function Get-NetTCPConnection {
    [CmdletBinding()] param([string]$State)
    return $script:Listeners
}
function Invoke-Command { throw 'NETWORK ACCESS IS FORBIDDEN IN THESE TESTS.' }
function netsh.exe {
    [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NativeArguments)
    $global:LASTEXITCODE = 0
    $flat = $NativeArguments -join ' '
    $values = @{}
    foreach ($arg in $NativeArguments) {
        if ($arg -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    if ($flat -eq 'interface portproxy show v4tov4') {
        $script:Reads++
        foreach ($row in $script:Rows) { '{0} {1} {2} {3}' -f $row.Address, $row.Listen, $row.Connect, $row.Port }
        return
    }
    if ($flat -like 'advfirewall firewall show rule *') {
        $script:Reads++
        if ($script:Firewalls.ContainsKey($values.name)) { return "Rule Name: $($values.name)" }
        $global:LASTEXITCODE = 1
        return 'Rule not found.'
    }
    [void]$script:Writes.Add($flat)
    if ($flat -like 'interface portproxy add v4tov4 *') {
        $target = $values.connectaddress
        if ($script:BadReadback) { $target = '10.0.0.254' }
        $script:Rows += New-Row -Listen ([int]$values.listenport) -Address $values.listenaddress -Connect $target -Port ([int]$values.connectport)
    } elseif ($flat -like 'interface portproxy delete v4tov4 *') {
        $script:Rows = @($script:Rows | Where-Object { -not ($_.Listen -eq [int]$values.listenport -and $_.Address -eq $values.listenaddress) })
    } elseif ($flat -like 'advfirewall firewall add rule *') {
        $script:Firewalls[$values.name] = $true
    } elseif ($flat -like 'advfirewall firewall delete rule *') {
        $script:Firewalls.Remove($values.name)
    } else { throw "UNMOCKED COMMAND: $flat" }
    if ($script:FailOn -and $flat -match $script:FailOn) {
        $global:LASTEXITCODE = 9
        return 'Simulated native failure.'
    }
    return 'Ok.'
}
function Invoke-Offline([object[]]$Mappings, [bool]$ReadOnly = $false) {
    $json = ConvertTo-Json -InputObject @($Mappings) -Compress
    & $body $json $ReadOnly ${function:Assert-ForwardMappings}.ToString()
}

$pass = 0
$listener = [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 13306 }
Reset-Fakes -Rows @((New-Row)) -Listeners @($listener)
$result = @(Invoke-Offline @((New-Mapping)))
Assert-True ($result[0].Status -eq 'unchanged' -and $script:Writes.Count -eq 0) 'Same rule must never write firewall/portproxy.'
$pass++

Reset-Fakes -Rows @((New-Row -Address '*')) -Listeners @($listener)
$result = @(Invoke-Offline @((New-Mapping)) $true)
Assert-True ($result[0].Status -eq 'unchanged' -and $script:Writes.Count -eq 0) 'Wildcard display must normalize to unchanged.'
$pass++

Reset-Fakes -Rows @((New-Row -Connect '10.0.0.200'))
Assert-Throws { Invoke-Offline @((New-Mapping)) } 'CONFLICT'
Assert-True ($script:Writes.Count -eq 0) 'Different target must not write.'
$pass++

Reset-Fakes -Rows @((New-Row -Address '127.0.0.1'))
Assert-Throws { Invoke-Offline @((New-Mapping)) } 'CONFLICT'
Assert-True ($script:Writes.Count -eq 0) 'Different listen address must not write.'
$pass++

Reset-Fakes -Rows @((New-Row -Connect '10.0.0.200'))
Assert-Throws { Invoke-Offline @((New-Mapping -Listen 23389), (New-Mapping)) } 'CONFLICT'
Assert-True ($script:Writes.Count -eq 0) 'Whole batch must preflight before first write.'
$pass++

foreach ($mapping in @((New-Mapping -Connect '999.1.1.1'), (New-Mapping -Connect '10.0.0.01'), (New-Mapping -Listen 0), (New-Mapping -Listen 65536), (New-Mapping -Port 65536))) {
    Reset-Fakes
    Assert-Throws { Invoke-Offline @($mapping) } 'IPv4|1\.\.65535'
    Assert-True ($script:Writes.Count -eq 0 -and $script:Reads -eq 0) 'Invalid input must fail before native commands.'
    $pass++
}
Reset-Fakes
Assert-Throws { Invoke-Offline @((New-Mapping), (New-Mapping)) } 'Duplicate'
Assert-True ($script:Writes.Count -eq 0 -and $script:Reads -eq 0) 'Duplicate listen must fail before native commands.'
$pass++

Reset-Fakes -Listeners @($listener)
Assert-Throws { Invoke-Offline @((New-Mapping)) } 'CONFLICT'
Assert-True ($script:Writes.Count -eq 0) 'Non-portproxy listener must not be overridden.'
$pass++

Reset-Fakes
Assert-Throws { Invoke-Offline @((New-Mapping)) $true } 'MISSING'
Assert-True ($script:Writes.Count -eq 0) 'VerifyOnly must not create missing rules.'
$pass++

Reset-Fakes -Rows @((New-Row))
Assert-Throws { Invoke-Offline @((New-Mapping)) $true } 'CLOSED'
Assert-True ($script:Writes.Count -eq 0) 'VerifyOnly must not repair a stopped listener.'
$pass++

Reset-Fakes
$result = @(Invoke-Offline @((New-Mapping)))
Assert-True ($result[0].Status -eq 'created' -and $script:Writes.Count -eq 2 -and $script:Reads -ge 4) 'New mappings require checked creation and readback.'
Assert-True ($script:Writes[0] -match 'connectaddress=10\.0\.0\.201 connectport=3306') 'Native arguments must contain property values, not member-access literals.'
$pass++

Reset-Fakes -Rows @((New-Row)) -Listeners @($listener)
$script:FailOn = '^advfirewall firewall add'
Assert-Throws { Invoke-Offline @((New-Mapping), (New-Mapping -Listen 23389 -Connect '10.0.0.200' -Port 3389)) } 'netsh failed \(exit 9\)'
Assert-True ($script:Rows.Count -eq 1 -and $script:Rows[0].Listen -eq 13306) 'Rollback must preserve every original proxy.'
Assert-True ($script:Firewalls.Count -eq 0) 'Rollback must remove only this invocation firewall.'
Assert-True (@($script:Writes | Where-Object { $_ -match 'delete v4tov4.*listenport=13306' }).Count -eq 0) 'Rollback must never delete an unchanged proxy.'
$pass++

Reset-Fakes -Rows @((New-Row)) -Listeners @($listener)
$script:FailOn = '^advfirewall firewall add.*localport=23390'
Assert-Throws { Invoke-Offline @((New-Mapping), (New-Mapping -Listen 23389), (New-Mapping -Listen 23390)) } 'netsh failed \(exit 9\)'
Assert-True ($script:Rows.Count -eq 1 -and $script:Rows[0].Listen -eq 13306 -and $script:Firewalls.Count -eq 0) 'A later failure must roll back the entire new batch, preserving originals.'
$pass++

Reset-Fakes -Rows @((New-Row -Connect '@{Listen=13306; Connect=10.0.0.201}.Connect'))
Assert-Throws { Invoke-Offline @((New-Mapping)) } 'CONFLICT'
Assert-True ($script:Writes.Count -eq 0) 'Previously corrupted target text must never be treated as an absent rule.'
$pass++

Reset-Fakes -Rows @((New-Row)) -Listeners @($listener)
$script:FailOn = '^interface portproxy add'
Assert-Throws { Invoke-Offline @((New-Mapping), (New-Mapping -Listen 23389 -Connect '10.0.0.200' -Port 3389)) } 'netsh failed \(exit 9\)'
Assert-True ($script:Rows.Count -eq 1 -and $script:Rows[0].Listen -eq 13306) 'Partially created proxy must roll back without touching original.'
$pass++

Assert-Throws { Assert-ChannelVerification -Failures @('CLOSED 13306') } 'Verification failed: CLOSED'
Assert-Throws { Assert-ChannelVerification -Failures @('Web probe failed: HTTP 500') } 'Verification failed: Web'
Assert-ChannelVerification -Failures @()
$pass += 3

Reset-Fakes
# Read failures are also checked by the wrapper (dedicated mock override).
function netsh.exe { $global:LASTEXITCODE = 7; 'Simulated read failure.' }
Assert-Throws { Invoke-Offline @((New-Mapping)) } 'netsh failed \(exit 7\)'
Assert-True ($script:Writes.Count -eq 0) 'Failed show must fail closed.'
$pass++

Assert-Throws { Set-RemoteForwards -Mappings @((New-Mapping)) -ForceIt $true -EnsureOnBootIt $false } 'disabled'
Assert-Throws { Set-RemoteForwards -Mappings @((New-Mapping)) -ForceIt $false -EnsureOnBootIt $true } 'disabled'
$pass += 2
Assert-Throws { New-ForwardMappings -TargetAddress '10.0.0.201' -Extra @('13306:10.0.0.200:3389') -Db 13306 -Web 18080 -Rdp 13389 } 'Duplicate'
$pass++
Write-Host "PASS: $pass offline forwarding checks (PowerShell $($PSVersionTable.PSVersion)); no main, native executable, or remote connection executed."
