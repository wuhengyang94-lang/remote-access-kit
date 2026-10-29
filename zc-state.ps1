#Requires -Version 5.1
# Shared run-journal and undo helpers for the remote-access kit.
# ASCII-only. Journals must never contain secrets (auth keys, passwords).

$script:ZcToolName = 'zcode-remote-access-kit'
$script:ZcSchema = 1
$script:ZcMarker = 'ZCodeRemoteAccess'

function Get-ZcStateRoot {
    param([string]$Override)
    if ($Override) { return $Override }
    return (Join-Path $env:ProgramData 'ZCodeRemoteAccess')
}

function Get-ZcLocalStateRoot {
    param([string]$Override)
    if ($Override) { return $Override }
    return (Join-Path $env:LOCALAPPDATA 'ZCodeRemoteAccess')
}

function Initialize-ZcStateRoot {
    param([string]$Path)
    if (-not $Path) { $Path = Get-ZcStateRoot }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $runs = Join-Path $Path 'runs'
    if (-not (Test-Path -LiteralPath $runs)) {
        New-Item -ItemType Directory -Path $runs -Force | Out-Null
    }
    $out = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot secure state directory ACL ($Path): $out"
    }
    return $Path
}

function Initialize-ZcLocalStateRoot {
    param([string]$Path)
    if (-not $Path) { $Path = Get-ZcLocalStateRoot }
    $runs = Join-Path $Path 'runs'
    if (-not (Test-Path -LiteralPath $runs)) {
        New-Item -ItemType Directory -Path $runs -Force | Out-Null
    }
    return $Path
}

function New-ZcRunId {
    param([string]$Phase)
    if (-not $Phase) { $Phase = 'run' }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $chars = '0123456789abcdef'
    $rand = ''
    for ($i = 0; $i -lt 8; $i++) { $rand += $chars[(Get-Random -Maximum 16)] }
    return ('{0}-{1}-{2}' -f $Phase, $stamp, $rand)
}

function New-ZcJournal {
    param(
        [string]$Phase,
        [string]$SiteName,
        [string]$HostName,
        $Snapshot = $null,
        [string]$RunId
    )
    if (-not $RunId) { $RunId = New-ZcRunId $Phase }
    if ($null -eq $Snapshot) { $Snapshot = [pscustomobject]@{} }
    return [pscustomobject]@{
        Schema      = $script:ZcSchema
        Tool        = $script:ZcToolName
        RunId       = $RunId
        Phase       = $Phase
        HostName    = $HostName
        SiteName    = $SiteName
        CreatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        UpdatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        Status      = 'Applying'
        Snapshot    = $Snapshot
        Changes     = @()
        UndoResults = @()
    }
}

function Get-ZcJournalPath {
    param([string]$Root, [string]$RunId)
    return (Join-Path (Join-Path $Root 'runs') ($RunId + '.json'))
}

function Save-ZcJournal {
    param([string]$Root, $Journal)
    $Journal.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $runs = Join-Path $Root 'runs'
    if (-not (Test-Path -LiteralPath $runs)) {
        New-Item -ItemType Directory -Path $runs -Force | Out-Null
    }
    $path = Get-ZcJournalPath -Root $Root -RunId $Journal.RunId
    $tmp = $path + '.tmp'
    $Journal | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Add-ZcChange {
    param([string]$Root, $Journal, [string]$Kind, $Data)
    $change = [pscustomobject]@{
        Kind       = $Kind
        AppliedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Data       = $Data
    }
    $Journal.Changes = @($Journal.Changes) + $change
    Save-ZcJournal -Root $Root -Journal $Journal | Out-Null
    return $change
}

function Read-ZcJournal {
    param([string]$Path)
    $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$j.Schema -ne $script:ZcSchema) { throw "Unsupported journal schema in $Path" }
    if (-not $j.RunId -or -not $j.Phase) { throw "Invalid journal in $Path" }
    return $j
}

