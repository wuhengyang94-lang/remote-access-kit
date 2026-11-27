#Requires -Version 5.1
<#
.SYNOPSIS
    Local one-stop wizard: hook THIS PC up to a project site through a jump host.

.DESCRIPTION
    Run on YOUR machine after 01-jump-setup.ps1 has been run once on the
    on-site jump machine. Identical mappings are unchanged; conflicts are refused.

    Steps:
      1. Ensure local Tailscale is installed and connected.
      2. Ensure the local WinRM client service and TrustedHosts.
      3. Verify WinRM to the jump host (falls back to Negotiate).
      4. Discover candidate servers (RDP history / ARP) when -Target is missing.
      5. Create missing, non-conflicting portproxy/firewall rules only.
         Existing rules are never refreshed. Force/startup tasks are disabled.
      6. Verify every channel from this machine.
      7. Print a site profile; save it with -ProfilePath.

.NOTES
    ASCII-only source on purpose: Windows PowerShell 5.1 misreads UTF-8 .ps1
    files without BOM.

.PARAMETER JumpHost
    Tailscale IPv4 (or MagicDNS name) of the jump host, e.g. 100.64.0.10

.PARAMETER Forward
    Extra mapping "listen:host:port", e.g. 23389:10.0.0.20:3389

.PARAMETER VerifyOnly
    Requires Target. Makes no local setup/profile changes and only reads remote
    portproxy/listeners. Existing Tailscale, WinRM and trust must already work.

.EXAMPLE
    .\02-connect-site.ps1 -JumpHost 100.64.0.10 -Target 10.0.0.10 -SiteName demo

.EXAMPLE
    .\02-connect-site.ps1 -JumpHost 100.64.0.10 -Forward 23389:10.0.0.20:3389
#>
[CmdletBinding()]
param(
    [string]$JumpHost,
    [string]$JumpUser = 'zcode_ops',
    [string]$JumpPassword,
    [string]$Target,
    [string[]]$Forward = @(),
    [int]$DbPort  = 13306,
    [int]$WebPort = 18080,
    [int]$RdpPort = 13389,
    [switch]$Discover,
    [switch]$Force,
    [switch]$EnsureOnBoot,
    [switch]$NoVerify,
    [switch]$VerifyOnly,
    [switch]$DirectOnly,
    [switch]$SkipSignatureCheck,
    [string]$SiteName,
    [string]$ProfilePath
)

$ErrorActionPreference = 'Stop'
# Native commands emit UTF-8; a fresh console defaults to the ANSI codepage
# (GBK here), which can swallow quote bytes inside UTF-8 text and corrupt
# captured JSON (e.g. tailscale status --json). Force UTF-8 output decoding.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$script:TsExe          = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$script:TailscaleCidr  = '100.64.0.0/10'

$stateLib = Join-Path $PSScriptRoot 'zc-state.ps1'
if (-not (Test-Path -LiteralPath $stateLib)) {
    throw 'Kit incomplete: zc-state.ps1 is missing next to 02-connect-site.ps1.'
}
. $stateLib
. (Join-Path $PSScriptRoot 'zc-process.ps1')

function Assert-LocalInstallerTrusted([string]$Path) {
    if ($SkipSignatureCheck) {
        Write-Warn2 "installer signature check skipped: $Path"
        return
    }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch 'Tailscale') {
        throw "Untrusted Tailscale installer: $Path ($($sig.Status))"
    }
}

function Write-Step([string]$Text) { Write-Host "[step] $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "[ ok ] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "[warn] $Text" -ForegroundColor Yellow }

