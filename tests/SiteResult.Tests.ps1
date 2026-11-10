#Requires -Version 5.1
# The actual 01 main AST must reject an empty IP. All host operations are stubs.
$ErrorActionPreference='Stop'
$kit=Split-Path $PSScriptRoot -Parent
$testDir=Join-Path $env:TEMP ('kit-site-result-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$harness=@'
param([string]$Source,[string]$Root)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Engine parse error.'}
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
function Initialize-ZcStateRoot {param($Path) return $Path}
function New-ZcRunId {return 'site-fake'}
function Get-SiteSnapshot {return [pscustomobject]@{}}
function New-ZcJournal {return [pscustomobject]@{Status='Applying'}}
function Save-SiteJournal {}
function Get-ZcJournalPath {return 'fake-journal.json'}
function Add-SiteChange {}
function Get-TailscaleIp {Write-Host 'FAKE_EMPTY_IP_READ';return ''}
function Get-NetIPAddress {return @()}
$StateRoot=$Root;$SkipTailscale=$true;$SkipWinRM=$true;$NoRollbackOnFailure=$true;$AdvertiseRoutes=@();$script:WinRmBroadRulesRemaining=@()
$main=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
. ([scriptblock]::Create($main.Extent.Text))
'@
$path=Join-Path $testDir 'harness.ps1';[IO.File]::WriteAllText($path,$harness)
$out=Join-Path $testDir 'out.log';$err=Join-Path $testDir 'err.log'
$args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$path+'" -Source "'+(Join-Path $kit '01-jump-setup.ps1')+'" -Root "'+$testDir+'"'
$p=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
$null=$p.Handle
if(-not $p.WaitForExit(10000)){$p.Kill();throw 'Site harness exceeded 10 seconds.'};$p.WaitForExit()
$text=[IO.File]::ReadAllText($out)+[IO.File]::ReadAllText($err)
if($p.ExitCode -eq 0 -or $text -notmatch 'FAKE_EMPTY_IP_READ' -or $text -notmatch 'Could not verify Tailscale IPv4'){throw ('ASSERT: Empty IP must fail before READY. exit='+$p.ExitCode+'; '+$text)}
Write-Output 'PASS: 1 site result validity check (actual main AST; all host operations stubbed).'
