#Requires -Version 5.1
# Offline recovery tests. Real I/O is limited to uniquely named TEMP files.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'zc-state.ps1')
$script:Pass = 0
$script:Failures = New-Object System.Collections.ArrayList
$tmp = Join-Path $env:TEMP ('zcode-recovery-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tmp)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT: $Message" }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Pass++; Write-Host "PASS $Name" }
    catch { [void]$script:Failures.Add($Name + ': ' + $_.Exception.Message); Write-Host ("FAIL {0}: {1}" -f $Name, $_.Exception.Message) }
}
function New-OfflineJournal([string]$Id, [string]$Phase = 'local', [string]$Site = 'lab', [string]$Date = '2026-11-10T01:00:00Z') {
    $j = New-ZcJournal -Phase $Phase -SiteName $Site -HostName $env:COMPUTERNAME -RunId $Id
    $j.Status = 'Applied'; $j.CreatedUtc = $Date
    return $j
}
function Save-OfflineProfile($Journal, [string]$Path, [string]$Content) {
    $marker = 'ZCodeRemoteAccess:RunId=' + $Journal.RunId
    if (Get-Command Save-ZcProfile -ErrorAction SilentlyContinue) {
        Save-ZcProfile -Root $tmp -Journal $Journal -Path $Path -Content $Content -Marker $marker | Out-Null
        return
    }
    # Exercise the existing production writer for the initial behavior RED.
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root '02-connect-site.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    $writer = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$ProfilePath -and -not $VerifyOnly' }, $true))
    if ($writer.Count -ne 1) { throw 'Expected the current production profile writer.' }
    $localRoot = $tmp; $localJournal = $Journal; $ProfilePath = $Path; $profile = $Content; $runId = $Journal.RunId
    function Write-Ok([string]$Text) { }
    $body = ($writer[0].Clauses[0].Item2.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"
    & ([scriptblock]::Create($body))
}

# No initialization, native executable, network, account or registry is used.
function Initialize-ZcProfileBackupRoot([string]$Root) {
    $directory = Join-Path $Root 'profile-backups'
    [void][IO.Directory]::CreateDirectory($directory)
    return $directory
}
function Invoke-Command { throw 'NETWORK ACCESS IS FORBIDDEN IN THESE TESTS.' }
function Get-ZcRegState { param([string]$Path, [string]$Name) $script:RegistryReads++; return [pscustomobject]@{ Exists = $true; Value = 1 } }
function Set-ZcRegState { param([string]$Path, [string]$Name, $Value, [bool]$Exists) $script:RegistryWrites++ }
function Get-ZcLocalUserState { throw 'ACCOUNT ACCESS IS FORBIDDEN IN THESE TESTS.' }
function Get-Item {
    [CmdletBinding()] param([string]$Path)
    if ($Path -ne 'WSMan:\localhost\Client\TrustedHosts') { throw "UNMOCKED Get-Item: $Path" }
    $script:TrustedHostReads++
    return [pscustomobject]@{ Value = $script:TrustedHosts }
}
function Set-Item {
    [CmdletBinding()] param([string]$Path, [string]$Value, [switch]$Force)
    if ($Path -ne 'WSMan:\localhost\Client\TrustedHosts') { throw "UNMOCKED Set-Item: $Path" }
    $script:TrustedHosts = $Value
}
function Invoke-ZcNative {
    param([string]$FilePath, [string[]]$Arguments)
    [void]$script:Calls.Add($FilePath)
    return [pscustomobject]@{ ExitCode = 0; Output = '' }
}
function Invoke-ZcTailscaleLogout {
    param([string]$Exe, [int]$TimeoutSec)
    [void]$script:Calls.Add('logout')
    if ($script:LogoutBlocked) { return [pscustomobject]@{ ExitCode = -1; Text = 'TIMEOUT' } }
    if ($script:LogoutFails) { return [pscustomobject]@{ ExitCode = 1; Text = 'simulated logout failure' } }
    return [pscustomobject]@{ ExitCode = 0; Text = '' }
}
function Test-Path {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Path, [string]$PathType)
    if ($LiteralPath -like '*\Tailscale\tailscale.exe') { return $true }
    return (Microsoft.PowerShell.Management\Test-Path @PSBoundParameters)
}
function New-TailscaleJournal([string]$Id) {
    $j = New-OfflineJournal $Id 'site'
    $j.Changes = @(
        [pscustomobject]@{ Kind = 'registry.latfp'; Data = [pscustomobject]@{ Path = 'HKLM:\TEST'; Name = 'Value'; ValueSet = 1; ExistedBefore = $false; ValueBefore = $null } },
        [pscustomobject]@{ Kind = 'tailscale.install'; Data = [pscustomobject]@{ InstalledBefore = $false; ProductCode = '{OFFLINE-TEST}' } },
        [pscustomobject]@{ Kind = 'tailscale.join'; Data = [pscustomobject]@{ JoinedByTool = $true } }
    )
    return $j
}