function Test-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PlainPassword([string]$Given, [string]$Prompt) {
    if (-not [string]::IsNullOrWhiteSpace($Given)) { return $Given }
    $secure = Read-Host -AsSecureString $Prompt
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Ensure-LocalTailscale {
    if (Test-Path $script:TsExe) { Write-Ok 'Tailscale present.'; return }
    Write-Step 'installing Tailscale locally (accept the UAC prompt)...'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            & winget install --id tailscale.tailscale -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        } catch { }
        if (Test-Path $script:TsExe) { Write-Ok 'installed via winget.'; return }
    }
    # Bundled installer = true offline install (the plain .exe bootstrapper needs internet).
    $toolDir = Join-Path $PSScriptRoot 'tools'
    $full = @(Get-ChildItem $toolDir -Filter 'tailscale-setup*full*.exe' -ErrorAction SilentlyContinue)
    if ($full.Count -gt 0) {
        Write-Step "installing from bundled full installer: $($full[0].FullName)"
        Assert-LocalInstallerTrusted $full[0].FullName
        $proc = Start-Process -FilePath $full[0].FullName -ArgumentList '/quiet' -Wait -PassThru
        if ($proc.ExitCode -ne 0 -or -not (Test-Path $script:TsExe)) { throw 'Tailscale installation failed.' }
        Write-Ok 'installed.'
        return
    }
    $msi = @(Get-ChildItem $toolDir -Filter 'tailscale-setup*.msi' -ErrorAction SilentlyContinue)
    if ($msi.Count -gt 0) {
        Write-Step "installing from bundled MSI: $($msi[0].FullName)"
        Assert-LocalInstallerTrusted $msi[0].FullName
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"{0}"' -f $msi[0].FullName), '/quiet', '/norestart') -Wait -PassThru
        if ($proc.ExitCode -notin 0, 3010 -or -not (Test-Path $script:TsExe)) { throw 'Tailscale MSI installation failed.' }
        Write-Ok 'installed.'
        return
    }
    $installer = Join-Path $env:TEMP ('tailscale-setup-latest-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' -OutFile $installer -UseBasicParsing
        Assert-LocalInstallerTrusted $installer
        $proc = Start-Process -FilePath $installer -ArgumentList '/quiet' -Wait -PassThru
        if ($proc.ExitCode -ne 0 -or -not (Test-Path $script:TsExe)) { throw 'Tailscale installation failed.' }
        Write-Ok 'installed.'
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-TailscaleConnected {
    $backend = $null
    try {
        $result = Invoke-ZcNativeProcess -FilePath $script:TsExe -Arguments @('status','--json') -TimeoutSec 30
        if ($result.ExitCode -eq 0 -and $result.Text) { $backend = ($result.Text | ConvertFrom-Json).BackendState }
    } catch { $backend = $null }
    if ($backend -ne 'Running') {
        throw 'Tailscale is not connected. Open the Tailscale tray icon, log in to the same tailnet and connect, then re-run this script. No hidden login is started.'
    }
    Write-Ok 'Tailscale connected.'
}

function Ensure-WinRMClient {
    $svc = Get-Service WinRM -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Ok 'WinRM client service already running.'
        return
    }
    try {
        Set-Service WinRM -StartupType Automatic -ErrorAction Stop
        Start-Service WinRM -ErrorAction Stop
        Write-Ok 'WinRM client service running.'
    } catch {
        throw "Cannot start the WinRM client service ($($_.Exception.Message)). Right-click -> Run as administrator."
    }
}

function Ensure-TrustedHost([string]$Name) {
    $current = ''
    try { $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value } catch { $current = '' }
    if ($current -eq '*') { Write-Ok 'TrustedHosts is * (no change).'; return [pscustomobject]@{ Changed = $false } }
    $parts = @()
    if ($current) { $parts = @($current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($parts -contains $Name) {
        Write-Ok "TrustedHosts already contains $Name (no elevation needed)."
        return [pscustomobject]@{ Changed = $false }
    }
    $parts += $Name
    $expected = $parts -join ','
    try {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $expected -Force
        Write-Ok "TrustedHosts: $expected"
    } catch {
        throw "Cannot update TrustedHosts ($($_.Exception.Message)). Right-click -> Run as administrator."
    }
    return [pscustomobject]@{ Changed = $true; PriorValue = $current; ExpectedValue = $expected; Name = $Name }
}

function Connect-JumpHost([string]$Name, [pscredential]$Cred) {
    try {
        $remoteName = Invoke-Command -ComputerName $Name -Credential $Cred -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
    } catch {
        Write-Warn2 "Default auth failed: $($_.Exception.Message)"
        Write-Step 'retrying with Negotiate...'
        $remoteName = Invoke-Command -ComputerName $Name -Credential $Cred -Authentication Negotiate -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
    }
    Write-Ok "WinRM OK -> $remoteName"
    return $remoteName
}

function Get-SiteDiscovery([string]$Name, [pscredential]$Cred) {
    return Invoke-Command -ComputerName $Name -Credential $Cred -ScriptBlock {
        $rdp = New-Object System.Collections.ArrayList
        try {
            $hives = @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction Stop | Where-Object { $_.PSChildName -match '^S-1-5-21-' })
            foreach ($hive in $hives) {
                $key = "Registry::HKEY_USERS\$($hive.PSChildName)\Software\Microsoft\Terminal Server Client\Servers"
                try {
                    Get-ChildItem $key -ErrorAction Stop | ForEach-Object { [void]$rdp.Add($_.PSChildName) }
                } catch { }
            }
        } catch { }

        $arp = @()
        try {
            $arp = @((arp -a) -split "`r?`n" | ForEach-Object {
                $m = [regex]::Match($_, '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F-]{17})')
                if ($m.Success) { $m.Groups[1].Value }
            } | Where-Object { $_ -notmatch '^(0|127|224|239|255)\.' } | Sort-Object -Unique)
        } catch { }

        $nics = @()
        try {
            $nics = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
                ForEach-Object { $_.IPAddress })
        } catch { }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            RdpHistory   = @($rdp | Sort-Object -Unique)
            Arp          = $arp
            NicAddresses = $nics
        }
    }
}

