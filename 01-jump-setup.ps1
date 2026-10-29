#Requires -Version 5.1
<#
.SYNOPSIS
    One-time setup: turn THIS machine into a remote-access jump host.

.DESCRIPTION
    Run as Administrator ON THE ON-SITE JUMP MACHINE (the only machine at the
    project site with internet access). Idempotent with an explicit change
    journal: every resource this tool creates is recorded and can be reverted
    with 03-undo.ps1.

    What it does:
      1. Installs Tailscale (if missing) after Authenticode verification and
         joins the tailnet. The auth key is passed through the process
         environment, never through a command line or a fixed TEMP file.
      2. Enables WinRM / PS Remoting, then disables the broad WinRM firewall
         rules created by Enable-PSRemoting and adds a rule limited to the
         Tailscale CGNAT range 100.64.0.0/10.
      3. Creates a dedicated local admin account with New-LocalUser (no
         plaintext password on a command line) and sets
         LocalAccountTokenFilterPolicy=1.
      4. Optional subnet router mode.
      5. Writes access-result.txt with a run marker and updates config.json.
      6. Writes a journal under %ProgramData%\ZCodeRemoteAccess\runs and, on
         failure, rolls back only the resources created by this run.

.NOTES
    ASCII-only source on purpose: Windows PowerShell 5.1 misreads UTF-8 .ps1
    files without BOM, and this script must run on Windows Server 2019.
    zc-state.ps1 must be present next to this file.

.EXAMPLE
    .\01-jump-setup.ps1 -AuthKey tskey-auth-xxxx -OpsPassword 'Strong-Pass-42'

.EXAMPLE
    .\01-jump-setup.ps1 -SkipTailscale -OpsPassword 'Strong-Pass-42'
#>
[CmdletBinding()]
param(
    [string]$AuthKey = $env:TS_AUTHKEY,
    [string]$InstallerPath,
    [string]$OpsUser = 'zcode_ops',
    [string]$OpsPassword,
    [string[]]$AdvertiseRoutes = @(),
    [string]$SiteName = '',
    [switch]$SkipTailscale,
    [switch]$SkipWinRM,
    [switch]$AllowExperimentalSiteSetup,
    [switch]$SkipSignatureCheck,
    [string]$ExpectedInstallerSha256,
    [switch]$AllowExistingAccountUpdate,
    [switch]$AllowBroadWinRM,
    [switch]$NoRollbackOnFailure,
    [string]$StateRoot
)

if (-not $AllowExperimentalSiteSetup) {
    Write-Error 'Site setup is an experimental prototype pending security hardening. Use only on an isolated test host with -AllowExperimentalSiteSetup.'
    exit 1
}
$ErrorActionPreference = 'Stop'
# Native commands emit UTF-8; a fresh console defaults to the ANSI codepage
# (GBK on Chinese Windows), which can corrupt captured output. Force UTF-8.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$stateLib = Join-Path $PSScriptRoot 'zc-state.ps1'
if (-not (Test-Path -LiteralPath $stateLib)) {
    throw 'Kit incomplete: zc-state.ps1 is missing next to 01-jump-setup.ps1.'
}
. $stateLib

$script:TsExe   = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$script:ToolDir = Join-Path $PSScriptRoot 'tools'
$script:Journal = $null
$script:StateRoot = ''
$script:RunDir = ''
$script:RunId = ''
$script:WinRmBroadRulesRemaining = @()

function Write-Step([string]$Text) { Write-Host "[step] $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "[ ok ] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "[warn] $Text" -ForegroundColor Yellow }

function Test-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PlainPassword([string]$Given, [string]$Prompt) {
    if (-not [string]::IsNullOrWhiteSpace($Given)) { return $Given }
    $secure = Read-Host -AsSecureString $Prompt
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Add-SiteChange([string]$Kind, $Data) {
    if (-not $script:Journal) { throw 'Internal error: change journal not initialized.' }
    Add-ZcChange -Root $script:StateRoot -Journal $script:Journal -Kind $Kind -Data $Data | Out-Null
}

function Save-SiteJournal {
    if ($script:Journal) { Save-ZcJournal -Root $script:StateRoot -Journal $script:Journal | Out-Null }
}

function Get-SiteSnapshot {
    $svc = Get-ZcWinRmServiceState
    $listener = Get-ZcWinRmListenerState
    $rules = @()
    try {
        $rules = @(Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Enabled = [string]$_.Enabled }
        })
    } catch { }

    $latfpPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $ipPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $latfp = Get-ZcRegState -Path $latfpPath -Name 'LocalAccountTokenFilterPolicy'
    $iprouter = Get-ZcRegState -Path $ipPath -Name 'IPEnableRouter'
    $account = Get-ZcLocalUserState $OpsUser

    $tsInstalled = Test-Path -LiteralPath $script:TsExe
    $tsBackend = ''
    $tsIp = ''
    if ($tsInstalled) {
        $r = Invoke-ZcNative $script:TsExe @('status', '--json')
        if ($r.ExitCode -eq 0 -and $r.Output) {
            try {
                $j = $r.Output | ConvertFrom-Json
                $tsBackend = [string]$j.BackendState
                if ($j.Self -and $j.Self.TailscaleIPs) { $tsIp = [string]@($j.Self.TailscaleIPs)[0] }
            } catch { }
        }
    }

    $resultPath = Join-Path $PSScriptRoot 'access-result.txt'
    $resultText = ''
    if (Test-Path -LiteralPath $resultPath) {
        $resultText = Get-Content -LiteralPath $resultPath -Raw -ErrorAction SilentlyContinue
    }
    $configPath = Join-Path $PSScriptRoot 'config.json'
    $configHash = ''
    if (Test-Path -LiteralPath $configPath) {
        $text = Get-Content -LiteralPath $configPath -Raw -ErrorAction SilentlyContinue
        if ($text) {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $configHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLower() }
            finally { $sha.Dispose() }
        }
    }

    return [pscustomobject]@{
        WinRM = [pscustomobject]@{ Service = $svc; Listener = $listener; Rules = $rules }
        Registry = [pscustomobject]@{ Latfp = $latfp; IpRouter = $iprouter }
        Account = $account
        Tailscale = [pscustomobject]@{
            Installed = $tsInstalled
            BackendState = $tsBackend
            Ip = $tsIp
            Product = (Get-ZcTailscaleProductState)
        }
        AccessResult = [pscustomobject]@{
            Path = $resultPath
            Exists = [bool]$resultText
            HasMarker = [bool]($resultText -and $resultText.IndexOf('GeneratedBy=' + $script:ZcToolName + ':', [StringComparison]::OrdinalIgnoreCase) -ge 0)
        }
        Config = [pscustomobject]@{ Path = $configPath; Exists = (Test-Path -LiteralPath $configPath); Sha256 = $configHash }
    }
}

