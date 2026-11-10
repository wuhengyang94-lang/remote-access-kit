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

function Get-ZcBytesHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Initialize-ZcProfileBackupRoot {
    param([string]$Root)
    $path = Join-Path $Root 'profile-backups'
    if (-not (Test-Path -LiteralPath $path)) { [void][IO.Directory]::CreateDirectory($path) }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # Persist only the DACL; setting owner/SACL can require audit privileges.
    $acl = [IO.Directory]::GetAccessControl($path, [Security.AccessControl.AccessControlSections]::Access)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRuleSpecific($existing) }
    foreach ($principal in @($sid, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique) {
        $identity = New-Object Security.Principal.SecurityIdentifier($principal)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($path, $acl)
    return $path
}

function Write-ZcFileBytes {
    param([string]$Path, [byte[]]$Bytes)
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Save-ZcProfile {
    param([string]$Root, $Journal, [string]$Path, [string]$Content, [string]$Marker)
    if (-not $Root -or -not $Journal -or -not $Path -or -not $Marker) { throw 'Profile root, journal, path and marker are required.' }
    if ($Content.IndexOf($Marker, [StringComparison]::Ordinal) -lt 0) { throw 'Profile content must contain its run marker.' }
    $Root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ([IO.Directory]::Exists($fullPath)) { throw 'Profile destination must be a file.' }
    $existed = [IO.File]::Exists($fullPath)
    $backupPath = ''; $backupHash = ''
    if ($existed) {
        $backupRoot = Initialize-ZcProfileBackupRoot -Root $Root
        $backupPath = Join-Path $backupRoot ([guid]::NewGuid().ToString('N') + '.bin')
        $original = [IO.File]::ReadAllBytes($fullPath)
        $backupFile = [IO.File]::Open($backupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $backupFile.Write($original, 0, $original.Length) }
        finally { $backupFile.Dispose() }
        $backupHash = Get-ZcBytesHash -Bytes $original
    }
    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Content)
    # Persist ownership and the original bytes before replacing the destination.
    Add-ZcChange -Root $Root -Journal $Journal -Kind 'file.profile' -Data @{
        Path = $fullPath; Marker = $Marker; ExistedBefore = $existed
        BackupPath = $backupPath; BackupHash = $backupHash; ContentHash = (Get-ZcBytesHash -Bytes $bytes)
    } | Out-Null
    Write-ZcFileBytes -Path $fullPath -Bytes $bytes
    return $fullPath
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

function Get-ZcUndoCompletedIndexes {
    param($Journal)
    $completed = @($Journal.UndoCompleted | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    # Older journals used Undone even when optional Tailscale cleanup was kept.
    if (-not $Journal.PSObject.Properties['UndoCompleted'] -and [string]$Journal.Status -in @('Undone', 'RolledBack')) {
        for ($index = 0; $index -lt @($Journal.Changes).Count; $index++) {
            $kind = [string]$Journal.Changes[$index].Kind
            if ($kind -notin @('tailscale.install', 'tailscale.join') -or
                @($Journal.UndoResults | Where-Object { [string]$_.Kind -eq $kind -and [string]$_.Status -eq 'Removed' }).Count -gt 0) {
                $completed += $index
            }
        }
    }
    return @($completed | Select-Object -Unique)
}

function Get-ZcUndoChangeEntries {
    param($Journal, [switch]$TailscaleOnly)
    $completed = @(Get-ZcUndoCompletedIndexes -Journal $Journal)
    for ($index = 0; $index -lt @($Journal.Changes).Count; $index++) {
        if ($completed -contains $index) { continue }
        $change = $Journal.Changes[$index]
        if ($TailscaleOnly -and [string]$change.Kind -notin @('tailscale.install', 'tailscale.join')) { continue }
        if ([string]$change.Kind -eq 'tailscale.install' -and [bool]$change.Data.InstalledBefore) { continue }
        if ([string]$change.Kind -eq 'tailscale.join' -and -not [bool]$change.Data.JoinedByTool) { continue }
        [pscustomobject]@{ Index = $index; Change = $change }
    }
}

function Select-ZcUndoJournals {
    param([object[]]$Journals, [string]$RunId, [string]$SiteName, [switch]$All, [switch]$Latest, [switch]$RemoveTailscale, [switch]$UnjoinTailscale)
    $selectorCount = [int][bool]$RunId + [int][bool]$All + [int][bool]$Latest
    if ($selectorCount -gt 1) { throw '-RunId, -All and -Latest are mutually exclusive.' }
    $eligible = @()
    foreach ($journal in @($Journals)) {
        if ($RunId -and [string]$journal.RunId -ne $RunId) { continue }
        if ($SiteName -and [string]$journal.SiteName -ne $SiteName) { continue }
        $pending = @(Get-ZcUndoChangeEntries -Journal $journal | Where-Object {
            [string]$_.Change.Kind -notin @('tailscale.install', 'tailscale.join') -or
            ([string]$_.Change.Kind -eq 'tailscale.install' -and $RemoveTailscale) -or
            ([string]$_.Change.Kind -eq 'tailscale.join' -and $UnjoinTailscale)
        })
        if ($pending.Count -gt 0) { $eligible += $journal }
    }
    $eligible = @($eligible | Sort-Object CreatedUtc -Descending)
    if (-not $Latest) { return $eligible }
    $phases = @{}
    foreach ($journal in $eligible) {
        if ($phases.ContainsKey([string]$journal.Phase)) { continue }
        $phases[[string]$journal.Phase] = $true
        $journal
    }
}

function Complete-ZcUndoAttempt {
    param([string]$Root, $Journal, [object[]]$Results, [int[]]$Completed)
    $Journal | Add-Member -MemberType NoteProperty -Name UndoCompleted -Value @($Completed | Select-Object -Unique) -Force
    $Journal.UndoResults = @($Journal.UndoResults) + @($Results)
    $pending = @(Get-ZcUndoChangeEntries -Journal $Journal)
    if (@($Results | Where-Object { $_.Status -eq 'Error' }).Count -gt 0 -or
        @($pending | Where-Object { [string]$_.Change.Kind -notin @('tailscale.install', 'tailscale.join') }).Count -gt 0) { $Journal.Status = 'UndoPartial' }
    elseif ($pending.Count -gt 0) { $Journal.Status = 'UndoneOptional' }
    else { $Journal.Status = 'Undone' }
    Save-ZcJournal -Root $Root -Journal $Journal | Out-Null
}

function Get-ZcUndoFileState {
    param([string]$Path, [hashtable]$PlanState, [switch]$DryRun)
    if ($DryRun -and $null -ne $PlanState -and $PlanState.Files.ContainsKey($Path)) { return $PlanState.Files[$Path] }
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ Exists = $false; Bytes = [byte[]]@() } }
    return [pscustomobject]@{ Exists = $true; Bytes = [IO.File]::ReadAllBytes($Path) }
}

function Get-ZcUndoRegState {
    param([string]$Path, [string]$Name, [hashtable]$PlanState, [switch]$DryRun)
    $key = $Path + '|' + $Name
    if ($DryRun -and $null -ne $PlanState -and $PlanState.Registry.ContainsKey($key)) { return $PlanState.Registry[$key] }
    return (Get-ZcRegState -Path $Path -Name $Name)
}

function Set-ZcUndoRegPlan {
    param([hashtable]$PlanState, [string]$Path, [string]$Name, $Value, [bool]$Exists)
    if ($null -ne $PlanState) { $PlanState.Registry[$Path + '|' + $Name] = [pscustomobject]@{ Exists = $Exists; Value = $Value } }
}

function Initialize-ZcUndoPlanState {
    param([hashtable]$PlanState)
    if ($null -eq $PlanState) { $PlanState = @{} }
    foreach ($key in @('Files', 'Registry', 'DeletedByUndo')) { if (-not $PlanState.ContainsKey($key)) { $PlanState[$key] = @{} } }
    return $PlanState
}

function Invoke-ZcUndoFileChange {
    param([string]$Root, $Change, [hashtable]$PlanState, [switch]$DryRun)
    $kind = [string]$Change.Kind; $d = $Change.Data
    $path = [string]$d.Path; $marker = [string]$d.Marker; $backup = [string]$d.BackupPath
    $restore = [bool]$d.ExistedBefore -or [bool]$backup
    $action = 'delete file'
    if ($restore) { $action = 'restore file' }
    try {
        $file = Get-ZcUndoFileState -Path $path -PlanState $PlanState -DryRun:$DryRun
        if (-not $file.Exists) {
            if (-not $restore) { return (New-ZcUndoResult $kind $path 'none' 'Skipped' 'file not present') }
            # Legacy access-result journals did not back up an older tool file.
            # Only a deletion proven in this same undo permits the older backup.
            if (-not $PlanState.DeletedByUndo[$path]) { throw 'file missing; backup not restored without undo ownership' }
        } else {
            $current = [byte[]]$file.Bytes
            $currentHash = Get-ZcBytesHash -Bytes $current
            if ($restore -and $d.BackupHash -and $currentHash -eq [string]$d.BackupHash) {
                if ($DryRun) { $PlanState.Files[$path] = $file }
                $PlanState.DeletedByUndo[$path] = $false
                return (New-ZcUndoResult $kind $path 'none' 'Skipped' 'original content already present')
            }
            $text = [Text.Encoding]::UTF8.GetString($current)
            if (-not $marker -or $text.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) { throw 'marker mismatch; not changed' }
            if ($d.ContentHash -and $currentHash -ne [string]$d.ContentHash) { throw 'file content changed; not changed' }
        }
        $original = $null
        if ($restore) {
            if ($kind -eq 'file.profile') {
                $backupPrefix = [IO.Path]::GetFullPath((Join-Path $Root 'profile-backups')).TrimEnd('\') + '\'
                if (-not $backup -or -not [IO.Path]::GetFullPath($backup).StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'invalid profile backup path; not changed' }
            }
            if (-not [IO.File]::Exists($backup)) { throw 'file backup missing; not changed' }
            $original = [IO.File]::ReadAllBytes($backup)
            if (($kind -eq 'file.profile' -or $d.ContentHash -or $d.BackupHash) -and
                (-not $d.BackupHash -or (Get-ZcBytesHash -Bytes $original) -ne [string]$d.BackupHash)) { throw 'file backup hash mismatch; not changed' }
        }
        if ($DryRun) {
            $PlanState.Files[$path] = [pscustomobject]@{ Exists = $restore; Bytes = $original }
            $PlanState.DeletedByUndo[$path] = -not $restore
            return (New-ZcUndoResult $kind $path $action 'Planned' '')
        }
        if ($restore) {
            Write-ZcFileBytes -Path $path -Bytes $original
            $PlanState.DeletedByUndo[$path] = $false
            return (New-ZcUndoResult $kind $path $action 'Restored' 'original bytes restored')
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        $PlanState.DeletedByUndo[$path] = $true
        return (New-ZcUndoResult $kind $path $action 'Removed' '')
    } catch { return (New-ZcUndoResult $kind $path $action 'Error' $_.Exception.Message) }
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
        [switch]$UnjoinTailscale,
        [switch]$TailscaleOnly,
        [hashtable]$PlanState
    )
    if ($Journal.HostName -ne $env:COMPUTERNAME) {
        throw "Journal belongs to '$($Journal.HostName)', not '$env:COMPUTERNAME'. Run undo on the correct host."
    }
    $PlanState = Initialize-ZcUndoPlanState -PlanState $PlanState
    if ($Journal.Phase -eq 'local') { return (Invoke-ZcUndoLocalJournal -Root $Root -Journal $Journal -DryRun:$DryRun -TailscaleOnly:$TailscaleOnly -PlanState $PlanState) }

    $results = New-Object System.Collections.ArrayList
    $completed = @(Get-ZcUndoCompletedIndexes -Journal $Journal)
    # Log out before uninstalling, and keep run-file backups until restores end.
    $allChanges = @(Get-ZcUndoChangeEntries -Journal $Journal -TailscaleOnly:$TailscaleOnly)
    $orderedChanges = @(@($allChanges | Where-Object { [string]$_.Change.Kind -notin @('tailscale.install', 'tempdir') })) +
                      @(@($allChanges | Where-Object { [string]$_.Change.Kind -eq 'tailscale.install' })) +
                      @(@($allChanges | Where-Object { [string]$_.Change.Kind -eq 'tempdir' }))
    foreach ($entry in $orderedChanges) {
        $c = $entry.Change
        $resultStart = $results.Count
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
                $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
                $targetPath = ''
                if ($path) { $targetPath = [IO.Path]::GetFullPath($path) }
                if (@($results | Where-Object { $_.Status -eq 'Error' }).Count -gt 0) {
                    [void]$results.Add((New-ZcUndoResult $kind $path 'keep directory' 'Error' 'run files retained because undo is incomplete'))
                } elseif ($targetPath -and $targetPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $targetPath)) {
                    if ($DryRun) {
                        [void]$results.Add((New-ZcUndoResult $kind $path 'delete directory' 'Planned' ''))
                    } else {
                        try {
                            Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction Stop
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
                $cur = Get-ZcUndoRegState -Path $path -Name $name -PlanState $PlanState -DryRun:$DryRun
                if ($cur.Exists -and [string]$cur.Value -ne [string]$d.ValueSet) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Error' 'current value differs; not restored'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Planned' ''))
                    Set-ZcUndoRegPlan -PlanState $PlanState -Path $path -Name $name -Value $d.ValueBefore -Exists ([bool]$d.ExistedBefore)
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
                $cur = Get-ZcUndoRegState -Path $path -Name $name -PlanState $PlanState -DryRun:$DryRun
                $curText = (@($cur.Value) -join "`n")
                $setText = (@($d.ValueSet) -join "`n")
                if ($cur.Exists -and $curText -ne $setText) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Error' 'current value differs; not restored'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind $name 'restore registry' 'Planned' ''))
                    Set-ZcUndoRegPlan -PlanState $PlanState -Path $path -Name $name -Value $d.ValueBefore -Exists ([bool]$d.ExistedBefore)
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
                } elseif ($UnjoinTailscale -and ($PlanState.TailscaleLogoutBlocked -or @($results | Where-Object { $_.Kind -eq 'tailscale.join' -and $_.Status -in @('Error', 'Skipped') }).Count -gt 0)) {
                    [void]$results.Add((New-ZcUndoResult $kind 'Tailscale' 'uninstall MSI' 'Error' 'logout did not complete; Tailscale was not uninstalled'))
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
                            [void]$results.Add((New-ZcUndoResult $kind 'Tailscale node' 'tailscale logout' 'Error' 'CLI blocked by Tailscale GUI/IPC; retry logout or revoke the node in the admin console'))
                        } else {
                            [void]$results.Add((New-ZcUndoResult $kind 'Tailscale node' 'tailscale logout' 'Error' $r.Text.Trim()))
                        }
                    }
                }
            }
            'file.access-result' {
                [void]$results.Add((Invoke-ZcUndoFileChange -Root $Root -Change $c -PlanState $PlanState -DryRun:$DryRun))
            }
            'file.config' {
                [void]$results.Add((New-ZcUndoResult $kind ([string]$d.Path) 'none' 'Skipped' 'config.json is user-editable and is not reverted automatically'))
            }
            default {
                [void]$results.Add((New-ZcUndoResult $kind '' 'none' 'Skipped' 'unknown change kind'))
            }
        }
        $changeResults = @($results | Select-Object -Skip $resultStart)
        if ($kind -eq 'tailscale.join' -and $UnjoinTailscale -and @($changeResults | Where-Object { $_.Status -in @('Error', 'Skipped') }).Count -gt 0) { $PlanState.TailscaleLogoutBlocked = $true }
        foreach ($item in $changeResults) { $item | Add-Member -MemberType NoteProperty -Name ChangeIndex -Value ([int]$entry.Index) }
        $done = $changeResults.Count -gt 0 -and @($changeResults | Where-Object { $_.Status -in @('Error', 'Planned') }).Count -eq 0
        if ($kind -in @('tailscale.install', 'tailscale.join')) { $done = @($changeResults | Where-Object { $_.Status -eq 'Removed' }).Count -gt 0 }
        if (-not $DryRun -and $done) { $completed += [int]$entry.Index }
    }

    $errors = @($results | Where-Object { $_.Status -eq 'Error' })
    if (-not $DryRun) {
        Complete-ZcUndoAttempt -Root $Root -Journal $Journal -Results @($results) -Completed $completed
    }
    return [pscustomobject]@{ Results = @($results); Errors = $errors; Status = $Journal.Status }
}