function Assert-ForwardMappings {
    param([object[]]$Mappings)
    if (-not $Mappings -or $Mappings.Count -eq 0) { throw 'At least one mapping is required.' }
    $seen = @{}
    foreach ($m in $Mappings) {
        $address = $null
        $text = [string]$m.Connect
        if ($text -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
            -not [Net.IPAddress]::TryParse($text, [ref]$address) -or
            $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $address.ToString() -ne $text) { throw "Invalid target IPv4: '$text'." }
        foreach ($value in @($m.Listen, $m.Port)) {
            $port = 0
            if (-not [int]::TryParse([string]$value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                throw "Port must be an integer in 1..65535: '$value'."
            }
        }
        $key = [string][int]$m.Listen
        if ($seen.ContainsKey($key)) { throw "Duplicate listen port: $key." }
        $seen[$key] = $true
    }
}

function New-ForwardMappings {
    param([string]$TargetAddress, [string[]]$Extra, [int]$Db, [int]$Web, [int]$Rdp)
    $items = @()
    if ($TargetAddress) {
        $items += [pscustomobject]@{ Listen = $Db; Connect = $TargetAddress; Port = 3306; Label = 'MySQL' }
        $items += [pscustomobject]@{ Listen = $Web; Connect = $TargetAddress; Port = 80; Label = 'Web' }
        $items += [pscustomobject]@{ Listen = $Rdp; Connect = $TargetAddress; Port = 3389; Label = 'RDP' }
    }
    foreach ($f in $Extra) {
        if ($f -notmatch '^(\d+):(\d{1,3}(?:\.\d{1,3}){3}):(\d+)$') {
            throw "Bad -Forward '$f'. Expected listen:host:port."
        }
        $items += [pscustomobject]@{ Listen = $Matches[1]; Connect = $Matches[2]; Port = $Matches[3]; Label = 'extra' }
    }
    if ($items.Count -gt 0) { Assert-ForwardMappings $items }
    return $items
}

function Get-ForwardingScriptBlock {
    # Self-contained remote body; tests extract functions with the AST, never main.
    return {
        param([string]$Json, [bool]$ReadOnly, [string]$ValidationBody,
              [string]$RunId = '', [string]$SiteName = '', [string]$StateRoot = '', [bool]$WriteJournal = $false)
        $ErrorActionPreference = 'Stop'
        $items = @(ConvertFrom-Json $Json | ForEach-Object { $_ })
        & ([scriptblock]::Create($ValidationBody)) -Mappings $items

        $journal = $null
        $journalPath = ''
        if ($WriteJournal) {
            if (-not $RunId -or -not $StateRoot) { throw 'Journal requested without RunId/StateRoot.' }
            if (-not (Test-Path -LiteralPath $StateRoot)) {
                New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
            }
            $runsDir = Join-Path $StateRoot 'runs'
            if (-not (Test-Path -LiteralPath $runsDir)) {
                New-Item -ItemType Directory -Path $runsDir -Force | Out-Null
            }
            $acl = & icacls.exe $StateRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Cannot secure state directory ACL: $acl" }
            $journalPath = Join-Path $runsDir ($RunId + '.json')
            $now = (Get-Date).ToUniversalTime().ToString('o')
            $journal = [ordered]@{
                Schema = 1; Tool = 'zcode-remote-access-kit'; RunId = $RunId; Phase = 'connect'
                HostName = $env:COMPUTERNAME; SiteName = $SiteName; CreatedUtc = $now; UpdatedUtc = $now
                Status = 'Applying'; Snapshot = [ordered]@{}; Changes = @(); UndoResults = @()
            }
            function Save-ConnectJournal {
                $journal.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                $tmp = $journalPath + '.tmp'
                $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8
                Move-Item -LiteralPath $tmp -Destination $journalPath -Force
            }
            function Add-ConnectChange([string]$Kind, $Data) {
                $journal.Changes = @($journal.Changes) + [pscustomobject]@{
                    Kind = $Kind
                    AppliedUtc = (Get-Date).ToUniversalTime().ToString('o')
                    Data = $Data
                }
                Save-ConnectJournal
            }
            Save-ConnectJournal
        }

        function Invoke-ForwardNative([string[]]$NativeArgs) {
            $saved = $ErrorActionPreference
            try {
                # PS 5.1 native stderr must not bypass explicit exit-code handling.
                $ErrorActionPreference = 'Continue'
                $output = (& netsh.exe @NativeArgs 2>&1 | Out-String)
                $code = $LASTEXITCODE
            } finally { $ErrorActionPreference = $saved }
            if ($code -ne 0) { throw "netsh failed (exit $code): $($NativeArgs -join ' '): $output" }
            return $output
        }

        function Get-ProxyRows {
            $text = Invoke-ForwardNative @('interface', 'portproxy', 'show', 'v4tov4')
            foreach ($line in ($text -split '\r?\n')) {
                if ($line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3}|\*)\s+(\d+)\s+(.+?)\s+(\d+)\s*$') {
                    $listenAddress = $Matches[1]
                    if ($listenAddress -eq '*') { $listenAddress = '0.0.0.0' }
                    [pscustomobject]@{ Address = $listenAddress; Listen = [int]$Matches[2]; Connect = $Matches[3]; Port = [int]$Matches[4] }
                }
            }
        }

        function Test-ExpectedProxy($Row, $Mapping) {
            return ($Row.Address -eq '0.0.0.0' -and $Row.Connect -eq [string]$Mapping.Connect -and $Row.Port -eq [int]$Mapping.Port)
        }

        $existing = @(Get-ProxyRows)
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
        $plan = @()
        # Preflight EVERY mapping before any write. Other listen addresses conflict.
        foreach ($m in $items) {
            $rows = @($existing | Where-Object { $_.Listen -eq [int]$m.Listen })
            $active = @($listeners | Where-Object { $_.LocalPort -eq [int]$m.Listen })
            if ($rows.Count -gt 0) {
                if ($rows.Count -ne 1 -or -not (Test-ExpectedProxy $rows[0] $m)) {
                    throw "CONFLICT: existing portproxy on port $($m.Listen); no changes made."
                }
                $listening = @($active | Where-Object { $_.LocalAddress -eq '0.0.0.0' -or $_.LocalAddress -eq '*' }).Count -gt 0
                if ($ReadOnly -and -not $listening) { throw "CLOSED: existing listener $($m.Listen) is not active; no changes made." }
                $plan += [pscustomobject]@{ Mapping = $m; Status = 'unchanged'; Listener = $listening }
            } else {
                if ($active.Count -gt 0) { throw "CONFLICT: port $($m.Listen) is occupied; no changes made." }
                if ($ReadOnly) { throw "MISSING: portproxy $($m.Listen); VerifyOnly cannot create it." }
                $plan += [pscustomobject]@{ Mapping = $m; Status = 'new'; Listener = $false }
            }
        }

        $ownedProxies = New-Object System.Collections.ArrayList
        $ownedFirewalls = New-Object System.Collections.ArrayList
        $results = @()
        try {
            foreach ($entry in $plan) {
                $m = $entry.Mapping
                if ($entry.Status -eq 'new') {
                    # Recheck immediately before creating; never delete an old rule.
                    $now = @(Get-ProxyRows | Where-Object { $_.Listen -eq [int]$m.Listen })
                    $busy = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq [int]$m.Listen })
                    if ($now.Count -gt 0 -or $busy.Count -gt 0) { throw "CONFLICT: port $($m.Listen) changed during preflight." }
                    [void]$ownedProxies.Add($m)
                    Invoke-ForwardNative @('interface', 'portproxy', 'add', 'v4tov4', 'listenaddress=0.0.0.0', "listenport=$($m.Listen)", "connectaddress=$($m.Connect)", "connectport=$($m.Port)") | Out-Null
                    $readback = @(Get-ProxyRows | Where-Object { $_.Listen -eq [int]$m.Listen })
                    if ($readback.Count -ne 1 -or -not (Test-ExpectedProxy $readback[0] $m)) { throw "Portproxy readback failed for $($m.Listen)." }
                    if ($WriteJournal) {
                        Add-ConnectChange 'portproxy' @{
                            ListenAddress = '0.0.0.0'
                            ListenPort = [int]$m.Listen
                            ConnectAddress = [string]$m.Connect
                            ConnectPort = [int]$m.Port
                        }
                    }
                    # Unique names ensure rollback cannot delete a pre-existing rule.
                    $ruleName = 'ZCode-Proxy-' + $m.Listen + '-' + [guid]::NewGuid().ToString('N')
                    $ruleDesc = 'ZCodeRemoteAccess:' + $RunId
                    [void]$ownedFirewalls.Add($ruleName)
                    Invoke-ForwardNative @('advfirewall', 'firewall', 'add', 'rule', "name=$ruleName", 'dir=in', 'action=allow', 'protocol=TCP', "localport=$($m.Listen)", 'remoteip=100.64.0.0/10', 'profile=any', "description=$ruleDesc") | Out-Null
                    $firewallText = Invoke-ForwardNative @('advfirewall', 'firewall', 'show', 'rule', "name=$ruleName")
                    if ($firewallText -notmatch [regex]::Escape($ruleName)) { throw "Firewall readback failed for $($m.Listen)." }
                    if ($WriteJournal) {
                        Add-ConnectChange 'firewall.rule' @{
                            Name = $ruleName
                            Description = $ruleDesc
                            LocalPort = [int]$m.Listen
                            RemoteIp = '100.64.0.0/10'
                        }
                    }
                    $entry.Status = 'created'
                }
                $results += [pscustomobject]@{ Listen = [int]$m.Listen; Connect = [string]$m.Connect; Port = [int]$m.Port; Label = [string]$m.Label; Status = $entry.Status; Listener = $entry.Listener }
            }
        } catch {
            $failure = $_.Exception.Message
            $rollbackErrors = @()
            foreach ($ruleName in $ownedFirewalls) {
                try { Invoke-ForwardNative @('advfirewall', 'firewall', 'delete', 'rule', "name=$ruleName") | Out-Null }
                catch { $rollbackErrors += $_.Exception.Message }
            }
            foreach ($m in $ownedProxies) {
                try {
                    $current = @(Get-ProxyRows | Where-Object { $_.Listen -eq [int]$m.Listen })
                    if ($current.Count -eq 1 -and (Test-ExpectedProxy $current[0] $m)) {
                        Invoke-ForwardNative @('interface', 'portproxy', 'delete', 'v4tov4', 'listenaddress=0.0.0.0', "listenport=$($m.Listen)") | Out-Null
                    } elseif ($current.Count -gt 0) { throw "Rollback refused: port $($m.Listen) changed ownership." }
                } catch { $rollbackErrors += $_.Exception.Message }
            }
            if ($rollbackErrors.Count -gt 0) { $failure += '; rollback errors: ' + ($rollbackErrors -join '; ') }
            if ($WriteJournal -and $journal) {
                try {
                    $journal.Status = $(if ($rollbackErrors.Count -eq 0) { 'RolledBack' } else { 'RollbackPartial' })
                    $journal.Error = $failure
                    Save-ConnectJournal
                } catch { }
            }
            throw $failure
        }
        if ($WriteJournal -and $journal) {
            $journal.Status = 'Applied'
            Save-ConnectJournal
        }
        # No service restart, firewall refresh, or scheduled task is performed.
        return $results
    }
}