try {
    Test-Case 'default undo does not let an empty rerun hide an older owned profile' {
        $j = New-OfflineJournal 'local-old'
        $p = Join-Path $tmp 'older.md'
        [IO.File]::WriteAllText($p, 'ZCodeRemoteAccess:RunId=local-old')
        Add-ZcChange -Root $tmp -Journal $j -Kind 'file.profile' -Data @{ Path = $p; Marker = 'ZCodeRemoteAccess:RunId=local-old' } | Out-Null
        $empty = New-OfflineJournal 'local-empty' 'local' 'lab' '2026-11-10T02:00:00Z'
        Save-ZcJournal -Root $tmp -Journal $empty | Out-Null
        $output = & powershell.exe -NoProfile -NonInteractive -File (Join-Path $root '03-undo.ps1') -Scope Local -LocalStateRoot $tmp -DryRun 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) 'Offline dry run must execute successfully.'
        Assert-True ($output -match '\[Planned\] file.profile') 'Default undo must plan the older owned profile beneath an empty rerun.'
    }
    Test-Case 'keeping Tailscale leaves an explicit optional cleanup state' {
        $script:RegistryReads = 0; $script:RegistryWrites = 0; $script:Calls = New-Object System.Collections.ArrayList
        $j = New-TailscaleJournal 'site-kept'
        $original = ConvertTo-Json -InputObject $j.Changes -Depth 8 -Compress
        $result = Invoke-ZcUndoJournal -Root $tmp -Journal $j
        Assert-True ($result.Status -eq 'UndoneOptional') 'Kept tool-owned Tailscale must remain eligible for later optional cleanup.'
        Assert-True ((ConvertTo-Json -InputObject $j.Changes -Depth 8 -Compress) -eq $original) 'Undo must retain the original ownership evidence.'
    }
    Test-Case 'historical Undone journals clean Tailscale without replaying registry changes' {
        $script:RegistryReads = 0; $script:RegistryWrites = 0; $script:Calls = New-Object System.Collections.ArrayList
        $j = New-TailscaleJournal 'site-historical'; $j.Status = 'Undone'
        $result = Invoke-ZcUndoJournal -Root $tmp -Journal $j -RemoveTailscale -UnjoinTailscale
        Assert-True ($script:RegistryReads -eq 0 -and $script:RegistryWrites -eq 0) 'A later optional cleanup must never replay registry restoration.'
        Assert-True (($script:Calls -join ',') -eq 'logout,msiexec.exe') 'Logout must precede uninstall.'
        $script:Calls.Clear()
        $again = Invoke-ZcUndoJournal -Root $tmp -Journal $j -RemoveTailscale -UnjoinTailscale
        Assert-True ($script:Calls.Count -eq 0) 'Completed optional cleanup must be idempotent.'
    }
    Test-Case 'profile undo restores preexisting bytes instead of losing the file' {
        $j = New-OfflineJournal 'local-replace'
        $p = Join-Path $tmp 'existing.md'
        $before = [byte[]]@(255,254,65,0,13,0,10,0)
        [IO.File]::WriteAllBytes($p, $before)
        Save-OfflineProfile $j $p '<!-- ZCodeRemoteAccess:RunId=local-replace --> new'
        $result = Invoke-ZcUndoLocalJournal -Root $tmp -Journal $j
        Assert-True ([IO.File]::Exists($p)) 'Undo must restore the original profile file.'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) -eq [Convert]::ToBase64String($before)) 'Undo must restore the exact original bytes.'
    }
    Test-Case 'default preview and undo follow a multi-run profile restore chain' {
        $stackRoot = Join-Path $tmp 'profile-stack'
        [void][IO.Directory]::CreateDirectory($stackRoot)
        $p = Join-Path $stackRoot 'repeated[1].md'
        [IO.File]::WriteAllBytes($p, [byte[]]@(1,2,3,4))
        $one = New-OfflineJournal 'local-stack-one'
        $two = New-OfflineJournal 'local-stack-two' 'local' 'lab' '2026-11-10T02:00:00Z'
        Save-ZcProfile -Root $stackRoot -Journal $one -Path $p -Content 'ZCodeRemoteAccess:RunId=local-stack-one' -Marker 'ZCodeRemoteAccess:RunId=local-stack-one' | Out-Null
        Save-ZcProfile -Root $stackRoot -Journal $two -Path $p -Content 'ZCodeRemoteAccess:RunId=local-stack-two' -Marker 'ZCodeRemoteAccess:RunId=local-stack-two' | Out-Null
        $output = & powershell.exe -NoProfile -NonInteractive -File (Join-Path $root '03-undo.ps1') -Scope Local -LocalStateRoot $stackRoot -DryRun 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) ('A valid profile chain must preview without ownership errors: ' + $output)
        Assert-True (([regex]::Matches($output, '\[Planned\] file.profile')).Count -eq 2) 'Both restore operations must be planned.'
        $output = & powershell.exe -NoProfile -NonInteractive -File (Join-Path $root '03-undo.ps1') -Scope Local -LocalStateRoot $stackRoot -Force 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) ('The valid profile chain must undo: ' + $output)
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) -eq 'AQIDBA==') 'All runs must restore the original bytes.'
    }
    Test-Case 'legacy access-result history restores an original backup after an owned deletion' {
        $stackRoot = Join-Path $tmp 'access-stack'
        [void][IO.Directory]::CreateDirectory($stackRoot)
        $p = Join-Path $stackRoot 'access-result.txt'; $backup = $p + '.backup'
        [IO.File]::WriteAllText($backup, 'original access file')
        [IO.File]::WriteAllText($p, 'GeneratedBy=site-access-two')
        $one = New-OfflineJournal 'site-access-one' 'site'
        $one.Changes = @([pscustomobject]@{ Kind = 'file.access-result'; Data = [pscustomobject]@{ Path = $p; Marker = 'GeneratedBy=site-access-one'; BackupPath = $backup } })
        $two = New-OfflineJournal 'site-access-two' 'site' 'lab' '2026-11-10T02:00:00Z'
        $two.Changes = @([pscustomobject]@{ Kind = 'file.access-result'; Data = [pscustomobject]@{ Path = $p; Marker = 'GeneratedBy=site-access-two'; BackupPath = '' } })
        foreach ($journal in @($one, $two)) { Save-ZcJournal -Root $stackRoot -Journal $journal | Out-Null }
        $output = & powershell.exe -NoProfile -NonInteractive -File (Join-Path $root '03-undo.ps1') -Scope Site -StateRoot $stackRoot -DryRun 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) ('Legacy history with an owned deletion must preview: ' + $output)
        $output = & powershell.exe -NoProfile -NonInteractive -File (Join-Path $root '03-undo.ps1') -Scope Site -StateRoot $stackRoot -Force 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0 -and [IO.File]::Exists($p)) ('Legacy history must restore the old backup: ' + $output)
        Assert-True ([IO.File]::ReadAllText($p) -eq 'original access file') 'The original access file bytes must survive full history undo.'
    }
    Test-Case 'selection includes all pending runs in descending order and filters sites' {
        $one = New-OfflineJournal 'select-one' 'connect' 'lab' '2026-11-10T01:00:00Z'
        $two = New-OfflineJournal 'select-two' 'connect' 'other' '2026-11-10T02:00:00Z'
        $three = New-OfflineJournal 'select-three' 'site' 'lab' '2026-11-10T03:00:00Z'
        foreach ($journal in @($one, $two, $three)) { $journal.Changes = @([pscustomobject]@{ Kind = 'firewall.rule'; Data = @{ Name = 'test' } }) }
        $selected = @(Select-ZcUndoJournals -Journals @($one, $two, $three))
        Assert-True (($selected.RunId -join ',') -eq 'select-three,select-two,select-one') 'The default must include all pending runs, newest first.'
        $selected = @(Select-ZcUndoJournals -Journals @($one, $two, $three) -SiteName 'lab')
        Assert-True (($selected.RunId -join ',') -eq 'select-three,select-one') 'Site filtering must be exact and preserve order.'
    }
    Test-Case 'Latest selects pending nonempty runs before grouping by phase' {
        $one = New-OfflineJournal 'latest-one' 'connect'
        $two = New-OfflineJournal 'latest-empty' 'connect' 'lab' '2026-11-10T02:00:00Z'
        $three = New-OfflineJournal 'latest-undone' 'connect' 'lab' '2026-11-10T03:00:00Z'
        foreach ($journal in @($one, $three)) { $journal.Changes = @([pscustomobject]@{ Kind = 'firewall.rule'; Data = @{ Name = 'test' } }) }
        $three.Status = 'Undone'
        $selected = @(Select-ZcUndoJournals -Journals @($one, $two, $three) -Latest)
        Assert-True ($selected.Count -eq 1 -and $selected[0].RunId -eq 'latest-one') 'An empty or completed newer run must not hide an older pending run.'
        $historical = New-TailscaleJournal 'latest-optional'; $historical.Status = 'Undone'
        $selected = @(Select-ZcUndoJournals -Journals @($historical) -RunId 'latest-optional' -RemoveTailscale -UnjoinTailscale)
        Assert-True ($selected.Count -eq 1) 'Historical Undone must remain selectable for optional cleanup.'
    }
    Test-Case 'mutually exclusive selectors fail before planning' {
        foreach ($arguments in @(@{ RunId = 'x'; Latest = $true }, @{ RunId = 'x'; All = $true }, @{ Latest = $true; All = $true })) {
            $message = ''
            try { Select-ZcUndoJournals -Journals @() @arguments | Out-Null } catch { $message = $_.Exception.Message }
            Assert-True ($message -match 'mutually exclusive') 'Every selector combination must be rejected.'
        }
    }
    Test-Case 'profile content changed by a user is retained and makes preview fail' {
        $state = Join-Path $tmp 'changed-profile'; [void][IO.Directory]::CreateDirectory($state)
        $p = Join-Path $state 'profile.md'; $j = New-OfflineJournal 'local-changed'
        Save-ZcProfile -Root $state -Journal $j -Path $p -Content 'ZCodeRemoteAccess:RunId=local-changed' -Marker 'ZCodeRemoteAccess:RunId=local-changed' | Out-Null
        [IO.File]::AppendAllText($p, ' user edit')
        $before = [IO.File]::ReadAllText($p)
        $result = Invoke-ZcUndoLocalJournal -Root $state -Journal $j
        Assert-True ($result.Errors.Count -eq 1 -and [IO.File]::ReadAllText($p) -eq $before) 'A marker must not bypass the generated content hash.'
        $output = & powershell.exe -NoProfile -NonInteractive -File (Join-Path $root '03-undo.ps1') -Scope Local -LocalStateRoot $state -DryRun 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 1 -and $output -match '\[Error\] file.profile') 'An unsafe dry run must return a nonzero exit code.'
    }
    Test-Case 'changed or missing profile backups never overwrite the generated file' {
        foreach ($mode in @('changed', 'missing')) {
            $j = New-OfflineJournal ('local-backup-' + $mode); $p = Join-Path $tmp ('backup-' + $mode + '.md')
            [IO.File]::WriteAllText($p, 'original')
            $marker = 'ZCodeRemoteAccess:RunId=' + $j.RunId
            Save-ZcProfile -Root $tmp -Journal $j -Path $p -Content $marker -Marker $marker | Out-Null
            $backup = [string]$j.Changes[0].Data.BackupPath
            if ($mode -eq 'changed') { [IO.File]::WriteAllText($backup, 'changed backup') } else { [IO.File]::Delete($backup) }
            $result = Invoke-ZcUndoLocalJournal -Root $tmp -Journal $j
            Assert-True ($result.Errors.Count -eq 1 -and [IO.File]::ReadAllText($p) -eq $marker) 'An unavailable or changed backup must preserve the current profile.'
        }
    }
    Test-Case 'new profiles are removed and historical marker-only profiles remain compatible' {
        $j = New-OfflineJournal 'local-new'; $p = Join-Path $tmp 'new-profile.md'
        Save-ZcProfile -Root $tmp -Journal $j -Path $p -Content 'ZCodeRemoteAccess:RunId=local-new' -Marker 'ZCodeRemoteAccess:RunId=local-new' | Out-Null
        $result = Invoke-ZcUndoLocalJournal -Root $tmp -Journal $j
        Assert-True ($result.Errors.Count -eq 0 -and -not [IO.File]::Exists($p)) 'An owned profile without an original file must be deleted.'
        $legacy = New-OfflineJournal 'local-legacy'; $p = Join-Path $tmp 'legacy-profile.md'
        [IO.File]::WriteAllText($p, 'ZCodeRemoteAccess:RunId=local-legacy')
        $legacy.Changes = @([pscustomobject]@{ Kind = 'file.profile'; Data = @{ Path = $p; Marker = 'ZCodeRemoteAccess:RunId=local-legacy' } })
        $result = Invoke-ZcUndoLocalJournal -Root $tmp -Journal $legacy
        Assert-True ($result.Errors.Count -eq 0 -and -not [IO.File]::Exists($p)) 'Old profile entries without backup fields must remain usable.'
    }
    Test-Case 'TrustedHosts preview projects each successful restoration' {
        $script:TrustedHosts = 'A,B'; $script:TrustedHostReads = 0
        $one = New-OfflineJournal 'trusted-one'; $two = New-OfflineJournal 'trusted-two'
        $one.Changes = @([pscustomobject]@{ Kind = 'trustedhosts'; Data = @{ PriorValue = ''; ExpectedValue = 'A' } })
        $two.Changes = @([pscustomobject]@{ Kind = 'trustedhosts'; Data = @{ PriorValue = 'A'; ExpectedValue = 'A,B' } })
        $context = @{}
        $new = Invoke-ZcUndoLocalJournal -Root $tmp -Journal $two -DryRun -PlanState $context
        $old = Invoke-ZcUndoLocalJournal -Root $tmp -Journal $one -DryRun -PlanState $context
        Assert-True ($new.Errors.Count -eq 0 -and $old.Errors.Count -eq 0 -and $context.TrustedHosts -eq '') 'A valid TrustedHosts stack must preview successfully.'
        Assert-True ($script:TrustedHostReads -eq 1 -and $script:TrustedHosts -eq 'A,B') 'Projection must not change real TrustedHosts.'
        Invoke-ZcUndoLocalJournal -Root $tmp -Journal $two | Out-Null
        Invoke-ZcUndoLocalJournal -Root $tmp -Journal $one | Out-Null
        Assert-True ($script:TrustedHosts -eq '') 'Execution must restore TrustedHosts in the same order.'
    }
    Test-Case 'existing Tailscale ownership and explicit TailscaleOnly are preserved' {
        $script:Calls = New-Object System.Collections.ArrayList; $script:RegistryReads = 0; $script:RegistryWrites = 0
        $j = New-TailscaleJournal 'site-existing'
        $j.Changes[1].Data.InstalledBefore = $true; $j.Changes[2].Data.JoinedByTool = $false
        $result = Invoke-ZcUndoJournal -Root $tmp -Journal $j -TailscaleOnly -RemoveTailscale -UnjoinTailscale
        Assert-True ($script:Calls.Count -eq 0 -and $script:RegistryReads -eq 0) 'Existing Tailscale and non-Tailscale changes must be untouched.'
        Assert-True ($result.Status -eq 'UndoPartial') 'Unprocessed base changes must remain pending.'
    }
    Test-Case 'failed logout blocks an uninstall owned by an older run' {
        $script:Calls = New-Object System.Collections.ArrayList; $script:LogoutFails = $true
        try {
            $join = New-OfflineJournal 'split-join' 'site'
            $install = New-OfflineJournal 'split-install' 'site'
            $join.Changes = @([pscustomobject]@{ Kind = 'tailscale.join'; Data = @{ JoinedByTool = $true } })
            $install.Changes = @([pscustomobject]@{ Kind = 'tailscale.install'; Data = @{ InstalledBefore = $false; ProductCode = '{OFFLINE-TEST}' } })
            $context = @{}
            $new = Invoke-ZcUndoJournal -Root $tmp -Journal $join -RemoveTailscale -UnjoinTailscale -PlanState $context
            $old = Invoke-ZcUndoJournal -Root $tmp -Journal $install -RemoveTailscale -UnjoinTailscale -PlanState $context
            Assert-True ($new.Errors.Count -eq 1 -and $old.Errors.Count -eq 1) 'Logout failure must propagate across selected runs.'
            Assert-True (($script:Calls -join ',') -eq 'logout') 'MSI must not be uninstalled after a failed cross-run logout.'
        } finally { $script:LogoutFails = $false }
    }
    Test-Case 'legacy missing access-result requires a proven undo deletion' {
        $j = New-OfflineJournal 'access-missing' 'site'; $p = Join-Path $tmp 'missing-access.txt'; $backup = $p + '.backup'
        [IO.File]::WriteAllText($backup, 'original')
        $j.Changes = @([pscustomobject]@{ Kind = 'file.access-result'; Data = @{ Path = $p; Marker = 'GeneratedBy=access-missing'; BackupPath = $backup } })
        $result = Invoke-ZcUndoJournal -Root $tmp -Journal $j
        Assert-True ($result.Errors.Count -eq 1 -and -not [IO.File]::Exists($p)) 'A missing file outside an owned undo chain must not be recreated.'
    }
    Test-Case 'registry preview projects successive prior values without writing the registry' {
        $script:RegistryReads = 0; $script:RegistryWrites = 0
        $one = New-TailscaleJournal 'registry-one'; $one.Changes = @($one.Changes[0]); $one.Changes[0].Data.ValueSet = 2
        $two = New-TailscaleJournal 'registry-two'; $two.Changes = @($two.Changes[0]); $two.Changes[0].Data.ValueBefore = 2; $two.Changes[0].Data.ExistedBefore = $true
        $context = @{}
        $new = Invoke-ZcUndoJournal -Root $tmp -Journal $two -DryRun -PlanState $context
        $old = Invoke-ZcUndoJournal -Root $tmp -Journal $one -DryRun -PlanState $context
        Assert-True ($new.Errors.Count -eq 0 -and $old.Errors.Count -eq 0) 'A valid registry restore chain must preview using projected values.'
        Assert-True ($script:RegistryReads -eq 1 -and $script:RegistryWrites -eq 0) 'Registry projection must remain in memory.'
    }
    Test-Case 'historical successful failure rollback keeps only optional cleanup pending' {
        $script:RegistryReads = 0; $script:RegistryWrites = 0; $script:Calls = New-Object System.Collections.ArrayList
        $j = New-TailscaleJournal 'site-rolledback'; $j.Status = 'RolledBack'
        $result = Invoke-ZcUndoJournal -Root $tmp -Journal $j -RemoveTailscale -UnjoinTailscale
        Assert-True ($script:RegistryReads -eq 0 -and $script:RegistryWrites -eq 0 -and $result.Errors.Count -eq 0) 'Historical successful rollback must not replay completed base changes.'
    }
    Test-Case 'run directory cleanup happens after restoring its access-result backup' {
        $runDir = Join-Path $tmp 'run-files'; [void][IO.Directory]::CreateDirectory($runDir)
        $backup = Join-Path $runDir 'access.bak'; $p = Join-Path $tmp 'run-access.txt'
        [IO.File]::WriteAllText($backup, 'original access')
        [IO.File]::WriteAllText($p, 'GeneratedBy=run-cleanup')
        $j = New-OfflineJournal 'run-cleanup' 'site'
        $j.Changes = @(
            [pscustomobject]@{ Kind = 'tempdir'; Data = @{ Path = $runDir } },
            [pscustomobject]@{ Kind = 'file.access-result'; Data = @{ Path = $p; Marker = 'GeneratedBy=run-cleanup'; ExistedBefore = $true; BackupPath = $backup; BackupHash = (Get-ZcBytesHash ([IO.File]::ReadAllBytes($backup))); ContentHash = (Get-ZcBytesHash ([IO.File]::ReadAllBytes($p))) } }
        )
        $result = Invoke-ZcUndoJournal -Root $tmp -Journal $j
        Assert-True ($result.Errors.Count -eq 0 -and [IO.File]::ReadAllText($p) -eq 'original access') 'A run directory must not be removed before its backup is restored.'
        Assert-True (-not [IO.Directory]::Exists($runDir)) 'Run files may be removed after successful restoration.'
    }
    Test-Case 'a rejected restoration preserves the run directory and original backup' {
        $runDir = Join-Path $tmp 'failed-run-files'; [void][IO.Directory]::CreateDirectory($runDir)
        $backup = Join-Path $runDir 'access.bak'; $p = Join-Path $tmp 'failed-run-access.txt'
        [IO.File]::WriteAllText($backup, 'original access')
        [IO.File]::WriteAllText($p, 'GeneratedBy=failed-run user edit')
        $j = New-OfflineJournal 'failed-run' 'site'
        $j.Changes = @(
            [pscustomobject]@{ Kind = 'tempdir'; Data = @{ Path = $runDir } },
            [pscustomobject]@{ Kind = 'file.access-result'; Data = @{ Path = $p; Marker = 'GeneratedBy=failed-run'; ExistedBefore = $true; BackupPath = $backup; BackupHash = (Get-ZcBytesHash ([IO.File]::ReadAllBytes($backup))); ContentHash = (Get-ZcBytesHash ([Text.Encoding]::UTF8.GetBytes('GeneratedBy=failed-run'))) } }
        )
        $result = Invoke-ZcUndoJournal -Root $tmp -Journal $j
        Assert-True ($result.Errors.Count -eq 2 -and [IO.File]::Exists($backup)) 'Undo errors must keep the only original backup available.'
        Assert-True ([IO.File]::ReadAllText($p) -eq 'GeneratedBy=failed-run user edit') 'A rejected restore must preserve user changes.'
    }
    Test-Case 'a directory sharing the state-root prefix is outside cleanup ownership' {
        $state = Join-Path $tmp 'boundary'; $outside = Join-Path $tmp 'boundary-sibling'
        [void][IO.Directory]::CreateDirectory($outside)
        $p = Join-Path $outside 'keep.txt'; [IO.File]::WriteAllText($p, 'keep')
        $j = New-OfflineJournal 'boundary-test' 'site'
        $j.Changes = @([pscustomobject]@{ Kind = 'tempdir'; Data = @{ Path = $outside } })
        $result = Invoke-ZcUndoJournal -Root $state -Journal $j
        Assert-True ($result.Errors.Count -eq 0 -and $result.Results[0].Status -eq 'Skipped' -and [IO.File]::Exists($p)) 'A common string prefix must not authorize directory deletion.'
    }
    Test-Case 'a journaled profile whose write never applied is already restored' {
        $p = Join-Path $tmp 'not-applied.md'; [IO.File]::WriteAllText($p, 'original before the write')
        $backupRoot = Initialize-ZcProfileBackupRoot -Root $tmp
        $backup = Join-Path $backupRoot 'not-applied.bin'; [IO.File]::WriteAllText($backup, 'original before the write')
        $j = New-OfflineJournal 'not-applied'
        $j.Changes = @([pscustomobject]@{ Kind = 'file.profile'; Data = @{
            Path = $p; Marker = 'ZCodeRemoteAccess:RunId=not-applied'; ExistedBefore = $true; BackupPath = $backup
            BackupHash = (Get-ZcBytesHash ([IO.File]::ReadAllBytes($backup)))
            ContentHash = (Get-ZcBytesHash ([Text.Encoding]::UTF8.GetBytes('ZCodeRemoteAccess:RunId=not-applied')))
        } })
        $result = Invoke-ZcUndoLocalJournal -Root $tmp -Journal $j
        Assert-True ($result.Errors.Count -eq 0 -and $result.Status -eq 'Undone') 'A write that never changed the file must finish without ownership errors.'
        Assert-True ([IO.File]::ReadAllText($p) -eq 'original before the write') 'An already original file must not be overwritten.'
    }
    Test-Case 'a requested logout blocked by the CLI is a retryable error' {
        $j = New-OfflineJournal 'logout-blocked' 'site'
        $j.Changes = @([pscustomobject]@{ Kind = 'tailscale.join'; Data = @{ JoinedByTool = $true } })
        $script:Calls = New-Object System.Collections.ArrayList; $script:LogoutBlocked = $true
        try {
            $result = Invoke-ZcUndoJournal -Root $tmp -Journal $j -UnjoinTailscale
            Assert-True ($result.Errors.Count -eq 1 -and $result.Status -eq 'UndoPartial') 'A requested logout that never finished must not report successful undo.'
        } finally { $script:LogoutBlocked = $false }
    }
    Test-Case 'the actual site writer preserves the original when journal persistence fails' {
        $caseRoot = Join-Path $tmp 'site-writer-failure'; [void][IO.Directory]::CreateDirectory($caseRoot)
        [IO.File]::WriteAllText((Join-Path $caseRoot 'access-result.txt'), 'original site result')
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root '01-jump-setup.ps1'), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
        $writer = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-AccessResult' }, $true))
        if ($writer.Count -ne 1) { throw 'Expected one actual site writer.' }
        # The original function is defined in a TEMP script, binding its
        # PSScriptRoot to this isolated directory. The fault stops it before
        # reaching its desktop/config branches in both old and new versions.
        $harness = @'