function Get-ZcJournals {
    param([string]$Root, [string]$RunId, [string[]]$Phase)
    $runs = Join-Path $Root 'runs'
    if (-not (Test-Path -LiteralPath $runs)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $runs -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($RunId) { $files = @($files | Where-Object { $_.BaseName -eq $RunId }) }
    $out = @()
    foreach ($f in $files) {
        try {
            $j = Read-ZcJournal -Path $f.FullName
            if ($Phase -and ($Phase -notcontains [string]$j.Phase)) { continue }
            $out += $j
        } catch { }
    }
    return @($out | Sort-Object CreatedUtc)
}

function Invoke-ZcNative {
    param([string]$FilePath, [string[]]$Arguments)
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $FilePath @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return [pscustomobject]@{ Output = $output; ExitCode = $code }
}

function Invoke-ZcTailscaleLogout {
    param([string]$Exe, [int]$TimeoutSec = 30)
    # The Tailscale GUI/IPN can hold the IPC and make the CLI block forever.
    # Use .NET Process: Start-Process -PassThru can return a null ExitCode when
    # stdout/stderr are redirected.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = 'logout'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        try { [void]$proc.WaitForExit(5000) } catch { }
        return [pscustomobject]@{ Text = 'TIMEOUT'; ExitCode = -1 }
    }
    $text = ''
    try { $text = $outTask.Result + $errTask.Result } catch { }
    return [pscustomobject]@{ Text = $text; ExitCode = $proc.ExitCode }
}

function Get-ZcProxyRows {
    $r = Invoke-ZcNative 'netsh.exe' @('interface', 'portproxy', 'show', 'v4tov4')
    if ($r.ExitCode -ne 0) { throw "netsh show failed (exit $($r.ExitCode)): $($r.Output)" }
    $rows = @()
    foreach ($line in ($r.Output -split '\r?\n')) {
        if ($line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3}|\*)\s+(\d+)\s+(.+?)\s+(\d+)\s*$') {
            $addr = $Matches[1]
            if ($addr -eq '*') { $addr = '0.0.0.0' }
            $rows += [pscustomobject]@{
                Address = $addr
                Listen  = [int]$Matches[2]
                Connect = $Matches[3]
                Port    = [int]$Matches[4]
            }
        }
    }
    return $rows
}

function Test-ZcProxyOwned {
    param($Row, $Change)
    if (-not $Row -or -not $Change) { return $false }
    $d = $Change.Data
    return (
        [string]$Row.Address -eq [string]$d.ListenAddress -and
        [int]$Row.Listen -eq [int]$d.ListenPort -and
        [string]$Row.Connect -eq [string]$d.ConnectAddress -and
        [int]$Row.Port -eq [int]$d.ConnectPort
    )
}

function Get-ZcFirewallRule {
    param([string]$Name)
    # netsh-created rules have a GUID Name and the supplied text as DisplayName.
    try {
        $rule = Get-NetFirewallRule -Name $Name -ErrorAction Stop
        if ($rule) { return $rule }
    } catch { }
    try {
        return (Get-NetFirewallRule -DisplayName $Name -ErrorAction Stop | Select-Object -First 1)
    } catch {
        return $null
    }
}

function Test-ZcFirewallOwned {
    param($Rule, [string]$RunId)
    if (-not $Rule) { return $false }
    $needle = $script:ZcMarker + ':' + $RunId
    return ([string]$Rule.Description).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-ZcWinRmServiceState {
    try {
        $s = Get-Service WinRM -ErrorAction Stop
        return [pscustomobject]@{ Status = [string]$s.Status; StartType = [string]$s.StartType }
    } catch { return $null }
}

function Get-ZcWinRmListenerState {
    try {
        $items = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop)
        return [pscustomobject]@{ Count = [int]$items.Count; Keys = @($items | ForEach-Object { [string]$_.PSChildName }) }
    } catch {
        return [pscustomobject]@{ Count = 0; Keys = @() }
    }
}

function Get-ZcRegState {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return [pscustomobject]@{ Exists = $true; Value = $item.$Name }
    } catch {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
}

