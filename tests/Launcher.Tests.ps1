#Requires -Version 5.1
# Offline: isolated stub engines, fake credentials, no network or host changes.
$ErrorActionPreference = 'Stop'
$kit = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $env:TEMP ('remote-kit-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($true)
$passed = 0
# gui.ps1 must parse and be UTF-8 with BOM (PS 5.1 reads non-BOM files as ANSI).
$guiPath = Join-Path $kit 'gui.ps1'
$guiTokens = $null; $guiErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$guiTokens, [ref]$guiErrors)
if (@($guiErrors).Count -gt 0) { throw 'gui.ps1 has parse errors.' }
$guiBytes = [IO.File]::ReadAllBytes($guiPath)
if (-not ($guiBytes.Length -ge 3 -and $guiBytes[0] -eq 0xEF -and $guiBytes[1] -eq 0xBB -and $guiBytes[2] -eq 0xBF)) { throw 'gui.ps1 must be UTF-8 with BOM for PS 5.1.' }
$passed++
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $sandbox = Join-Path $testRoot 'folder with spaces'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    [IO.File]::WriteAllText((Join-Path $sandbox 'run.ps1'), [IO.File]::ReadAllText((Join-Path $kit 'run.ps1'), [Text.Encoding]::UTF8), $utf8)
    Copy-Item -LiteralPath (Join-Path $kit 'zc-config.ps1') -Destination (Join-Path $sandbox 'zc-config.ps1')
    $stub = @'
param([string]$JumpHost,[string]$JumpUser,[string]$JumpPassword,[string]$Target,
[string[]]$Forward,[string]$SiteName,[string]$ProfilePath,[switch]$VerifyOnly,
[int]$DbPort,[int]$WebPort,[int]$RdpPort,[switch]$DirectOnly)
$PSBoundParameters | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $PSScriptRoot 'received.json') -Encoding UTF8
'@
    [IO.File]::WriteAllText((Join-Path $sandbox '02-connect-site.ps1'), $stub, $utf8)
    [IO.File]::WriteAllText((Join-Path $sandbox '01-jump-setup.ps1'), "throw 'Site engine must not run in these tests.'", $utf8)
    $fakePassword = 'SYNTHETIC "quoted" value with space and slash\'
    $cfg = [ordered]@{authKey='';opsUser='fake_ops';opsPassword=$fakePassword;siteName='offline';jumpHost='100.64.0.10';targetServer='10.0.0.10';connectionMode='Forward';dbPort=13306;webPort=18080;rdpPort=13389;extraForwards=@('23389:10.0.0.20:3389','33389:10.0.0.30:3389');advertiseRoutes=@();profilePath=''}
    function Save-Config { [IO.File]::WriteAllText((Join-Path $sandbox 'config.json'), ($cfg | ConvertTo-Json -Depth 6), $utf8) }
    function Invoke-Case([string]$Flags, [bool]$ShouldPass) {
        $out = Join-Path $testRoot 'stdout.txt'; $err = Join-Path $testRoot 'stderr.txt'
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f (Join-Path $sandbox 'run.ps1'), $Flags
        $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        # PS 5.1: retain the process handle before waiting, otherwise ExitCode
        # can be null after a short-lived redirected child exits.
        $null = $proc.Handle
        if (-not $proc.WaitForExit(20000)) { $proc.Kill(); throw 'Launcher test exceeded 20 seconds.' }
        $proc.WaitForExit()
        $code = $proc.ExitCode
        if (($code -eq 0) -ne $ShouldPass) { throw "Unexpected launcher exit code: $code" }
    }
    Save-Config
    Invoke-Case '-Mode 2 -VerifyOnly' $true
    $received = Get-Content (Join-Path $sandbox 'received.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($received.JumpPassword -cne $fakePassword -or @($received.Forward).Count -ne 2 -or -not $received.VerifyOnly) { throw 'Structured arguments did not round-trip exactly.' }
    $passed++
    Invoke-Case '-Mode 1' $false; $passed++
    Invoke-Case '' $false; $passed++
    $cfg.opsPassword = ''; Save-Config
    Invoke-Case '-Mode 2 -VerifyOnly' $false; $passed++
    $cfg.opsPassword=$fakePassword; $cfg.targetServer=''; Save-Config
    Invoke-Case '-Mode 2 -VerifyOnly' $false; $passed++
    # A failed engine must not be hidden by a stale profile or result file.
    $cfg.targetServer='10.0.0.10'; $cfg.authKey='synthetic-key-not-valid'; Save-Config
    [IO.File]::WriteAllText((Join-Path $sandbox '02-connect-site.ps1'), 'exit 7', $utf8)
    Invoke-Case '-Mode 2 -VerifyOnly' $false; $passed++
    [IO.File]::WriteAllText((Join-Path $sandbox 'site-profile-offline.md'), 'stale profile', $utf8)
    Invoke-Case '-Mode 2' $false; $passed++
    # The online installer option must reach the site engine (config or switch).
    $stub01 = @'
param([string]$AuthKey,[string]$OpsUser,[string]$OpsPassword,[string]$SiteName,
[string[]]$AdvertiseRoutes,[switch]$AllowExperimentalSiteSetup,[switch]$UseOnlineInstaller)
$PSBoundParameters | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $PSScriptRoot 'received01.json') -Encoding UTF8
'@
    $cfg.useOnlineInstaller = $true; Save-Config
    [IO.File]::WriteAllText((Join-Path $sandbox '01-jump-setup.ps1'), $stub01, $utf8)
    [IO.File]::WriteAllText((Join-Path $sandbox 'access-result.txt'), 'JumpHost=100.64.0.10', $utf8)
    # An unchanged result from an earlier run cannot prove this run succeeded.
    Invoke-Case '-Mode 1 -AllowExperimentalSiteSetup' $false; $passed++
    $stub01 += "`r`n" + '[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''access-result.txt''), (''JumpHost=100.64.0.10'' + [Environment]::NewLine + ''GeneratedBy=stub:'' + [guid]::NewGuid().ToString(''N'')))'
    [IO.File]::WriteAllText((Join-Path $sandbox '01-jump-setup.ps1'), $stub01, $utf8)
    Invoke-Case '-Mode 1 -AllowExperimentalSiteSetup' $true
    $received01 = Get-Content (Join-Path $sandbox 'received01.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $received01.UseOnlineInstaller) { throw 'useOnlineInstaller from config did not reach the site engine.' }
    $passed++
    $cfg.useOnlineInstaller = $false; Save-Config
    Remove-Item (Join-Path $sandbox 'received01.json') -Force -ErrorAction SilentlyContinue
    Invoke-Case '-Mode 1 -AllowExperimentalSiteSetup -OnlineInstaller' $true
    $received01 = Get-Content (Join-Path $sandbox 'received01.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $received01.UseOnlineInstaller) { throw 'the -OnlineInstaller switch did not reach the site engine.' }
    $passed++
    [IO.File]::WriteAllText((Join-Path $sandbox '01-jump-setup.ps1'), 'exit 9', $utf8)
    Invoke-Case '-Mode 1 -AllowExperimentalSiteSetup' $false; $passed++
    Write-Output "PASS: $passed offline launcher checks (stub engines; no remote access)."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        if ((Split-Path $resolved -Leaf) -notmatch '^remote-kit-test-[0-9a-f]{32}$') { throw 'Unexpected cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
