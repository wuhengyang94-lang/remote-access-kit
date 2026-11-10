#Requires -Version 5.1
# Real file/ACL integration for profiles, confined to a random temporary root.
$ErrorActionPreference='Stop'
$kit=Split-Path $PSScriptRoot -Parent
. (Join-Path $kit 'zc-state.ps1')
$testRoot=Join-Path $env:TEMP ('kit-profile-files-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$path=Join-Path $testRoot 'profile [literal].md'
$original=[byte[]]@(0,255,128,10,13,65,66,67)
[IO.File]::WriteAllBytes($path,$original)
$run=New-ZcJournal -Phase 'local' -SiteName 'offline' -HostName $env:COMPUTERNAME
$marker='ZCodeRemoteAccess:RunId='+$run.RunId
Save-ZcProfile -Root $testRoot -Journal $run -Path $path -Content ($marker+"`r`nsynthetic profile") -Marker $marker | Out-Null
$change=@($run.Changes | Where-Object {$_.Kind -eq 'file.profile'})[0]
if(-not (Test-Path -LiteralPath $change.Data.BackupPath) -or (Get-ZcBytesHash ([IO.File]::ReadAllBytes($change.Data.BackupPath))) -ne (Get-ZcBytesHash $original)){throw 'ASSERT: Original profile bytes must be durably backed up.'}
$passed=1
$acl=Get-Acl -LiteralPath (Split-Path $change.Data.BackupPath -Parent)
$allowed=@($acl.Access | Where-Object {$_.AccessControlType -eq 'Allow'} | ForEach-Object {$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value})
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if(-not $acl.AreAccessRulesProtected -or @($allowed | Where-Object {$_ -notin @($sid,'S-1-5-18','S-1-5-32-544')}).Count){throw 'ASSERT: Profile backup permissions must exclude ordinary users.'}
$passed++
$undo=Invoke-ZcUndoJournal -Root $testRoot -Journal $run
if($undo.Errors.Count -or (Get-ZcBytesHash ([IO.File]::ReadAllBytes($path))) -ne (Get-ZcBytesHash $original)){throw 'ASSERT: Actual file undo must restore every original byte.'}
$passed++
$newPath=Join-Path $testRoot 'new-profile.md'
$second=New-ZcJournal -Phase 'local' -SiteName 'offline' -HostName $env:COMPUTERNAME
$secondMarker='ZCodeRemoteAccess:RunId='+$second.RunId
Save-ZcProfile -Root $testRoot -Journal $second -Path $newPath -Content $secondMarker -Marker $secondMarker | Out-Null
$undo=Invoke-ZcUndoJournal -Root $testRoot -Journal $second
if($undo.Errors.Count -or (Test-Path -LiteralPath $newPath)){throw 'ASSERT: A newly generated profile must be removed by undo.'}
$passed++
Write-Output "PASS: $passed profile file integration checks (actual TEMP files and DACL; no system or remote operations)."
Write-Output "TEMP: $testRoot"