function Assert-InstallerTrusted([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Installer not found: $Path" }
    if ($SkipSignatureCheck) {
        Write-Warn2 "installer signature check skipped by request: $Path"
        return
    }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        throw "Installer Authenticode status is '$($sig.Status)': $Path"
    }
    $subject = ''
    if ($sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
    if ($subject -notmatch 'Tailscale') {
        throw "Unexpected installer signer: $subject"
    }
    if ($ExpectedInstallerSha256) {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $ExpectedInstallerSha256.ToLower()) {
            throw "Installer SHA256 mismatch: $hash"
        }
    }
}

function Wait-TailscaleReady([int]$TimeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $script:TsExe) {
            $r = Invoke-Ts @('version') -TimeoutSec 30
            if ($r.ExitCode -eq 0) { return $true }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-TailscaleHealth {
    $r = Invoke-Ts @('status', '--json') -TimeoutSec 30
    if ($r.ExitCode -ne 0 -or -not $r.Text) { return $null }
    try { $j = $r.Text | ConvertFrom-Json } catch { return $null }
    $health = (@($j.Health) -join '; ')
    $reset = ($health -match 'Unable to connect to the Tailscale coordination server|Unable to connect to the coordination server|fetch control key|wsarecv|connection reset|reset by peer')
    return [pscustomobject]@{
        BackendState = [string]$j.BackendState
        Health = $health
        ControlPlaneTlsReset = [bool]$reset
    }
}

function Enable-TailscaleTlsMlkemWorkaround {
    # Some on-site networks/security appliances reset Tailscale's Go TLS
    # handshake (the post-quantum ML-KEM ClientHello is large) while plain
    # curl/SChannel to the same host succeeds. Disable ML-KEM for the service
    # only; the setting must persist for the node to stay connectable.
    $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tailscale'
    $before = Get-ZcRegState -Path $svcKey -Name 'Environment'
    $beforeLines = @()
    if ($before.Exists -and $null -ne $before.Value) {
        $beforeLines = @($before.Value | ForEach-Object { [string]$_ })
    }
    $lines = @($beforeLines)
    $changed = $false
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^GODEBUG=') { $idx = $i; break } }
    if ($idx -ge 0) {
        $val = $lines[$idx].Substring(8)
        if ($val -notmatch '(^|,)tlsmlkem=0(,|$)') {
            $lines[$idx] = 'GODEBUG=' + $(if ($val) { $val + ',tlsmlkem=0' } else { 'tlsmlkem=0' })
            $changed = $true
        }
    } else {
        $lines += 'GODEBUG=tlsmlkem=0'
        $changed = $true
    }
    if ($changed) {
        New-ItemProperty -Path $svcKey -Name 'Environment' -PropertyType MultiString -Value ([string[]]$lines) -Force | Out-Null
        Add-SiteChange 'registry.tailscale-env' @{
            Path = $svcKey
            Name = 'Environment'
            ExistedBefore = [bool]$before.Exists
            ValueBefore = @($beforeLines)
            ValueSet = @($lines)
        }
    }
    Write-Warn2 'control-plane TLS handshake is being reset; set Tailscale service GODEBUG=tlsmlkem=0 and restarted the service.'
    Restart-Service -Name 'Tailscale' -Force -ErrorAction SilentlyContinue
    [void](Wait-TailscaleReady -TimeoutSec 120)
}

function Test-ZcTailscaleInstall {
    param([object]$ExitCode, [bool]$Installed, [bool]$LogOk)
    if (-not $Installed) { return [pscustomobject]@{ Ok = $false; Reason = 'product not found after install' } }
    if ($null -ne $ExitCode -and ([int]$ExitCode -notin 0, 3010) -and -not $LogOk) {
        return [pscustomobject]@{ Ok = $false; Reason = "installer exit code $ExitCode" }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Install-Tailscale {
    if (Test-Path -LiteralPath $script:TsExe) {
        Write-Ok "Tailscale already installed: $script:TsExe"
        return
    }
    $localInstaller = $InstallerPath
    if (-not $localInstaller -and (Test-Path -LiteralPath $script:ToolDir)) {
        $full = @(Get-ChildItem -LiteralPath $script:ToolDir -Filter 'tailscale-setup*full*.exe' -ErrorAction SilentlyContinue)
        if ($full.Count -gt 0) {
            $localInstaller = $full[0].FullName
            Write-Step "using bundled full installer (offline): $localInstaller"
        } else {
            $msi = @(Get-ChildItem -LiteralPath $script:ToolDir -Filter 'tailscale-setup*.msi' -ErrorAction SilentlyContinue)
            if ($msi.Count -gt 0) {
                $localInstaller = $msi[0].FullName
                Write-Step "using bundled MSI: $localInstaller"
            } else {
                $exe = @(Get-ChildItem -LiteralPath $script:ToolDir -Filter 'tailscale-setup*.exe' -ErrorAction SilentlyContinue)
                if ($exe.Count -gt 0) {
                    $localInstaller = $exe[0].FullName
                    Write-Step "using bundled installer (still needs internet during install): $localInstaller"
                }
            }
        }
    }
    if (-not $localInstaller) {
        $localInstaller = Join-Path $script:RunDir ('tailscale-setup-' + [guid]::NewGuid().ToString('N') + '.exe')
        Write-Step 'downloading Tailscale installer (curl, retry)...'
        $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
        if ($curl) {
            $dl = & curl.exe -L --retry 3 --retry-delay 2 -s -S -o $localInstaller 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Tailscale download failed (curl exit $LASTEXITCODE): $dl" }
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' -OutFile $localInstaller -UseBasicParsing
        }
        if (-not (Test-Path -LiteralPath $localInstaller) -or (Get-Item -LiteralPath $localInstaller).Length -lt 500KB) {
            throw 'downloaded Tailscale installer looks truncated or missing.'
        }
    }
    Assert-InstallerTrusted $localInstaller

    Write-Step 'installing Tailscale (silent)...'
    $msiLog = Join-Path $script:RunDir 'tailscale-msi.log'
    if ($localInstaller -match '\.msi$') {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"{0}"' -f $localInstaller), '/quiet', '/norestart', '/l*v', ('"{0}"' -f $msiLog)) -Wait -PassThru
    } else {
        $proc = Start-Process -FilePath $localInstaller -ArgumentList '/quiet' -Wait -PassThru
    }
    $exitCode = $proc.ExitCode
    # A successful install may still return a null exit code on some hosts.
    # Confirm by product/exe presence and the MSI log instead of the code alone.
    $installed = $false
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-Path -LiteralPath $script:TsExe) { $installed = $true; break }
        if (Get-ZcTailscaleProductState) { $installed = $true; break }
        Start-Sleep -Seconds 1
    }
    $logOk = $false
    if (Test-Path -LiteralPath $msiLog) {
        $logTail = @(Get-Content -LiteralPath $msiLog -Tail 300 -ErrorAction SilentlyContinue)
        if (@($logTail | Where-Object { $_ -match 'MainEngineThread is returning 0' }).Count -gt 0) { $logOk = $true }
    }
    $verdict = Test-ZcTailscaleInstall -ExitCode $exitCode -Installed $installed -LogOk $logOk
    if (-not $verdict.Ok) { throw "Tailscale install failed: $($verdict.Reason) (exit code: $exitCode; log: $msiLog)." }
    if ($null -eq $exitCode) { Write-Warn2 'installer exit code was unavailable; product presence confirmed, continuing.' }
    $product = $null
    for ($i = 0; $i -lt 10; $i++) {
        $product = Get-ZcTailscaleProductState
        if ($product) { break }
        Start-Sleep -Seconds 1
    }
    # Record ownership before waiting for the service: if the install succeeds
    # but the service never comes up, undo must still know about the install.
    Add-SiteChange 'tailscale.install' @{
        InstalledBefore = $false
        ProductCode = $(if ($product) { [string]$product.ProductCode } else { '' })
        DisplayName = $(if ($product) { [string]$product.DisplayName } else { '' })
        Installer = $localInstaller
    }
    if (-not (Wait-TailscaleReady -TimeoutSec 180)) { throw 'Tailscale service did not come up after installation.' }
    Write-Ok 'Tailscale installed.'
}

function Invoke-Ts([string[]]$TailArgs, [int]$TimeoutSec = 60) {
    # Use .NET Process directly: Start-Process -PassThru can return a null
    # ExitCode when stdout/stderr are redirected. A hard timeout is required:
    # with the Tailscale IPN/GUI holding the IPC, the CLI can block forever
    # instead of returning 401.
    $argLine = ($TailArgs | ForEach-Object {
        $s = [string]$_
        if ($s -match '\s') { '"' + $s.Replace('"', '\"') + '"' } else { $s }
    }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:TsExe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        try { [void]$proc.WaitForExit(5000) } catch { }
        return [pscustomobject]@{ Text = 'TIMEOUT'; ExitCode = -1 }
    }
    $text = ''
    try { $text = $outTask.Result + $errTask.Result } catch { }
    return [pscustomobject]@{ Text = $text; ExitCode = $proc.ExitCode }
}

function Invoke-TsWithEnvKey([string[]]$TailArgs, [string]$Key, [int]$TimeoutSec = 60) {
    $saved1 = $env:TS_AUTHKEY
    $saved2 = $env:TS_AUTH_KEY
    try {
        $env:TS_AUTHKEY = $Key
        $env:TS_AUTH_KEY = $Key
        return (Invoke-Ts $TailArgs -TimeoutSec $TimeoutSec)
    } finally {
        if ($null -eq $saved1) { Remove-Item Env:TS_AUTHKEY -ErrorAction SilentlyContinue } else { $env:TS_AUTHKEY = $saved1 }
        if ($null -eq $saved2) { Remove-Item Env:TS_AUTH_KEY -ErrorAction SilentlyContinue } else { $env:TS_AUTH_KEY = $saved2 }
    }
}

function Stop-TailscaleIpn {
    $procs = @(Get-Process tailscale-ipn -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($procs.Count -gt 0) {
        Write-Warn2 'stopped the Tailscale IPN/GUI to release the CLI IPC'
        Start-Sleep -Seconds 2
    }
}

function Invoke-TailscaleAsSystem([string[]]$TailArgs, [int]$TimeoutSec = 120, [string]$AuthKey) {
    # When a logged-in Tailscale GUI (running as another user) owns the IPC,
    # the CLI answers 401 "already in use by <user>". SYSTEM is exempt, so
    # re-run the CLI through a one-time scheduled task. The task name and all
    # files are random inside the ACL-restricted run directory. The auth key,
    # when needed, is written to a SYSTEM/Administrators-only file and read by
    # the wrapper into TS_AUTHKEY; it never appears in a command line.
    $taskName = 'ZCodeTsOnce-' + [guid]::NewGuid().ToString('N')
    $wrapper = Join-Path $script:RunDir ('ts-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $keyFile = Join-Path $script:RunDir ('key-' + [guid]::NewGuid().ToString('N') + '.txt')
    $outFile = Join-Path $script:RunDir ('out-' + [guid]::NewGuid().ToString('N') + '.log')
    $created = $false
    try {
        $lines = @()
        $lines += '$ErrorActionPreference = ''Continue'''
        if ($AuthKey) {
            [IO.File]::WriteAllText($keyFile, $AuthKey, (New-Object Text.UTF8Encoding($false)))
            $acl = & icacls.exe $keyFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Cannot secure auth-key file ACL: $acl" }
            $lines += ('$env:TS_AUTHKEY = [IO.File]::ReadAllText(''' + $keyFile + ''').Trim()')
            $lines += '$env:TS_AUTH_KEY = $env:TS_AUTHKEY'
        }
        $argList = ($TailArgs | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
        $lines += ('$out = ''' + $outFile + '''')
        $lines += ('& ''' + $script:TsExe + ''' @(' + $argList + ') *> $out')
        $lines += '$ec = $LASTEXITCODE'
        $lines += 'Add-Content -LiteralPath $out -Value (''__EXIT__='' + $ec)'
        [IO.File]::WriteAllText($wrapper, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

        $action = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + $wrapper
        if ($wrapper -match '\s') { $action = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $wrapper + '"' }
        $create = Invoke-ZcNative 'schtasks.exe' @('/Create', '/TN', $taskName, '/TR', $action, '/SC', 'ONCE', '/ST', '23:59', '/RU', 'SYSTEM', '/RL', 'HIGHEST', '/F')
        if ($create.ExitCode -ne 0) { throw "cannot create the SYSTEM scheduled task: $($create.Output.Trim())" }
        $created = $true
        Add-SiteChange 'scheduledtask' @{ Name = $taskName }
        $run = Invoke-ZcNative 'schtasks.exe' @('/Run', '/TN', $taskName)
        if ($run.ExitCode -ne 0) { throw "cannot start the SYSTEM scheduled task: $($run.Output.Trim())" }

        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $text = ''
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-Path -LiteralPath $outFile) {
                $text = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
                if ($text -match '__EXIT__=(\d+)') { break }
            }
        }
        if ($text -notmatch '__EXIT__=(\d+)') { throw 'SYSTEM tailscale task timed out.' }
        return [pscustomobject]@{ Text = $text; ExitCode = [int]$Matches[1] }
    } finally {
        if ($created) {
            Invoke-ZcNative 'schtasks.exe' @('/End', '/TN', $taskName) | Out-Null
            Invoke-ZcNative 'schtasks.exe' @('/Delete', '/TN', $taskName, '/F') | Out-Null
            # A timed-out SYSTEM task can still hold the output file. Kill the
            # wrapper (and its tailscale child) before deleting the run files.
            $wrappers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -like "*$wrapper*" })
            foreach ($w in $wrappers) {
                $children = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { [int]$_.ParentProcessId -eq [int]$w.ProcessId })
                foreach ($ch in $children) {
                    try { Stop-Process -Id $ch.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
                }
                try { Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
            }
            Start-Sleep -Seconds 1
        }
        Remove-Item -LiteralPath $keyFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-TailscaleRunning {
    $r = Invoke-Ts @('status') -TimeoutSec 30
    if ($r.ExitCode -eq 0) { return $true }
    try {
        $sysOut = Invoke-TailscaleAsSystem @('status') -TimeoutSec 60
        return ($sysOut.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function Join-Tailnet([string]$Key, [string[]]$Routes) {
    $tailArgs = @('up', '--unattended', '--accept-dns=false')
    if ($Routes.Count -gt 0) {
        $tailArgs += @('--advertise-routes', ($Routes -join ','))
        $ipPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
        $before = Get-ZcRegState -Path $ipPath -Name 'IPEnableRouter'
        & reg add 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' /v IPEnableRouter /t REG_DWORD /d 1 /f | Out-Null
        Add-SiteChange 'registry.iprouter' @{ Path = $ipPath; Name = 'IPEnableRouter'; ExistedBefore = [bool]$before.Exists; ValueBefore = $before.Value; ValueSet = 1 }
        Write-Ok 'IP forwarding enabled (subnet router mode).'
    }

    $wasConnected = ([string]$script:Journal.Snapshot.Tailscale.BackendState -eq 'Running')
    if ($Key) {
        Write-Step 'joining tailnet with auth key...'
        # Recoverable join failures: the IPN holds the IPC (401/already in use), the
        # CLI hangs (TIMEOUT), or it silently falls back to interactive login and
        # prints a login URL instead of honoring TS_AUTHKEY.
        $retryPattern = 'already in use|401|TIMEOUT|To authenticate, visit'
        $r = Invoke-TsWithEnvKey -TailArgs $tailArgs -Key $Key -TimeoutSec 60
        if ($r.ExitCode -ne 0 -and $r.Text -match $retryPattern) {
            Write-Warn2 'Tailscale did not accept the auth key via environment (IPC held or interactive fallback); stopping the IPN and retrying...'
            Stop-TailscaleIpn
            $r = Invoke-TsWithEnvKey -TailArgs $tailArgs -Key $Key -TimeoutSec 60
        }
        if ($r.ExitCode -ne 0 -and $r.Text -match $retryPattern) {
            Write-Warn2 'still failing; retrying with --authkey after stopping the IPN...'
            Write-Warn2 'the auth key is visible to local administrators in the short-lived tailscale process'
            Stop-TailscaleIpn
            $r = Invoke-Ts ($tailArgs + @('--authkey', $Key)) -TimeoutSec 90
        }
        # Some on-site networks/security appliances reset Tailscale's own TLS
        # handshake while plain curl to the same host succeeds. Detect that via
        # status --json and apply the service-level ML-KEM workaround.
        if ($r.ExitCode -ne 0) {
            $health = Get-TailscaleHealth
            if ($health -and $health.ControlPlaneTlsReset) {
                Write-Warn2 ("Tailscale cannot reach the coordination server (BackendState=" + $health.BackendState + "); this is a network TLS reset, not a bad key.")
                Enable-TailscaleTlsMlkemWorkaround
                Stop-TailscaleIpn
                $r = Invoke-Ts ($tailArgs + @('--authkey', $Key)) -TimeoutSec 90
            }
        }
        if ($r.ExitCode -ne 0 -and $r.Text -match $retryPattern) {
            Write-Warn2 'still failing; retrying as SYSTEM...'
            $sysOut = Invoke-TailscaleAsSystem -TailArgs $tailArgs -AuthKey $Key -TimeoutSec 120
            if ($sysOut.ExitCode -ne 0) { throw "tailscale up failed under SYSTEM. output: $($sysOut.Text)" }
            Write-Ok 'tailnet joined (via SYSTEM).'
        } elseif ($r.ExitCode -ne 0) {
            if ($r.Text) { Write-Host "      $($r.Text)" }
            $health = Get-TailscaleHealth
            if ($health) { Write-Host ("      BackendState=" + $health.BackendState + "; Health=" + $health.Health) }
            throw "tailscale up failed (exit $($r.ExitCode)). Check auth key expiry / reuse policy and internet access."
        } else {
            Write-Ok 'tailnet joined.'
        }
        $ipRes = Get-TailscaleIp
        Add-SiteChange 'tailscale.join' @{
            JoinedByTool = (-not $wasConnected)
            NodeName = $env:COMPUTERNAME
            NodeIp = [string]$ipRes
        }
        return
    }

    Write-Step 'requesting a login URL (non-interactive)...'
    $outFile = Join-Path $script:RunDir ('login-' + [guid]::NewGuid().ToString('N') + '.out')
    $errFile = Join-Path $script:RunDir ('login-' + [guid]::NewGuid().ToString('N') + '.err')
    Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $script:TsExe -ArgumentList $tailArgs `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile -WindowStyle Hidden -PassThru

    $url = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $outFile) {
            $text = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
            if ($text) {
                $m = [regex]::Match($text, 'https://login\.tailscale\.com/[a-zA-Z0-9/]+')
                if ($m.Success) { $url = $m.Value; break }
            }
        }
        if ($proc.HasExited) { break }
    }

    if (-not $url) {
        if (Test-TailscaleRunning) {
            $st = Invoke-Ts @('status') -TimeoutSec 30
            if ($st.Text -match 'already in use|401|TIMEOUT') {
                Write-Warn2 'GUI blocks the CLI; re-applying prefs via SYSTEM...'
                $sysOut = Invoke-TailscaleAsSystem $tailArgs -TimeoutSec 120
                if ($sysOut.ExitCode -ne 0) { throw "tailscale up failed under SYSTEM. output: $($sysOut.Text)" }
            }
            Write-Ok 'tailnet already connected.'
            $ipRes = Get-TailscaleIp
            Add-SiteChange 'tailscale.join' @{ JoinedByTool = (-not $wasConnected); NodeName = $env:COMPUTERNAME; NodeIp = [string]$ipRes }
            return
        }
        $detail = ''
        if (Test-Path -LiteralPath $errFile) { $detail += (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path -LiteralPath $outFile) { $detail += "`n" + (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) }
        throw "Could not obtain a login URL. tailscale output: $detail"
    }

    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Yellow
    Write-Host ' OPEN THIS LINK IN A BROWSER ON YOUR OWN PC (proxy on if needed),'     -ForegroundColor Yellow
    Write-Host ' then click Connect. This site machine cannot reach Google by itself.' -ForegroundColor Yellow
    Write-Host "   $url" -ForegroundColor White
    Write-Host '=====================================================================' -ForegroundColor Yellow
    Write-Host ''

    Write-Step 'waiting for approval (up to 10 minutes)...'
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        if (Test-TailscaleRunning) {
            Write-Ok 'tailnet joined.'
            $ipRes = Get-TailscaleIp
            Add-SiteChange 'tailscale.join' @{ JoinedByTool = (-not $wasConnected); NodeName = $env:COMPUTERNAME; NodeIp = [string]$ipRes }
            return
        }
        Start-Sleep -Seconds 5
    }
    throw 'Timed out waiting for tailscale login approval.'
}

function Get-TailscaleIp {
    $ipRes = Invoke-Ts @('ip', '-4') -TimeoutSec 30
    if ($ipRes.Text -match 'already in use|401|TIMEOUT') {
        $sysOut = Invoke-TailscaleAsSystem @('ip', '-4') -TimeoutSec 60
        $m = [regex]::Match($sysOut.Text, '(?m)^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*$')
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    }
    $m = [regex]::Match($ipRes.Text, '(?m)^\s*(\d{1,3}(?:\.\d{1,3}){3})')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Enable-Remoting {
    Write-Step 'enabling WinRM / PS Remoting...'
    $snap = $script:Journal.Snapshot.WinRM
    $beforeRules = @($snap.Rules)
    $beforeService = $snap.Service
    $beforeListener = $snap.Listener

    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-Service WinRM -StartupType Automatic
    Start-Service WinRM

    $afterService = Get-ZcWinRmServiceState
    if ($beforeService -and $afterService -and
        ([string]$beforeService.StartType -ne [string]$afterService.StartType -or [string]$beforeService.Status -ne [string]$afterService.Status)) {
        Add-SiteChange 'winrm.service' @{
            Changed = $true
            StartupBefore = [string]$beforeService.StartType
            StatusBefore = [string]$beforeService.Status
        }
    }

    $afterRules = @(Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; Enabled = [string]$_.Enabled }
    })
    $created = @()
    $existing = @()
    $ownFailed = @()
    foreach ($r in $afterRules) {
        $prev = @($beforeRules | Where-Object { [string]$_.Name -eq [string]$r.Name }) | Select-Object -First 1
        if (-not $prev) {
            $desc = $script:ZcMarker + ':' + $script:RunId
            $owned = $false
            $disabled = $false
            try {
                Set-NetFirewallRule -Name $r.Name -Description $desc -Enabled False -ErrorAction Stop
                $owned = $true
                $disabled = $true
            } catch {
                try { Set-NetFirewallRule -Name $r.Name -Enabled False -ErrorAction Stop; $disabled = $true } catch { }
            }
            $created += [pscustomobject]@{ Name = [string]$r.Name; Owned = $owned; Disabled = $disabled; Description = $desc }
            if (-not $disabled) { $ownFailed += [string]$r.Name }
        } elseif ([string]$prev.Enabled -ne [string]$r.Enabled) {
            $existing += [pscustomobject]@{ Name = [string]$r.Name; EnabledBefore = [string]$prev.Enabled }
            # Enable-PSRemoting can turn a previously disabled default rule on.
            # That change is ours, so undo it immediately; otherwise a fresh
            # host would remain broadly exposed despite the scoped rule.
            if ([string]$prev.Enabled -eq 'False' -and [string]$r.Enabled -eq 'True') {
                try {
                    Set-NetFirewallRule -Name $r.Name -Enabled False -ErrorAction Stop
                } catch {
                    $ownFailed += [string]$r.Name
                }
            }
        }
    }
    if ($created.Count -gt 0 -or $existing.Count -gt 0) {
        Add-SiteChange 'winrm.firewall' @{ Created = $created; ExistingBefore = $existing }
    }
    if ($ownFailed.Count -gt 0) {
        $msg = 'Cannot disable broad WinRM firewall rule(s) created by Enable-PSRemoting: ' + ($ownFailed -join ', ')
        if (-not $AllowBroadWinRM) {
            throw ($msg + '. Refusing to claim Tailscale-only exposure. Use -AllowBroadWinRM only for an isolated lab.')
        }
        Write-Warn2 $msg
    }
    $script:WinRmBroadRulesRemaining = @()
    try {
        $currentRules = @(Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Enabled = [string]$_.Enabled }
        })
        $script:WinRmBroadRulesRemaining = @($currentRules | Where-Object { [string]$_.Enabled -eq 'True' } | ForEach-Object { [string]$_.Name })
    } catch {
        $script:WinRmBroadRulesRemaining = @($afterRules | Where-Object { [string]$_.Enabled -eq 'True' } | ForEach-Object { [string]$_.Name })
    }
    if ($script:WinRmBroadRulesRemaining.Count -gt 0) {
        Write-Warn2 ('pre-existing WinRM firewall rule(s) remain enabled: ' + ($script:WinRmBroadRulesRemaining -join ', '))
    }

    $afterListener = Get-ZcWinRmListenerState
    if ([int]$beforeListener.Count -eq 0 -and [int]$afterListener.Count -gt 0) {
        Add-SiteChange 'winrm.listener' @{ Created = $true; CountBefore = 0; HttpBefore = $false }
    }

    $ruleName = 'ZCode-WinRM-Tailscale-' + $script:RunId
    $desc = $script:ZcMarker + ':' + $script:RunId
    $equivalent = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
        [string]$_.Name -like 'ZCode-WinRM-Tailscale*' -and
        [string]$_.Enabled -eq 'True' -and
        [string]$_.Direction -eq 'Inbound' -and
        [string]$_.Action -eq 'Allow'
    })
    $reuse = $null
    foreach ($eq in $equivalent) {
        $ra = @($eq.RemoteAddress | ForEach-Object { [string]$_ }) -join ','
        if ($ra -eq '100.64.0.0/10') { $reuse = $eq; break }
    }
    if ($reuse) {
        Write-Warn2 "existing Tailscale-scoped WinRM rule detected; reusing without claiming ownership: $($reuse.Name)"
    } else {
        New-NetFirewallRule -Name $ruleName -DisplayName 'ZCode WinRM (Tailscale)' -Description $desc `
            -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -RemoteAddress '100.64.0.0/10' -Profile Any -ErrorAction Stop | Out-Null
        Add-SiteChange 'firewall.rule' @{ Name = $ruleName; Description = $desc; LocalPort = 5985; RemoteIp = '100.64.0.0/10' }
    }

    Write-Ok 'WinRM enabled with a Tailscale-scoped rule.'
}

function Set-OpsAccount([string]$User, [string]$Password) {
    Write-Step "configuring ops account '$User'..."
    Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction SilentlyContinue
    $existing = Get-ZcLocalUserState $User
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force

    if ($existing) {
        if (-not $AllowExistingAccountUpdate) {
            throw "Local user '$User' already exists. Refusing to reset its password. Use a different OpsUser or -AllowExistingAccountUpdate (irreversible password change)."
        }
        Set-LocalUser -Name $User -Password $secure -ErrorAction Stop
        Add-SiteChange 'account.update' @{ Name = $User; Sid = [string]$existing.Sid; PasswordReset = $true }
    } else {
        New-LocalUser -Name $User -Password $secure -Description 'zcode remote ops account' -AccountNeverExpires -PasswordNeverExpires:$false -ErrorAction Stop | Out-Null
        $createdUser = Get-ZcLocalUserState $User
        if (-not $createdUser) { throw "Account '$User' was not created." }
        Add-SiteChange 'account.create' @{ Name = $User; Sid = [string]$createdUser.Sid; Created = $true }
    }

    $adminSid = 'S-1-5-32-544'
    $isAdmin = $false
    try {
        $isAdmin = @(Get-LocalGroupMember -SID $adminSid -ErrorAction Stop | Where-Object {
            [string]$_.Name -match ('\\' + [regex]::Escape($User) + '$')
        }).Count -gt 0
    } catch { }
    if (-not $isAdmin) {
        Add-LocalGroupMember -SID $adminSid -Member $User -ErrorAction Stop
    }

    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $regName = 'LocalAccountTokenFilterPolicy'
    $before = Get-ZcRegState -Path $regPath -Name $regName
    Set-ItemProperty -Path $regPath -Name $regName -Value 1 -Type DWord -Force
    Add-SiteChange 'registry.latfp' @{
        Path = $regPath
        Name = $regName
        ExistedBefore = [bool]$before.Exists
        ValueBefore = $before.Value
        ValueSet = 1
    }
    Write-Ok "account ready (admin group, LocalAccountTokenFilterPolicy=1)."
}

function Write-AccessResult([string]$TsIp, [string]$Site) {
    $marker = 'GeneratedBy=' + $script:ZcToolName + ':' + $script:RunId
    $content = @(
        "JumpHost=$TsIp"
        "OpsUser=$OpsUser"
        "MachineName=$env:COMPUTERNAME"
        "SiteName=$Site"
        "Generated=$(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        $marker
    ) -join "`r`n"
    $utf8NoBom = New-Object Text.UTF8Encoding($false)

    $resultPath = Join-Path $PSScriptRoot 'access-result.txt'
    $backupPath = ''
    $snap = $script:Journal.Snapshot.AccessResult
    if (Test-Path -LiteralPath $resultPath) {
        if (-not [bool]$snap.HasMarker) {
            $backupPath = $resultPath + '.backup-' + (Get-Date -Format 'yyyyMMddHHmmss')
            Move-Item -LiteralPath $resultPath -Destination $backupPath -Force
        }
    }
    [IO.File]::WriteAllText($resultPath, $content, $utf8NoBom)
    Add-SiteChange 'file.access-result' @{ Path = $resultPath; Marker = $marker; BackupPath = $backupPath }
    Write-Ok "result written: $resultPath"

    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) {
            $desktopPath = Join-Path $desktop 'access-result.txt'
            $desktopBackup = ''
            if (Test-Path -LiteralPath $desktopPath) {
                $oldText = Get-Content -LiteralPath $desktopPath -Raw -ErrorAction SilentlyContinue
                $hasMarker = [bool]($oldText -and $oldText.IndexOf('GeneratedBy=' + $script:ZcToolName + ':', [StringComparison]::OrdinalIgnoreCase) -ge 0)
                if (-not $hasMarker) {
                    $desktopBackup = $desktopPath + '.backup-' + (Get-Date -Format 'yyyyMMddHHmmss')
                    Move-Item -LiteralPath $desktopPath -Destination $desktopBackup -Force
                }
            }
            [IO.File]::WriteAllText($desktopPath, $content, $utf8NoBom)
            Add-SiteChange 'file.access-result' @{ Path = $desktopPath; Marker = $marker; BackupPath = $desktopBackup }
        }
    } catch { }

    $cfgPath = Join-Path $PSScriptRoot 'config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.PSObject.Properties.Name -contains 'jumpHost') {
                $cfg.jumpHost = $TsIp
            } else {
                $cfg | Add-Member -NotePropertyName jumpHost -NotePropertyValue $TsIp
            }
            [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 6), $utf8NoBom)
            Add-SiteChange 'file.config' @{ Path = $cfgPath; Updated = $true }
            Write-Ok "config.json updated: jumpHost=$TsIp"
        } catch {
            Write-Warn2 "config.json update failed (non-fatal): $($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------------ main ---
if (-not (Test-Admin)) {
    throw 'Run this script as Administrator (right-click -> Run as administrator).'
}

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " Jump host setup: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

try {
    $script:StateRoot = Initialize-ZcStateRoot -Path $StateRoot
    $script:RunId = New-ZcRunId 'site'
    $script:RunDir = Join-Path (Join-Path $script:StateRoot 'runs') $script:RunId
    New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null

    $snapshot = Get-SiteSnapshot
    $script:Journal = New-ZcJournal -Phase 'site' -SiteName $SiteName -HostName $env:COMPUTERNAME -Snapshot $snapshot -RunId $script:RunId
    Save-SiteJournal
    Add-SiteChange 'tempdir' @{ Path = $script:RunDir }
    Write-Host " Run ID: $($script:RunId)" -ForegroundColor DarkGray
    Write-Host " Journal: $(Get-ZcJournalPath -Root $script:StateRoot -RunId $script:RunId)" -ForegroundColor DarkGray

    if (-not $SkipTailscale) {
        Install-Tailscale
        Join-Tailnet $AuthKey $AdvertiseRoutes
    } else {
        Write-Warn2 'Tailscale step skipped (-SkipTailscale).'
    }

    if (-not $SkipWinRM) {
        Enable-Remoting
        $pw = Get-PlainPassword $OpsPassword "Password for ops account '$OpsUser'"
        Set-OpsAccount $OpsUser $pw
    } else {
        Write-Warn2 'WinRM step skipped (-SkipWinRM).'
    }

    if ($AdvertiseRoutes.Count -gt 0) {
        Write-Host ''
        Write-Warn2 'Subnet router: approve the advertised route in the Tailscale admin console.'
        Write-Warn2 "Routes: $($AdvertiseRoutes -join ', ')"
    }

    $tsIp = Get-TailscaleIp
    if ($tsIp) { Write-AccessResult $tsIp $SiteName }

    $script:Journal.Status = 'Applied'
    Save-SiteJournal

    Write-Host ''
    Write-Host '============================ READY ============================' -ForegroundColor Green
    Write-Host "Machine          : $env:COMPUTERNAME"
    Write-Host "Tailscale IPv4   : $tsIp"
    if ($AdvertiseRoutes.Count -gt 0) {
        Write-Host "Advertised routes: $($AdvertiseRoutes -join ', ')  (approve in admin console)"
    }
    Write-Host "Ops account      : $OpsUser (password set by you)"
    Write-Host "Run ID           : $script:RunId"
    Write-Host "Undo on this host: .\03-undo.ps1 -RunId $script:RunId"
    if ($script:WinRmBroadRulesRemaining.Count -gt 0) {
        Write-Warn2 'Pre-existing WinRM firewall rules remain enabled; exposure is not limited to Tailscale on this host.'
    }
    Write-Host ''
    Write-Host 'IPv4 addresses on this machine:'
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Select-Object IPAddress, InterfaceAlias |
        Format-Table -AutoSize | Out-String | Write-Host
    Write-Host 'Next step - on YOUR local PC run:'
    Write-Host "  .\02-connect-site.ps1 -JumpHost $tsIp -JumpUser $OpsUser" -ForegroundColor White
    Write-Host '==============================================================' -ForegroundColor Green
}
catch {
    $original = $_.Exception.Message
    Write-Host ''
    Write-Host "[FAIL] $original" -ForegroundColor Red
    if ($script:Journal) {
        try {
            $script:Journal.Status = 'Failed'
            $script:Journal | Add-Member -NotePropertyName Error -NotePropertyValue $original -Force
            Save-SiteJournal
            if (-not $NoRollbackOnFailure) {
                Write-Host 'Rolling back resources created by this run...' -ForegroundColor Yellow
                $saved = Read-ZcJournal -Path (Get-ZcJournalPath -Root $script:StateRoot -RunId $script:RunId)
                $undo = Invoke-ZcUndoJournal -Root $script:StateRoot -Journal $saved
                $script:Journal.UndoResults = @($undo.Results)
                if (@($undo.Errors).Count -eq 0) { $script:Journal.Status = 'RolledBack' } else { $script:Journal.Status = 'RollbackPartial' }
                Save-SiteJournal
                foreach ($item in @($undo.Results)) {
                    $color = $(if ($item.Status -eq 'Error') { 'Red' } else { 'Gray' })
                    Write-Host ("  [{0}] {1} {2}: {3}" -f $item.Status, $item.Kind, $item.Target, $item.Detail) -ForegroundColor $color
                }
                if (@($undo.Errors).Count -gt 0) {
                    Write-Warn2 'Rollback was partial. Review the journal and run 03-undo.ps1 manually.'
                }
            }
        } catch {
            Write-Warn2 "Journal/rollback failed: $($_.Exception.Message)"
        }
    }
    exit 1
}
