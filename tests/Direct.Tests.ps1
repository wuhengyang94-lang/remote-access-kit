#Requires -Version 5.1
# Verify the launcher contract with stub engines, including PC-only access.
$ErrorActionPreference='Stop'
$kit=Split-Path $PSScriptRoot -Parent
$root=Join-Path $env:TEMP ('kit-direct-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
foreach($name in @('run.ps1','zc-config.ps1')){if(Test-Path -LiteralPath (Join-Path $kit $name)){Copy-Item -LiteralPath (Join-Path $kit $name) -Destination (Join-Path $root $name)}}
$stub=@'
param([string]$JumpHost,[string]$JumpUser,[string]$JumpPassword,[string]$Target,[string[]]$Forward,[string]$SiteName,[string]$ProfilePath,[switch]$VerifyOnly,[switch]$DirectOnly,[int]$DbPort,[int]$WebPort,[int]$RdpPort)
$PSBoundParameters['DirectOnly']=[bool]$DirectOnly
$PSBoundParameters | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'received.json') -Encoding UTF8
'@
[IO.File]::WriteAllText((Join-Path $root '02-connect-site.ps1'),$stub)
$cfg=[ordered]@{opsUser='fake_ops';opsPassword='synthetic-password';authKey='';siteName='offline';jumpHost='100.64.0.10';targetServer='';connectionMode='Direct';extraForwards=@();dbPort=13306;webPort=18080;rdpPort=13389;profilePath=''}
function Run-Case([bool]$expected){
[IO.File]::WriteAllText((Join-Path $root 'config.json'),($cfg | ConvertTo-Json -Depth 6))
$arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $root 'run.ps1')+'" -Mode 2 -VerifyOnly'
$p=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $root 'out.log') -RedirectStandardError (Join-Path $root 'err.log')
$null=$p.Handle
if(-not $p.WaitForExit(10000)){$p.Kill();throw 'Launcher exceeded 10 seconds.'};$p.WaitForExit()
if(($p.ExitCode -eq 0) -ne $expected){throw ('ASSERT: Expected direct launch success='+$expected+'; exit='+$p.ExitCode+'; '+[IO.File]::ReadAllText((Join-Path $root 'out.log')))}
}
Run-Case $true
$received=Get-Content -LiteralPath (Join-Path $root 'received.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not $received.DirectOnly -or $received.Target -or @($received.Forward).Count){throw 'ASSERT: Direct mode must not require or configure a target server.'}
$passed=1
$cfg.connectionMode='Forward'
Run-Case $false
$passed++
$cfg.targetServer='10.0.0.10'
Run-Case $true
$received=Get-Content -LiteralPath (Join-Path $root 'received.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if($received.DirectOnly -or $received.Target -ne '10.0.0.10'){throw 'ASSERT: Forward mode must preserve its explicit target.'}
$passed++
Write-Output "PASS: $passed offline direct/forward launcher checks (stub engines; no remote access)."
Write-Output "TEMP: $root"
