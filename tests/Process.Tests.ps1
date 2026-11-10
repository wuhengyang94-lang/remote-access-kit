#Requires -Version 5.1
# Exercise the actual GUI runner with a harmless local stub child.
$ErrorActionPreference='Stop'
$kit=Split-Path $PSScriptRoot -Parent
$root=Join-Path $env:TEMP ('kit-process-test-'+[guid]::NewGuid().ToString('N'))
$script:root=Join-Path $root 'folder with spaces'
New-Item -ItemType Directory -Path $script:root -Force | Out-Null
$script:LogRoot=Join-Path $root 'logs'
foreach($libName in @('zc-config.ps1','zc-process.ps1')) { $lib=Join-Path $kit $libName; if(Test-Path -LiteralPath $lib){. $lib} }
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $kit 'gui.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'GUI parse errors.'}
$funcs=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($f in $funcs){. ([scriptblock]::Create($f.Extent.Text))}
$script:proc=$null;$script:io=$null;$script:actionButtons=@();$script:inputControls=@()
$script:status=[pscustomobject]@{Text=''}
$script:log=[pscustomobject]@{Buffer=''}
$script:log | Add-Member ScriptMethod AppendText {param($text) $this.Buffer += $text}
$script:timer=[pscustomobject]@{}
$script:timer | Add-Member ScriptMethod Start {}
$script:timer | Add-Member ScriptMethod Stop {}
[IO.File]::WriteAllText((Join-Path $script:root 'stub.ps1'),"Write-Output 'STUB_REACHED'; exit 7")
Start-Engine 'stub.ps1' @()
for($i=0;$i -lt 100 -and -not $script:proc.HasExited;$i++){Start-Sleep -Milliseconds 100}
if(-not $script:proc.HasExited){$script:proc.Kill();throw 'Local stub exceeded 10 seconds.'}
if($script:proc.ExitCode -ne 7){throw "ASSERT: GUI must retain child exit code 7; got '$($script:proc.ExitCode)'."}
$passed=1
$quoted=Get-ZcPowerShellArguments -ScriptPath (Join-Path $script:root 'stub.ps1') -Arguments @()
if($quoted -notmatch '-File "[^"]+folder with spaces[^"]+"'){throw 'ASSERT: The elevation path must be explicitly quoted.'}
$passed++
Read-IntoLog
if($script:log.Buffer -notmatch 'STUB_REACHED'){throw 'ASSERT: GUI must collect child output.'}
$passed++
$result=Get-ZcProcessResult -Job $script:job
if($result.ExitCode -ne 7 -or $result.Succeeded){throw 'ASSERT: A failing child must produce a failure result.'}
$passed++
Write-Output "PASS: $passed offline GUI process checks (real local stub; no elevation or remote access)."
Write-Output "TEMP: $root"