function Set-ZcRegState {
    param([string]$Path, [string]$Name, $Value, [bool]$Exists)
    if ($Exists) {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force
    } else {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

function Get-ZcLocalUserState {
    param([string]$Name)
    Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction SilentlyContinue
    try {
        $u = Get-LocalUser -Name $Name -ErrorAction Stop
        return [pscustomobject]@{ Name = [string]$u.Name; Sid = [string]$u.SID.Value; Enabled = [bool]$u.Enabled }
    } catch { return $null }
}

function Get-ZcTailscaleProductState {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    try {
        $p = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '^Tailscale' } |
            Select-Object -First 1
        if ($p) {
            return [pscustomobject]@{
                ProductCode     = [string]$p.PSChildName
                DisplayName     = [string]$p.DisplayName
                UninstallString = [string]$p.UninstallString
            }
        }
    } catch { }
    return $null
}

function New-ZcUndoResult {
    param([string]$Kind, [string]$Target, [string]$Action, [string]$Status, [string]$Detail)
    return [pscustomobject]@{ Kind = $Kind; Target = $Target; Action = $Action; Status = $Status; Detail = $Detail }
}

function Invoke-ZcUndoJournal {
    param(
        [string]$Root,
        $Journal,
        [switch]$DryRun,
        [switch]$RemoveTailscale,
        [switch]$UnjoinTailscale
    )
    if ($Journal.HostName -ne $env:COMPUTERNAME) {
        throw "Journal belongs to '$($Journal.HostName)', not '$env:COMPUTERNAME'. Run undo on the correct host."
    }
    if ($Journal.Phase -eq 'local') { return (Invoke-ZcUndoLocalJournal -Root $Root -Journal $Journal -DryRun:$DryRun) }

    $results = New-Object System.Collections.ArrayList
    # Log out of the tailnet before uninstalling Tailscale. Keep the install
    # undo last even though the journal recorded it before the join.
    $allChanges = @($Journal.Changes)
    $orderedChanges = @(@($allChanges | Where-Object { [string]$_.Kind -ne 'tailscale.install' })) +
                      @(@($allChanges | Where-Object { [string]$_.Kind -eq 'tailscale.install' }))
    foreach ($c in $orderedChanges) {
        $kind = [string]$c.Kind
        $d = $c.Data
        switch ($kind) {
            'scheduledtask' {
                $name = [string]$d.Name
                $q = Invoke-ZcNative 'schtasks.exe' @('/Query', '/TN', $name)
                if ($q.ExitCode -ne 0) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'none' 'Skipped' 'task not present'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'delete task' 'Planned' ''))
                } else {
                    $r = Invoke-ZcNative 'schtasks.exe' @('/Delete', '/TN', $name, '/F')
                    if ($r.ExitCode -eq 0) {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'delete task' 'Removed' ''))
                    } else {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'delete task' 'Error' $r.Output.Trim()))
                    }
                }
            }
            'tempdir' {
                $path = [string]$d.Path
                if ($path -and $path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $path)) {
                    if ($DryRun) {
                        [void]$results.Add((New-ZcUndoResult $kind $path 'delete directory' 'Planned' ''))
                    } else {
                        try {
                            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                            [void]$results.Add((New-ZcUndoResult $kind $path 'delete directory' 'Removed' ''))
                        } catch {
                            [void]$results.Add((New-ZcUndoResult $kind $path 'delete directory' 'Error' $_.Exception.Message))
                        }
                    }
                } else {
                    [void]$results.Add((New-ZcUndoResult $kind $path 'none' 'Skipped' 'not present or outside state root'))
                }
            }
            'firewall.rule' {
                $name = [string]$d.Name
                $rule = Get-ZcFirewallRule $name
                if (-not $rule) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'none' 'Skipped' 'rule not present'))
                } elseif (-not (Test-ZcFirewallOwned $rule $Journal.RunId)) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'delete rule' 'Error' 'description marker mismatch'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'delete rule' 'Planned' ''))
                } else {
                    try {
                        Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
                        [void]$results.Add((New-ZcUndoResult $kind $name 'delete rule' 'Removed' ''))
                    } catch {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'delete rule' 'Error' $_.Exception.Message))
                    }
                }
            }
            'portproxy' {
                $target = ('{0}:{1} -> {2}:{3}' -f $d.ListenAddress, $d.ListenPort, $d.ConnectAddress, $d.ConnectPort)
                try {
                    $rows = @(Get-ZcProxyRows | Where-Object { $_.Listen -eq [int]$d.ListenPort })
                    if ($rows.Count -eq 0) {
                        [void]$results.Add((New-ZcUndoResult $kind $target 'none' 'Skipped' 'rule not present'))
                    } elseif ($rows.Count -eq 1 -and (Test-ZcProxyOwned $rows[0] $c)) {
                        if ($DryRun) {
                            [void]$results.Add((New-ZcUndoResult $kind $target 'delete portproxy' 'Planned' ''))
                        } else {
                            $r = Invoke-ZcNative 'netsh.exe' @('interface', 'portproxy', 'delete', 'v4tov4', "listenaddress=$($d.ListenAddress)", "listenport=$($d.ListenPort)")
                            if ($r.ExitCode -eq 0) {
                                [void]$results.Add((New-ZcUndoResult $kind $target 'delete portproxy' 'Removed' ''))
                            } else {
                                [void]$results.Add((New-ZcUndoResult $kind $target 'delete portproxy' 'Error' $r.Output.Trim()))
                            }
                        }
                    } else {
                        [void]$results.Add((New-ZcUndoResult $kind $target 'delete portproxy' 'Error' 'current rule differs; not removed'))
                    }
                } catch {
                    [void]$results.Add((New-ZcUndoResult $kind $target 'delete portproxy' 'Error' $_.Exception.Message))
                }
            }
            'winrm.firewall' {
                foreach ($item in @($d.Created)) {
                    $name = [string]$item.Name
                    $rule = Get-ZcFirewallRule $name
                    if (-not $rule) {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'none' 'Skipped' 'rule not present'))
                    } elseif (-not (Test-ZcFirewallOwned $rule $Journal.RunId)) {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'delete rule' 'Error' 'description marker mismatch'))
                    } elseif ($DryRun) {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'delete rule' 'Planned' ''))
                    } else {
                        try {
                            Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
                            [void]$results.Add((New-ZcUndoResult $kind $name 'delete rule' 'Removed' ''))
                        } catch {
                            [void]$results.Add((New-ZcUndoResult $kind $name 'delete rule' 'Error' $_.Exception.Message))
                        }
                    }
                }
                foreach ($item in @($d.ExistingBefore)) {
                    $name = [string]$item.Name
                    $rule = Get-ZcFirewallRule $name
                    if (-not $rule) {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'none' 'Skipped' 'rule not present'))
                    } elseif ([string]$rule.Enabled -eq [string]$item.EnabledBefore) {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'none' 'Skipped' 'state already matches'))
                    } elseif ($DryRun) {
                        [void]$results.Add((New-ZcUndoResult $kind $name ('restore Enabled=' + $item.EnabledBefore) 'Planned' ''))
                    } else {
                        try {
                            Set-NetFirewallRule -Name $rule.Name -Enabled ([bool]::Parse([string]$item.EnabledBefore)) -ErrorAction Stop
                            [void]$results.Add((New-ZcUndoResult $kind $name ('restore Enabled=' + $item.EnabledBefore) 'Restored' ''))
                        } catch {
                            [void]$results.Add((New-ZcUndoResult $kind $name 'restore Enabled' 'Error' $_.Exception.Message))
                        }
                    }
                }
            }
            'winrm.listener' {
                if (-not [bool]$d.Created) {
                    [void]$results.Add((New-ZcUndoResult $kind 'WinRM HTTP listener' 'none' 'Skipped' 'not created by this run'))
                } elseif ([bool]$d.HttpBefore) {
                    [void]$results.Add((New-ZcUndoResult $kind 'WinRM HTTP listener' 'none' 'Skipped' 'HTTP listener existed before'))
                } else {
                    $state = Get-ZcWinRmListenerState
                    if ($state.Count -eq 0) {
                        [void]$results.Add((New-ZcUndoResult $kind 'WinRM HTTP listener' 'none' 'Skipped' 'listener not present'))
                    } elseif ($DryRun) {
                        [void]$results.Add((New-ZcUndoResult $kind 'WinRM HTTP listener' 'remove listener' 'Planned' ''))
                    } else {
                        try {
                            Remove-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{ Address = '*'; Transport = 'HTTP' } -ErrorAction Stop
                            [void]$results.Add((New-ZcUndoResult $kind 'WinRM HTTP listener' 'remove listener' 'Removed' ''))
                        } catch {
                            [void]$results.Add((New-ZcUndoResult $kind 'WinRM HTTP listener' 'remove listener' 'Error' $_.Exception.Message))
                        }
                    }
                }
            }
            'winrm.service' {
                if (-not [bool]$d.Changed) {
                    [void]$results.Add((New-ZcUndoResult $kind 'WinRM service' 'none' 'Skipped' 'not changed by this run'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind 'WinRM service' ('restore StartType=' + $d.StartupBefore + ', Status=' + $d.StatusBefore) 'Planned' ''))
                } else {
                    try {
                        Set-Service WinRM -StartupType ([string]$d.StartupBefore) -ErrorAction Stop
                        if ([string]$d.StatusBefore -eq 'Stopped') {
                            Stop-Service WinRM -Force -ErrorAction SilentlyContinue
                        } else {
                            Start-Service WinRM -ErrorAction SilentlyContinue
                        }
                        [void]$results.Add((New-ZcUndoResult $kind 'WinRM service' 'restore service state' 'Restored' ''))
                    } catch {
                        [void]$results.Add((New-ZcUndoResult $kind 'WinRM service' 'restore service state' 'Error' $_.Exception.Message))
                    }
                }
            }
            'account.create' {
                $name = [string]$d.Name
                if (-not [bool]$d.Created) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'none' 'Skipped' 'not created by this run'))
                } else {
                    $u = Get-ZcLocalUserState $name
                    if (-not $u) {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'none' 'Skipped' 'account not present'))
                    } elseif ($u.Sid -ne [string]$d.Sid) {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'delete account' 'Error' 'SID mismatch; not removed'))
                    } elseif ($DryRun) {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'delete account' 'Planned' ''))
                    } else {
                        try {
                            Remove-LocalUser -Name $name -ErrorAction Stop
                            [void]$results.Add((New-ZcUndoResult $kind $name 'delete account' 'Removed' ''))
                        } catch {
                            [void]$results.Add((New-ZcUndoResult $kind $name 'delete account' 'Error' $_.Exception.Message))
                        }
                    }
                }
            }
            'account.update' {
                [void]$results.Add((New-ZcUndoResult $kind ([string]$d.Name) 'manual' 'Error' 'existing account password was changed; the old password cannot be restored'))
            }
            { $_ -eq 'registry.latfp' -or $_ -eq 'registry.iprouter' } {
                $path = [string]$d.Path
                $name = [string]$d.Name
                $cur = Get-ZcRegState -Path $path -Name $name
                if ($cur.Exists -and [string]$cur.Value -ne [string]$d.ValueSet) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Error' 'current value differs; not restored'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Planned' ''))
                } else {
                    try {
                        Set-ZcRegState -Path $path -Name $name -Value $d.ValueBefore -Exists ([bool]$d.ExistedBefore)
                        [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Restored' ''))
                    } catch {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Error' $_.Exception.Message))
                    }
                }
            }
            'registry.tailscale-env' {
                $path = [string]$d.Path
                $name = [string]$d.Name
                $cur = Get-ZcRegState -Path $path -Name $name
                $curText = (@($cur.Value) -join "`n")
                $setText = (@($d.ValueSet) -join "`n")
                if ($cur.Exists -and $curText -ne $setText) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Error' 'current value differs; not restored'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Planned' ''))
                } else {
                    try {
                        Set-ZcRegState -Path $path -Name $name -Value $d.ValueBefore -Exists ([bool]$d.ExistedBefore)
                        [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Restored' ''))
                    } catch {
                        [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Error' $_.Exception.Message))
                    }
                }
            }
            'tailscale.install' {
                if (-not $RemoveTailscale) {
                    [void]$results.Add((New-ZcUndoResult $kind 'Tailscale' 'none' 'Skipped' 'install kept; use -RemoveTailscale to uninstall'))
                } elseif ([bool]$d.InstalledBefore) {
                    [void]$results.Add((New-ZcUndoResult $kind 'Tailscale' 'none' 'Skipped' 'Tailscale existed before this run'))
                } elseif (-not [string]$d.ProductCode) {
                    [void]$results.Add((New-ZcUndoResult $kind 'Tailscale' 'uninstall' 'Error' 'MSI product code not recorded'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind 'Tailscale' 'uninstall MSI' 'Planned' ''))
                } else {
                    $r = Invoke-ZcNative 'msiexec.exe' @('/x', [string]$d.ProductCode, '/quiet', '/norestart')
                    if ($r.ExitCode -in 0, 1605, 3010) {
                        [void]$results.Add((New-ZcUndoResult $kind 'Tailscale' 'uninstall MSI' 'Removed' ''))
                    } else {
                        [void]$results.Add((New-ZcUndoResult $kind 'Tailscale' 'uninstall MSI' 'Error' ("msiexec exit $($r.ExitCode): $($r.Output)".Trim())))
                    }
                }
            }
            'tailscale.join' {
                if (-not $UnjoinTailscale) {
                    [void]$results.Add((New-ZcUndoResult $kind 'Tailscale node' 'none' 'Skipped' 'node kept; revoke it in the Tailscale admin console'))
                } elseif (-not [bool]$d.JoinedByTool) {
                    [void]$results.Add((New-ZcUndoResult $kind 'Tailscale node' 'none' 'Skipped' 'node was already joined before this run'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind 'Tailscale node' 'tailscale logout' 'Planned' ''))
                } else {
                    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
                    if (-not (Test-Path -LiteralPath $exe)) {
                        [void]$results.Add((New-ZcUndoResult $kind 'Tailscale node' 'tailscale logout' 'Error' 'tailscale.exe not found'))
                    } else {
                        $r = Invoke-ZcTailscaleLogout -Exe $exe -TimeoutSec 30
                        if ($r.ExitCode -eq 0) {
                            [void]$results.Add((New-ZcUndoResult $kind 'Tailscale node' 'tailscale logout' 'Removed' ''))
                        } elseif ($r.Text -match 'TIMEOUT|already in use|401') {
                            [void]$results.Add((New-ZcUndoResult $kind 'Tailscale node' 'tailscale logout' 'Skipped' 'CLI blocked by Tailscale GUI/IPC; revoke or remove the node in the admin console'))
                        } else {
                            [void]$results.Add((New-ZcUndoResult $kind 'Tailscale node' 'tailscale logout' 'Error' $r.Text.Trim()))
                        }
                    }
                }
            }
            'file.access-result' {
                $path = [string]$d.Path
                $marker = [string]$d.Marker
                if (-not (Test-Path -LiteralPath $path)) {
                    [void]$results.Add((New-ZcUndoResult $kind $path 'none' 'Skipped' 'file not present'))
                } else {
                    $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
                    if (-not $text -or $text.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                        [void]$results.Add((New-ZcUndoResult $kind $path 'delete file' 'Error' 'marker mismatch; not removed'))
                    } elseif ($DryRun) {
                        [void]$results.Add((New-ZcUndoResult $kind $path 'delete file' 'Planned' ''))
                    } else {
                        try {
                            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                            $detail = ''
                            if ($d.BackupPath -and (Test-Path -LiteralPath ([string]$d.BackupPath))) {
                                Move-Item -LiteralPath ([string]$d.BackupPath) -Destination $path -Force
                                $detail = 'backup restored'
                            }
                            [void]$results.Add((New-ZcUndoResult $kind $path 'delete file' 'Removed' $detail))
                        } catch {
                            [void]$results.Add((New-ZcUndoResult $kind $path 'delete file' 'Error' $_.Exception.Message))
                        }
                    }
                }
            }
            'file.config' {
                [void]$results.Add((New-ZcUndoResult $kind ([string]$d.Path) 'none' 'Skipped' 'config.json is user-editable and is not reverted automatically'))
            }
            default {
                [void]$results.Add((New-ZcUndoResult $kind '' 'none' 'Skipped' 'unknown change kind'))
            }
        }
    }

    $errors = @($results | Where-Object { $_.Status -eq 'Error' })
    if (-not $DryRun) {
        $Journal.UndoResults = @($results)
        if ($errors.Count -eq 0) { $Journal.Status = 'Undone' } else { $Journal.Status = 'UndoPartial' }
        Save-ZcJournal -Root $Root -Journal $Journal | Out-Null
    }
    return [pscustomobject]@{ Results = @($results); Errors = $errors; Status = $Journal.Status }
}