param([string]$Library, [string]$Root)
$ErrorActionPreference = 'Stop'
. $Library
$script:RunId = 'writer-journal-failure'
$script:RunDir = Join-Path $Root 'run-files'
$script:Journal = New-ZcJournal -Phase site -SiteName lab -HostName $env:COMPUTERNAME -RunId $script:RunId
$OpsUser = 'offline-user'
[void][IO.Directory]::CreateDirectory($script:RunDir)
Add-ZcChange -Root $Root -Journal $script:Journal -Kind tempdir -Data @{ Path = $script:RunDir } | Out-Null
function Write-Ok([string]$Text) { }
function Add-SiteChange { param([string]$Kind, $Data) throw 'SIMULATED_JOURNAL_FAILURE' }
__WRITER__
$message = ''
try { Write-AccessResult '100.64.0.1' 'lab' } catch { $message = $_.Exception.Message }
if ($message -notmatch 'SIMULATED_JOURNAL_FAILURE') { throw ('Fault injection was not reached: ' + $message) }
Invoke-ZcUndoJournal -Root $Root -Journal $script:Journal | Out-Null
if ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'access-result.txt')) -ne 'original site result') { throw 'Original site result was lost after writer failure.' }
Write-Output 'PASS actual site writer persistence fault.'
'@
        $harness = $harness.Replace('__WRITER__', $writer[0].Extent.Text)
        $path = Join-Path $caseRoot 'site-writer.ps1'; [IO.File]::WriteAllText($path, $harness)
        $output = & powershell.exe -NoProfile -NonInteractive -File $path -Library (Join-Path $root 'zc-state.ps1') -Root $caseRoot 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0 -and $output -match 'PASS actual site writer') ('The production writer must keep the original before journal persistence: ' + $output)
    }
} finally {
    $absolute = [IO.Path]::GetFullPath($tmp)
    $tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $absolute.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe TEMP cleanup path.' }
    foreach ($file in @(Get-ChildItem -LiteralPath $tmp -Recurse -File)) { Remove-Item -LiteralPath $file.FullName -Force }
    foreach ($dir in @(Get-ChildItem -LiteralPath $tmp -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending)) { [IO.Directory]::Delete($dir.FullName) }
    [IO.Directory]::Delete($absolute)
}
Write-Host ("RESULT: {0} passed; {1} failed (PowerShell {2}); offline TEMP/stubs only." -f $script:Pass, $script:Failures.Count, $PSVersionTable.PSVersion)
if ($script:Failures.Count -gt 0) { exit 1 }
