#Requires -Version 5.1
<#
.SYNOPSIS
    Experimental remote-access kit menu (1 = site setup, 2 = local connection).
.NOTES
    Engines are called in-process with hashtable splatting. Secrets and arrays
    must never be reconstructed as a powershell.exe command line.
    Site setup remains opt-in until the security review findings are resolved.
#>
[CmdletBinding()]
param(
    [ValidateSet(0,1,2)][int]$Mode = 0,
    [switch]$VerifyOnly,
    [switch]$AllowExperimentalSiteSetup,
    [switch]$OnlineInstaller
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
$root = $PSScriptRoot

function Test-Headless {
    try { return [Console]::IsInputRedirected } catch { return $true }
}
function Get-ResultValue([string]$Key) {
    $path = Join-Path $PSScriptRoot 'access-result.txt'
    if (Test-Path -LiteralPath $path) {
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if ($line -match ('^' + [regex]::Escape($Key) + '=(.+)$')) { return $Matches[1].Trim() }
        }
    }
    return ''
}

try {
    if ($Mode -eq 0) {
        if (Test-Headless) { throw 'Headless usage requires -Mode 1 or -Mode 2. No prompt is allowed.' }
        Write-Host ''
        Write-Host '===== 现场远程接入工具 / 回归原型 =====' -ForegroundColor Cyan
        Write-Host '[1] 现场初始化（实验功能，需要显式授权）'
        Write-Host '[2] 本机连接（相同转发规则不重写、不重启服务）'
        $answer = Read-Host '请选择 1 或 2'
        if ($answer -notin @('1','2')) { throw 'Invalid menu selection.' }
        $Mode = [int]$answer
    }
    $configPath = Join-Path $root 'config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { throw 'config.json is missing. Copy the template and fill in project settings.' }
    $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.opsUser -or -not $cfg.opsPassword) { throw 'Set opsUser and opsPassword in config.json before running. No hidden password prompt is used.' }
    if ($cfg.siteName -and [string]$cfg.siteName -match '[<>:"/\\|?*]') { throw 'siteName contains invalid filename characters.' }

    if ($Mode -eq 1) {
        if ($VerifyOnly) { throw 'VerifyOnly is supported by mode 2 only.' }
        if (-not $AllowExperimentalSiteSetup) {
            throw '现场初始化尚未通过安全验收，默认暂停。仅在隔离测试机上使用 -AllowExperimentalSiteSetup；不要再次在生产跳板机试跑。'
        }
        if (-not $cfg.authKey) { throw 'Set authKey in config.json for first-time site enrollment.' }
        $parameters = @{
            AuthKey = [string]$cfg.authKey
            OpsUser = [string]$cfg.opsUser
            OpsPassword = [string]$cfg.opsPassword
            SiteName = [string]$cfg.siteName
            AdvertiseRoutes = [string[]]@($cfg.advertiseRoutes)
            AllowExperimentalSiteSetup = $true
        }
        if ($OnlineInstaller -or [bool]$cfg.useOnlineInstaller) { $parameters['UseOnlineInstaller'] = $true }
        $global:LASTEXITCODE = 0
        & (Join-Path $root '01-jump-setup.ps1') @parameters
        $engineExit = $LASTEXITCODE
        if ($engineExit -ne 0) { throw "Site engine failed (exit $engineExit)." }
        $ip = Get-ResultValue 'JumpHost'
        if (-not $ip) { throw 'Site setup did not produce an access result. It is not verified.' }
        Write-Host ('现场结果：{0}。保留工具目录中的接入结果供本机读取。' -f $ip) -ForegroundColor Green
    }
    else {
        $jump = [string]$cfg.jumpHost
        if (-not $jump) { $jump = Get-ResultValue 'JumpHost' }
        if (-not $jump) { throw 'Set jumpHost or bring back access-result.txt from the site.' }
        if ((Test-Headless) -and -not $cfg.targetServer) { throw 'Headless usage requires targetServer in config.json. Do not guess a production server.' }
        $name = [string]$cfg.siteName
        if (-not $name) { $name = 'site' }
        $profile = [string]$cfg.profilePath
        if (-not $profile) { $profile = Join-Path $root ('site-profile-{0}.md' -f $name) }
        $parameters = @{
            JumpHost = $jump
            JumpUser = [string]$cfg.opsUser
            JumpPassword = [string]$cfg.opsPassword
            Target = [string]$cfg.targetServer
            Forward = [string[]]@($cfg.extraForwards)
            SiteName = $name
            ProfilePath = $profile
            VerifyOnly = [bool]$VerifyOnly
        }
        foreach ($entry in @(@('dbPort','DbPort'),@('webPort','WebPort'),@('rdpPort','RdpPort'))) {
            $value = $cfg.($entry[0])
            if ($null -ne $value) { $parameters[$entry[1]] = [int]$value }
        }
        $global:LASTEXITCODE = 0
        & (Join-Path $root '02-connect-site.ps1') @parameters
        $engineExit = $LASTEXITCODE
        if ($engineExit -ne 0) { throw "Local engine failed (exit $engineExit)." }
        if ($VerifyOnly) {
            Write-Host '只读验证完成：没有修改现场配置，也没有写入接入档案。' -ForegroundColor Green
        } else {
            if (-not (Test-Path -LiteralPath $profile)) { throw 'Verification did not produce a profile.' }
            Write-Host ('本机验证完成，档案：{0}' -f $profile) -ForegroundColor Green
        }
    }
}
catch {
    Write-Host ('[FAIL] {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