function Invoke-ZcUndoLocalJournal {
    param([string]$Root, $Journal, [switch]$DryRun)
    $results = New-Object System.Collections.ArrayList
    foreach ($c in @($Journal.Changes)) {
        $kind = [string]$c.Kind
        $d = $c.Data
        switch ($kind) {
            'trustedhosts' {
                $expected = [string]$d.ExpectedValue
                $prior = [string]$d.PriorValue
                $cur = ''
                try { $cur = [string](Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value } catch { $cur = '' }
                if ($cur -ne $expected) {
                    [void]$results.Add((New-ZcUndoResult $kind 'TrustedHosts' 'restore' 'Error' 'current value differs; not restored'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind 'TrustedHosts' 'restore' 'Planned' ''))
                } else {
                    try {
                        if ($prior) {
                            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $prior -Force
                        } else {
                            Set-Item WSMan:\localhost\Client\TrustedHosts -Value '' -Force
                        }
                        [void]$results.Add((New-ZcUndoResult $kind 'TrustedHosts' 'restore' 'Restored' ''))
                    } catch {
                        [void]$results.Add((New-ZcUndoResult $kind 'TrustedHosts' 'restore' 'Error' $_.Exception.Message))
                    }
                }
            }
            'file.profile' {
                $path = [string]$d.Path
                $marker = [string]$d.Marker
                if (-not (Test-Path -LiteralPath $path)) {
                    [void]$results.Add((New-ZcUndoResult $kind $path 'none' 'Skipped' 'file not present'))
                } else {
                    $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
                    if (-not $text -or $text.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                        [void]$results.Add((New-ZcUndoResult $kind $path 'delete file' 'Error' 'marker mismatch; not removed'))
                    } elseif ($DryRun) {
                        [void]$results.Add((New-ZcUndoResult $kind $path 'delete file' 'Planned' ''))
                    } else {
                        try {
                            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                            [void]$results.Add((New-ZcUndoResult $kind $path 'delete file' 'Removed' ''))
                        } catch {
                            [void]$results.Add((New-ZcUndoResult $kind $path 'delete file' 'Error' $_.Exception.Message))
                        }
                    }
                }
            }
            default {
                [void]$results.Add((New-ZcUndoResult $kind '' 'none' 'Skipped' 'unknown local change kind'))
            }
        }
    }
    $errors = @($results | Where-Object { $_.Status -eq 'Error' })
    if (-not $DryRun) {
        $Journal.UndoResults = @($results)
        if ($errors.Count -eq 0) { $Journal.Status = 'Undone' } else { $Journal.Status = 'UndoPartial' }
        Save-ZcJournal -Root $Root -Journal $Journal | Out-Null
    }
    return [pscustomobject]@{ Results = @($results); Errors = $errors; Status = $Journal.Status }
}