function Invoke-ZcUndoLocalJournal {
    param([string]$Root, $Journal, [switch]$DryRun, [switch]$TailscaleOnly, [hashtable]$PlanState)
    $PlanState = Initialize-ZcUndoPlanState -PlanState $PlanState
    $results = New-Object System.Collections.ArrayList
    $completed = @(Get-ZcUndoCompletedIndexes -Journal $Journal)
    $entries = @(Get-ZcUndoChangeEntries -Journal $Journal -TailscaleOnly:$TailscaleOnly | Sort-Object Index -Descending)
    foreach ($entry in $entries) {
        $c = $entry.Change
        $resultStart = $results.Count
        $kind = [string]$c.Kind
        $d = $c.Data
        switch ($kind) {
            'trustedhosts' {
                $expected = [string]$d.ExpectedValue
                $prior = [string]$d.PriorValue
                $cur = ''
                if ($DryRun -and $PlanState.ContainsKey('TrustedHosts')) { $cur = [string]$PlanState.TrustedHosts }
                else { try { $cur = [string](Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value } catch { $cur = '' } }
                if ($cur -ne $expected) {
                    [void]$results.Add((New-ZcUndoResult $kind 'TrustedHosts' 'restore' 'Error' 'current value differs; not restored'))
                } elseif ($DryRun) {
                    [void]$results.Add((New-ZcUndoResult $kind 'TrustedHosts' 'restore' 'Planned' ''))
                    $PlanState.TrustedHosts = $prior
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
                [void]$results.Add((Invoke-ZcUndoFileChange -Root $Root -Change $c -PlanState $PlanState -DryRun:$DryRun))
            }
            default {
                [void]$results.Add((New-ZcUndoResult $kind '' 'none' 'Skipped' 'unknown local change kind'))
            }
        }
        $changeResults = @($results | Select-Object -Skip $resultStart)
        foreach ($item in $changeResults) { $item | Add-Member -MemberType NoteProperty -Name ChangeIndex -Value ([int]$entry.Index) }
        if (-not $DryRun -and $changeResults.Count -gt 0 -and @($changeResults | Where-Object { $_.Status -in @('Error', 'Planned') }).Count -eq 0) { $completed += [int]$entry.Index }
    }
    $errors = @($results | Where-Object { $_.Status -eq 'Error' })
    if (-not $DryRun) {
        Complete-ZcUndoAttempt -Root $Root -Journal $Journal -Results @($results) -Completed $completed
    }
    return [pscustomobject]@{ Results = @($results); Errors = $errors; Status = $Journal.Status }
}

