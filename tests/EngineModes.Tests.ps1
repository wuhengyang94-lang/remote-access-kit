#Requires -Version 5.1
# Execute the real 02 main AST with every external dependency replaced.
$ErrorActionPreference='Stop'
$kit=Split-Path $PSScriptRoot -Parent
$temp=Join-Path $env:TEMP ('kit-modes-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$harness=@'
param([string]$Source,[switch]$ReadOnly)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Engine source parse error.'}
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
$script:connected=0;$script:prerequisites=0;$script:profileSaved=0;$script:trusted=0
function Connect-JumpHost { $script:connected++; return 'FAKE-PEER' }
function Ensure-LocalTailscale { $script:prerequisites++ }
function Ensure-TailscaleConnected { $script:prerequisites++ }
function Ensure-WinRMClient { $script:prerequisites++ }
function Ensure-TrustedHost { $script:trusted++; return [pscustomobject]@{Changed=$false} }
function Get-SiteDiscovery { throw 'ASSERT: Direct mode performed discovery.' }
function Set-RemoteForwards { throw 'ASSERT: Direct mode attempted forwarding.' }
function Initialize-ZcLocalStateRoot { return $env:TEMP }
function New-ZcRunId { return 'connect-offline-test' }
function New-ZcJournal { return [pscustomobject]@{Status='Applying'} }
function Save-ZcJournal {}
function Add-ZcChange {}
function Save-ZcProfile { $script:profileSaved++ }
function Test-Admin { return $true }
$DirectOnly=$true;$VerifyOnly=[bool]$ReadOnly;$Target='';$Forward=@();$Force=$false;$EnsureOnBoot=$false;$NoVerify=$false;$Discover=$false
$JumpHost='100.64.0.10';$JumpUser='fake_ops';$JumpPassword='synthetic-password';$SiteName='offline';$ProfilePath='fake-profile.md'
$DbPort=13306;$WebPort=18080;$RdpPort=13389
$main=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
. ([scriptblock]::Create($main.Extent.Text))
if($script:connected -ne 1){throw 'ASSERT: Direct access must verify an actual remote command.'}
if($ReadOnly){if($script:prerequisites -or $script:trusted -or $script:profileSaved){throw 'ASSERT: Read-only direct mode changed setup.'}}
else{if($script:prerequisites -ne 3 -or $script:trusted -ne 1 -or $script:profileSaved -ne 1){throw 'ASSERT: Normal direct mode did not prepare the client and save its profile.'}}
Write-Output ('PASS: actual direct engine main; readonly='+[bool]$ReadOnly)
'@
$path=Join-Path $temp 'harness.ps1'
[IO.File]::WriteAllText($path,$harness)
$passed=0
foreach($mode in @('', '-ReadOnly')){
$args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$path+'" -Source "'+(Join-Path $kit '02-connect-site.ps1')+'" '+$mode
$out=Join-Path $temp ('out-'+$passed+'.log');$err=Join-Path $temp ('err-'+$passed+'.log')
$p=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
$null=$p.Handle
if(-not $p.WaitForExit(10000)){$p.Kill();throw 'Engine harness exceeded 10 seconds.'};$p.WaitForExit()
if($p.ExitCode -ne 0){throw ('Engine harness failed: '+[IO.File]::ReadAllText($out)+[IO.File]::ReadAllText($err))}
$passed++
}
Write-Output "PASS: $passed actual direct engine checks (AST main; all external operations stubbed)."
Write-Output "TEMP: $temp"
