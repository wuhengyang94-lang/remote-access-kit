#Requires -Version 5.1
# A signed-out local client must fail clearly instead of waiting for hidden login.
$ErrorActionPreference='Stop'
$kit=Split-Path $PSScriptRoot -Parent
. (Join-Path $kit 'zc-config.ps1')
. (Join-Path $kit 'zc-process.ps1')
$temp=Join-Path $env:TEMP ('kit-client-ready-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$script:TsExe=Join-Path $temp 'fake-tailscale.ps1'
$flag=Join-Path $temp 'up-was-called'
$savedFlag=$env:KIT_CLIENT_TEST_FLAG;$env:KIT_CLIENT_TEST_FLAG=$flag
$fake=@'
param([string]$Operation)
if($Operation -eq 'status') { '{"BackendState":"NeedsLogin"}' }
if($Operation -eq 'up') { [IO.File]::WriteAllText($env:KIT_CLIENT_TEST_FLAG,'called') }
'@
[IO.File]::WriteAllText($script:TsExe,$fake)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $kit '02-connect-site.ps1'),[ref]$tokens,[ref]$errors)
$definition=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-TailscaleConnected'},$true)[0]
. ([scriptblock]::Create($definition.Extent.Text))
function Write-Step {}
function Write-Ok {}
$script:state='NeedsLogin'
function Invoke-ZcNativeProcess { return [pscustomobject]@{ExitCode=0;Text=('{"BackendState":"'+$script:state+'"}')} }
try {
    $message='';try{Ensure-TailscaleConnected}catch{$message=$_.Exception.Message}
    if((Test-Path -LiteralPath $flag) -or $message -notmatch 'log in'){throw 'ASSERT: A signed-out client must request tray login without starting a hidden authorization command.'}
    $passed=1
    $script:state='Running';Ensure-TailscaleConnected;$passed++
} finally {$env:KIT_CLIENT_TEST_FLAG=$savedFlag}
# Reload the real process helper for a harmless bounded native-process check.
. (Join-Path $kit 'zc-process.ps1')
$watch=[Diagnostics.Stopwatch]::StartNew()
$result=Invoke-ZcNativeProcess -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 10') -TimeoutSec 1
if($result.ExitCode -ne -1 -or $watch.Elapsed.TotalSeconds -gt 5){throw 'ASSERT: A native child must be terminated at its deadline.'}
$passed++
Write-Output "PASS: $passed client readiness/timeout checks (fake Tailscale and harmless local child; no remote access)."