function Set-RemoteForwards {
    param([string]$Name, [pscredential]$Cred, [object[]]$Mappings,
          [bool]$ForceIt, [bool]$EnsureOnBootIt, [bool]$ReadOnlyIt = $false,
          [string]$RunId = '', [string]$SiteName = '', [string]$StateRoot = '', [bool]$WriteJournal = $false)
    if ($ForceIt -or $EnsureOnBootIt) { throw '-Force and -EnsureOnBoot are disabled; existing rules must not be overwritten.' }
    Assert-ForwardMappings $Mappings
    $json = ConvertTo-Json -InputObject @($Mappings) -Compress
    $block = Get-ForwardingScriptBlock
    $validation = ${function:Assert-ForwardMappings}.ToString()
    return Invoke-Command -ComputerName $Name -Credential $Cred -ScriptBlock $block -ArgumentList $json, $ReadOnlyIt, $validation, $RunId, $SiteName, $StateRoot, $WriteJournal
}

function Assert-ChannelVerification {
    param([string[]]$Failures)
    if ($Failures.Count -gt 0) { throw ('Verification failed: ' + ($Failures -join '; ')) }
}

function New-SiteProfile {
    param([string]$Title, [string]$JumpHost, [string]$JumpUser, [object[]]$Items, [string]$RunId = '', [switch]$DirectOnly)

    $lines = @()
    $lines += '<!-- ZCodeRemoteAccess:RunId=' + $RunId + ' -->'
    $lines += "# Remote access profile - $Title"
    $lines += ''
    $lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $lines += ''
    $lines += '## Link'
    $lines += "Local PC  <->  Tailscale  <->  jump host $JumpHost  (account $JumpUser)"
    $lines += ''
    if ($DirectOnly) {
        $lines += 'Mode: Direct PC access. WinRM remote command verified; no port forwarding was configured.'
        $lines += ''
        $lines += ('- Remote command: Invoke-Command -ComputerName {0} -Credential (Get-Credential {1}) -ScriptBlock {{ hostname }}' -f $JumpHost, $JumpUser)
        $lines += ('- RDP address: {0}:3389 (only if Remote Desktop is already enabled on that PC).' -f $JumpHost)
        $lines += '- This kit does not enable Remote Desktop or open its firewall rules.'
        return ($lines -join "`r`n")
    }
    $lines += '## Channels (portproxy on the jump host; effective firewall policy is not audited)'
    $lines += ''
    $lines += '| Listen | Connect to | Purpose |'
    $lines += '|---|---|---|'
    foreach ($i in $Items) {
        $lines += ('| {0} | {1}:{2} | {3} |' -f $i.Listen, $i.Connect, $i.Port, $i.Label)
    }
    $lines += ''
    $lines += '## Daily use'
    $lines += ("- Web:    http://{0}:{1}" -f $JumpHost, $WebPort)
    $lines += ("- MySQL:  {0}:{1}" -f $JumpHost, $DbPort)
    $lines += ("- RDP:    {0}:{1}" -f $JumpHost, $RdpPort)
    $lines += ("- Remote command: Invoke-Command -ComputerName {0} -Credential (Get-Credential {1})" -f $JumpHost, $JumpUser)
    $lines += ''
    $lines += '## Health checks'
    $lines += '- ' + ('tailscale status on the local PC shows the jump host online')
    $lines += ("- netsh interface portproxy show v4tov4   (on the jump host)")
    $lines += ("- Test-NetConnection {0} -Port {1}" -f $JumpHost, $DbPort)
    return ($lines -join "`r`n")
}

