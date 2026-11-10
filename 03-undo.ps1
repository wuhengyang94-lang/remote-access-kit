#Requires -Version 5.1
<#
.SYNOPSIS
    Revert resources created by 01-jump-setup.ps1 and 02-connect-site.ps1.

.DESCRIPTION
    Journal-driven undo. Only resources whose ownership is proven by the run
    journal are removed or restored; pre-existing rules, accounts, registry
    values and services are preserved.

    Run this ON THE JUMP HOST for -Scope Site. Local TrustedHosts/profile
    changes are reverted on the local PC with -Scope Local.

    Default is a dry-run plan followed by an interactive confirmation. Use
    -Force for unattended execution and -DryRun to only print the plan.
    The default selects every pending run in the requested scope, newest first.
    Use -Latest to select only the latest pending run per phase, and -SiteName
    to restrict the selection to one site. Selection switches are exclusive.

.NOTES
    ASCII-only source on purpose: Windows PowerShell 5.1 misreads UTF-8 .ps1
    files without BOM.
#>
[CmdletBinding()]
param(
    [string]$RunId,
    [switch]$Latest,
    [switch]$All,
    [switch]$List,
    [string]$SiteName,
    [ValidateSet('Site', 'Local', 'All')]
    [string]$Scope = 'Site',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$RemoveTailscale,
    [switch]$UnjoinTailscale,
    [string]$StateRoot,
    [string]$LocalStateRoot
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$stateLib = Join-Path $PSScriptRoot 'zc-state.ps1'
if (-not (Test-Path -LiteralPath $stateLib)) {
    throw 'Kit incomplete: zc-state.ps1 is missing next to 03-undo.ps1.'
}
. $stateLib

function Write-Step([string]$Text) { Write-Host "[step] $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "[ ok ] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "[warn] $Text" -ForegroundColor Yellow }
function Test-Headless {
    try { return [Console]::IsInputRedirected } catch { return $true }
}

try {
    if (($RunId -and ($Latest -or $All)) -or ($Latest -and $All)) { throw '-RunId, -All and -Latest are mutually exclusive.' }
    if ($List -and ($DryRun -or $Force)) { throw '-List cannot be combined with -DryRun or -Force.' }

    $siteRoot = ''
    $localRoot = ''
    if ($Scope -eq 'Site' -or $Scope -eq 'All') { $siteRoot = Get-ZcStateRoot $StateRoot }
    if ($Scope -eq 'Local' -or $Scope -eq 'All') { $localRoot = Get-ZcLocalStateRoot $LocalStateRoot }

    $journals = @()
    if ($siteRoot) { $journals += @(Get-ZcJournals -Root $siteRoot -RunId $RunId -Phase @('site', 'connect')) }
    if ($localRoot) { $journals += @(Get-ZcJournals -Root $localRoot -RunId $RunId -Phase @('local')) }
    if ($SiteName) { $journals = @($journals | Where-Object { [string]$_.SiteName -eq $SiteName }) }

    if ($List) {
        if (@($journals).Count -eq 0) {
            Write-Warn2 'No journals found.'
            exit 0
        }
        $journals | Sort-Object CreatedUtc -Descending | ForEach-Object {
            '{0}  phase={1}  host={2}  site={3}  status={4}  changes={5}' -f `
                $_.RunId, $_.Phase, $_.HostName, $_.SiteName, $_.Status, @($_.Changes).Count
        }
        exit 0
    }

    if (@($journals).Count -eq 0) {
        Write-Warn2 'No journals found for the requested scope.'
        if ($Scope -eq 'Site' -or $Scope -eq 'All') {
            Write-Warn2 'Site undo must run on the jump host, where the journal was written.'
        }
        exit 0
    }

    $journals = @(Select-ZcUndoJournals -Journals $journals -RunId $RunId -SiteName $SiteName -All:$All -Latest:$Latest `
        -RemoveTailscale:$RemoveTailscale -UnjoinTailscale:$UnjoinTailscale)

    $entries = @()
    foreach ($j in $journals) {
        $root = $siteRoot
        if ([string]$j.Phase -eq 'local') { $root = $localRoot }
        if (-not $root) { continue }
        $entries += [pscustomobject]@{ Root = $root; Journal = $j }
    }
    if ($entries.Count -eq 0) {
        Write-Ok 'Nothing to undo for the selected scope and cleanup options.'
        exit 0
    }

    # Undo the newest run first: connect rules before site setup.
    $entries = @($entries | Sort-Object { $_.Journal.CreatedUtc } -Descending)

    Write-Step 'plan'
    $plans = @()
    $planState = @{}
    foreach ($entry in $entries) {
        try {
            $plan = Invoke-ZcUndoJournal -Root $entry.Root -Journal $entry.Journal -DryRun `
                -RemoveTailscale:$RemoveTailscale -UnjoinTailscale:$UnjoinTailscale -PlanState $planState
            $plans += [pscustomobject]@{ Entry = $entry; Plan = $plan }
            foreach ($r in @($plan.Results)) {
                Write-Host ("  [{0}] {1} {2} {3}" -f $r.Status, $r.Kind, $r.Target, $r.Action) -ForegroundColor Gray
            }
        } catch {
            Write-Warn2 ("cannot plan run {0}: {1}" -f $entry.Journal.RunId, $_.Exception.Message)
            $plans += [pscustomobject]@{ Entry = $entry; Plan = $null; Error = $_.Exception.Message }
        }
    }

    $planned = 0
    $planErrors = @()
    foreach ($p in $plans) {
        if ($p.Plan) {
            $planned += @($p.Plan.Results | Where-Object { $_.Status -eq 'Planned' }).Count
            $planErrors += @($p.Plan.Results | Where-Object { $_.Status -eq 'Error' })
        } else {
            $planErrors += $p.Error
        }
    }
    if ($DryRun) {
        Write-Host ''
        if (@($planErrors).Count -gt 0) {
            Write-Warn2 'Dry run found resources that cannot be safely reverted; nothing was changed.'
            exit 1
        }
        Write-Ok 'Dry run only; nothing was changed.'
        exit 0
    }
    if ($planned -eq 0) {
        if (@($planErrors).Count -gt 0) {
            Write-Warn2 'Plan found resources that cannot be safely reverted; nothing was changed.'
            exit 1
        }
        Write-Warn2 'No owned resources are currently present. Nothing to remove.'
        exit 0
    }

    if (-not $Force) {
        if (Test-Headless) { throw 'Headless undo requires -Force after reviewing -DryRun output.' }
        Write-Host ''
        Write-Warn2 ("About to change {0} resource(s). Type UNDO to continue." -f $planned)
        $answer = Read-Host 'Confirm'
        if ($answer -ne 'UNDO') {
            Write-Warn2 'Aborted; nothing was changed.'
            exit 1
        }
    }

    Write-Step 'undo'
    $errors = @()
    $executionState = @{}
    foreach ($p in $plans) {
        if (-not $p.Plan) {
            $errors += $p.Error
            continue
        }
        $entry = $p.Entry
        Write-Host ("run {0} ({1}) on {2}" -f $entry.Journal.RunId, $entry.Journal.Phase, $entry.Journal.HostName) -ForegroundColor Cyan
        try {
            $result = Invoke-ZcUndoJournal -Root $entry.Root -Journal $entry.Journal `
                -RemoveTailscale:$RemoveTailscale -UnjoinTailscale:$UnjoinTailscale -PlanState $executionState
            foreach ($r in @($result.Results)) {
                $color = 'Gray'
                if ($r.Status -eq 'Error') { $color = 'Red' }
                elseif ($r.Status -eq 'Removed' -or $r.Status -eq 'Restored') { $color = 'Green' }
                Write-Host ("  [{0}] {1} {2}: {3}" -f $r.Status, $r.Kind, $r.Target, $r.Detail) -ForegroundColor $color
            }
            $errors += @($result.Errors | ForEach-Object { $_.Kind + ' ' + $_.Target + ': ' + $_.Detail })
        } catch {
            $errors += $_.Exception.Message
            Write-Warn2 ("undo failed for run {0}: {1}" -f $entry.Journal.RunId, $_.Exception.Message)
        }
    }

    Write-Host ''
    if (@($errors).Count -gt 0) {
        Write-Warn2 'Undo completed with errors. Review the journal(s) and fix manually.'
        exit 1
    }
    Write-Ok 'Undo completed.'
    exit 0
} catch {
    Write-Host ''
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