# ------------------------------------------------------------------ main ---
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ' Connect local PC to a project site' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan

try {
    if ($Force -or $EnsureOnBoot) { throw '-Force and -EnsureOnBoot are disabled; no overrides or startup tasks are allowed.' }
    if ($DirectOnly -and ($Target -or $Forward.Count -or $Discover -or $NoVerify)) { throw '-DirectOnly cannot be combined with target mappings, discovery or skipped verification.' }
    if ($VerifyOnly -and -not $DirectOnly -and -not $Target) { throw '-VerifyOnly requires an explicit -Target IPv4 address in forward mode.' }
    if ($VerifyOnly -and ($NoVerify -or $Discover)) { throw '-VerifyOnly cannot be combined with -NoVerify or -Discover.' }
    # Validate all explicitly supplied mappings before changing local prerequisites.
    $initialMappings = @(New-ForwardMappings -TargetAddress $Target -Extra $Forward -Db $DbPort -Web $WebPort -Rdp $RdpPort)
    if (-not $JumpHost) {
        # Zero-input path: pick the jump host IP left by 01-jump-setup.ps1.
        $resPath = Join-Path $PSScriptRoot 'access-result.txt'
        if (Test-Path $resPath) {
            foreach ($line in Get-Content $resPath) {
                if ($line -match '^JumpHost=(.+)$') { $JumpHost = $Matches[1].Trim(); break }
            }
            if ($JumpHost) { Write-Ok "Jump host read from access-result.txt: $JumpHost" }
        }
    }
    if (-not $JumpHost) { $JumpHost = (Read-Host 'Jump host Tailscale IPv4 (printed by 01-jump-setup.ps1)').Trim() }
    if (-not $JumpHost) { throw 'JumpHost is required.' }

    $runId = ''
    $localRoot = ''
    $localJournal = $null
    if (-not $VerifyOnly) {
        $runId = New-ZcRunId 'connect'
        $localRoot = Initialize-ZcLocalStateRoot
        $localJournal = New-ZcJournal -Phase 'local' -SiteName $SiteName -HostName $env:COMPUTERNAME -RunId $runId
        Save-ZcJournal -Root $localRoot -Journal $localJournal | Out-Null
        Write-Host " Run ID: $runId" -ForegroundColor DarkGray
    }

    if ($VerifyOnly) {
        Write-Step '1/7 and 2/7 VerifyOnly: local installation/services unchanged'
    } else {
        Write-Step '1/7 local Tailscale'
        Ensure-LocalTailscale
        Ensure-TailscaleConnected
        Write-Step '2/7 WinRM client'
        Ensure-WinRMClient
    }

    $jumpPassword = Get-PlainPassword $JumpPassword "Password for '$JumpUser' on the jump host"
    $secure       = ConvertTo-SecureString $jumpPassword -AsPlainText -Force
    $cred         = New-Object System.Management.Automation.PSCredential($JumpUser, $secure)

    Write-Step '3/7 trust + verify WinRM to the jump host'
    if (-not $VerifyOnly) {
        $trust = Ensure-TrustedHost $JumpHost
        if ($trust.Changed) {
            Add-ZcChange -Root $localRoot -Journal $localJournal -Kind 'trustedhosts' -Data @{
                PriorValue = [string]$trust.PriorValue
                ExpectedValue = [string]$trust.ExpectedValue
                Name = [string]$trust.Name
            } | Out-Null
        }
    }
    else { Write-Step 'VerifyOnly: existing TrustedHosts configuration is used without changes' }
    if ($VerifyOnly -and -not $DirectOnly) { $remoteName = 'VerifyOnly (existing configuration)' }
    else { $remoteName = Connect-JumpHost $JumpHost $cred }

    $mappings = @()
    $verificationFailures = @()
    if (-not $DirectOnly) {
    Write-Step '4/7 discover candidate servers'
    $discovery = $null
    if ($Discover -or -not $Target) {
        $discovery = Get-SiteDiscovery $JumpHost $cred
        Write-Host ''
        Write-Host "Seen from jump host '$($discovery.ComputerName)':" -ForegroundColor Cyan
        Write-Host "  jump host NICs: $(@($discovery.NicAddresses) -join ', ')"
        if ($discovery.RdpHistory.Count -gt 0) {
            Write-Host '  RDP history:'
            $discovery.RdpHistory | ForEach-Object { Write-Host "    - $_" }
        } else {
            Write-Host '  RDP history: (none - user profiles may not be loaded)'
        }
        if ($discovery.Arp.Count -gt 0) {
            Write-Host '  ARP neighbours:'
            $discovery.Arp | ForEach-Object { Write-Host "    - $_" }
        }
        Write-Host ''
    }
    if (-not $Target) {
        # Zero-input path: probe candidates (RDP history + ARP) from the jump host
        # and auto-select the machine that answers MySQL 3306 (plus 80 if ambiguous).
        $candidates = @(@($discovery.RdpHistory) + @($discovery.Arp)) | Where-Object {
            $_ -and ($_ -match '^\d{1,3}(\.\d{1,3}){3}$') -and
            ($_ -notmatch '^(0|127|169|224|239|255)\.') -and
            (@($discovery.NicAddresses) -notcontains $_)
        } | Sort-Object -Unique

        if ($candidates.Count -gt 0) {
            $candidates = @($candidates | Select-Object -First 15)
            Write-Step 'auto-probing candidates from the jump host (3306/80/3389)...'
            $probeBlock = {
                param([string[]]$Ips)
                function Test-TcpPort([string]$Ip, [int]$Port, [int]$TimeoutMs = 500) {
                    $client = New-Object System.Net.Sockets.TcpClient
                    try {
                        $async = $client.BeginConnect($Ip, $Port, $null, $null)
                        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) { return $true }
                    } catch { } finally { $client.Close() }
                    return $false
                }
                foreach ($ip in $Ips) {
                    [pscustomobject]@{
                        Ip        = $ip
                        MySql3306 = (Test-TcpPort $ip 3306)
                        Web80     = (Test-TcpPort $ip 80)
                        Rdp3389   = (Test-TcpPort $ip 3389)
                    }
                }
            }
            $probed = @(Invoke-Command -ComputerName $JumpHost -Credential $cred -ScriptBlock $probeBlock -ArgumentList (,$candidates))
            $probed | Format-Table Ip, MySql3306, Web80, Rdp3389 -AutoSize | Out-String | Write-Host

            $dbHits = @($probed | Where-Object { $_.MySql3306 })
            if ($dbHits.Count -eq 1) {
                $Target = [string]$dbHits[0].Ip
                Write-Ok "main server auto-selected: $Target (MySQL 3306 open)"
            } elseif ($dbHits.Count -gt 1) {
                $webHits = @($dbHits | Where-Object { $_.Web80 })
                if ($webHits.Count -eq 1) {
                    $Target = [string]$webHits[0].Ip
                    Write-Ok "main server auto-selected: $Target (3306 + 80 open)"
                }
            }
        }
        if (-not $Target) {
            try {
                $Target = (Read-Host 'Main target server IPv4 (gets MySQL + Web + RDP); leave empty to skip').Trim()
            } catch {
                throw 'Multiple candidate servers and this session is non-interactive. Set targetServer in config.json or pass -Target <ipv4> explicitly.'
            }
        }
    }
    Write-Step '5/7 build and validate mappings'
    $mappings = @(New-ForwardMappings -TargetAddress $Target -Extra $Forward -Db $DbPort -Web $WebPort -Rdp $RdpPort)
    if ($mappings.Count -eq 0) { throw 'No mappings were selected. Supply -Target or -Forward; no connectivity pass is claimed.' }
    foreach ($m in $mappings) {
        Write-Host ("  {0,-6} -> {1}:{2}  [{3}]" -f $m.Listen, $m.Connect, $m.Port, $m.Label)
    }

    Write-Step '6/7 inspect rules; create only missing non-conflicting mappings'
    $result = Set-RemoteForwards -Name $JumpHost -Cred $cred -Mappings $mappings -ForceIt ([bool]$Force) -EnsureOnBootIt ([bool]$EnsureOnBoot) -ReadOnlyIt ([bool]$VerifyOnly) -RunId $runId -SiteName $SiteName -StateRoot 'C:\ProgramData\ZCodeRemoteAccess' -WriteJournal (-not $VerifyOnly)
    foreach ($r in $result) {
        Write-Ok ("{0} -> {1}:{2} [{3}]: {4}" -f $r.Listen, $r.Connect, $r.Port, $r.Label, $r.Status)
    }

    $verificationFailures = @()
    if (-not $NoVerify) {
        Write-Step '7/7 verify from this machine (no services are restarted)'
        foreach ($m in $mappings) {
            # A bounded TCP probe checks the frontend listener, not backend health.
            $open = $false
            foreach ($attempt in 1, 2, 3) {
                $client = New-Object System.Net.Sockets.TcpClient
                try {
                    $async = $client.BeginConnect($JumpHost, [int]$m.Listen, $null, $null)
                    if ($async.AsyncWaitHandle.WaitOne(4000) -and $client.Connected) { $open = $true }
                } catch { } finally { $client.Close() }
                if ($open) { break }
                if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
            }
            $line = ("{0}:{1} -> {2}:{3} [{4}]" -f $JumpHost, $m.Listen, $m.Connect, $m.Port, $m.Label)
            if ($open) { Write-Ok "OPEN   $line" } else {
                Write-Warn2 "CLOSED $line  (check jump host firewall/portproxy and the target service)"
                $verificationFailures += "CLOSED $line"
            }
        }
        if ($Target) {
            try {
                # Disable the HTTP application proxy only. OS/TUN routing still applies.
                # (-NoProxy is PS 6+ only; this kit targets PS 5.1.)
                $req = [System.Net.HttpWebRequest]::Create(("http://{0}:{1}/" -f $JumpHost, $WebPort))
                $req.Proxy = $null
                $req.Timeout = 20000
                $req.UserAgent = 'zcode-remote-access-kit/1.0'
                $resp = $req.GetResponse()
                Write-Ok ("Web responded: HTTP {0}" -f [int]$resp.StatusCode)
                $resp.Close()
            } catch {
                $we = $_.Exception
                $msg = $we.Message
                if ($we.Response) {
                    $msg = ("HTTP {0}" -f [int]$we.Response.StatusCode)
                    $we.Response.Close()
                }
                Write-Warn2 "Web probe failed: $msg"
                $verificationFailures += "Web probe failed: $msg"
            }
        }
    } else {
        Write-Warn2 '7/7 UNVERIFIED: channel verification skipped (-NoVerify); no connectivity pass is claimed.'
    }
    Assert-ChannelVerification -Failures $verificationFailures
    } else {
        Write-Ok ("Direct remote command verified on {0}; no discovery, forwarding or remote firewall changes were made." -f $remoteName)
    }

    $title = 'site'
    if ($SiteName) { $title = $SiteName }
    $profile = New-SiteProfile -Title $title -JumpHost $JumpHost -JumpUser $JumpUser -Items $mappings -RunId $runId -DirectOnly:$DirectOnly
    if ($NoVerify) { $profile = "Verification: UNVERIFIED (channel probes were skipped).`r`n`r`n" + $profile }
    Write-Host ''
    Write-Host $profile
    if ($ProfilePath -and -not $VerifyOnly) {
        Save-ZcProfile -Root $localRoot -Journal $localJournal -Path $ProfilePath -Content $profile -Marker ('ZCodeRemoteAccess:RunId=' + $runId) | Out-Null
        Write-Ok "profile saved: $ProfilePath"
    }

    if ($localJournal) {
        $localJournal.Status = 'Applied'
        Save-ZcJournal -Root $localRoot -Journal $localJournal | Out-Null
    }

    $adminHint = ''
    if (-not (Test-Admin)) { $adminHint = ' (run as Administrator next time to avoid UAC prompts)' }

    Write-Host ''
    if ($NoVerify) { Write-Host '========================= UNVERIFIED =========================' -ForegroundColor Yellow }
    elseif ($VerifyOnly) { Write-Host '====================== VERIFY ONLY PASS ======================' -ForegroundColor Green }
    else { Write-Host '============================ DONE ============================' -ForegroundColor Green }
    Write-Host "Jump host : $JumpHost ($remoteName)"
    Write-Host "Ops user  : $JumpUser"
    if ($runId) { Write-Host "Run ID    : $runId" }
    if (-not $DirectOnly) { Write-Host 'TCP OPEN checks frontend listeners only; verify backend application access separately.' }
    Write-Host "==============================================================$adminHint" -ForegroundColor Green
}
catch {
    if ($localJournal) {
        try {
            $localJournal.Status = 'Failed'
            $localJournal | Add-Member -NotePropertyName Error -NotePropertyValue $_.Exception.Message -Force
            Save-ZcJournal -Root $localRoot -Journal $localJournal | Out-Null
        } catch { }
    }
    Write-Host ''
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
