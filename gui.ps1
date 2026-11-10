#Requires -Version 5.1
<#
Remote access kit - simple GUI.
Double-click start.cmd (or gui.cmd). The window collects settings, writes
config.json next to this script, and runs 01/02/03 in a child process so the
window stays responsive. Run as Administrator (the script self-elevates).
#>
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$script:root = $PSScriptRoot
$configPath = Join-Path $script:root 'config.json'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) -Verb RunAs
    exit
}

$script:cfg = $null
if (Test-Path -LiteralPath $configPath) {
    try { $script:cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
function Cfg([string]$name, $default) {
    if ($script:cfg -and ($script:cfg.PSObject.Properties.Name -contains $name) -and $null -ne $script:cfg.$name) { return $script:cfg.$name }
    return $default
}
function ToInt([string]$s, [int]$def) {
    $v = 0
    if ([int]::TryParse($s.Trim(), [ref]$v)) { return $v }
    return $def
}

$form = New-Object Windows.Forms.Form
$form.Text = '现场远程接入工具'
$form.ClientSize = New-Object Drawing.Size(920, 800)
$form.StartPosition = 'CenterScreen'
$form.MaximizeBox = $false
$form.FormBorderStyle = 'FixedSingle'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

function Add-Label($parent, [int]$x, [int]$y, [int]$w, [string]$text) {
    $l = New-Object Windows.Forms.Label
    $l.Left = $x; $l.Top = $y; $l.Width = $w; $l.Text = $text
    $parent.Controls.Add($l)
    return $l
}
function Add-Text($parent, [int]$x, [int]$y, [int]$w, [string]$text, [switch]$Password, [switch]$Multiline, [int]$h = 0) {
    $t = New-Object Windows.Forms.TextBox
    $t.Left = $x; $t.Top = $y; $t.Width = $w; $t.Text = $text
    if ($Password) { $t.UseSystemPasswordChar = $true }
    if ($Multiline) { $t.Multiline = $true; $t.Height = $h; $t.ScrollBars = 'Vertical'; $t.AcceptsReturn = $true }
    $parent.Controls.Add($t)
    return $t
}
function Add-Btn($parent, [int]$x, [int]$y, [int]$w, [string]$text, [scriptblock]$onClick) {
    $b = New-Object Windows.Forms.Button
    $b.Left = $x; $b.Top = $y; $b.Width = $w; $b.Height = 30; $b.Text = $text
    $b.Add_Click($onClick)
    $parent.Controls.Add($b)
    return $b
}
function Add-Check($parent, [int]$x, [int]$y, [int]$w, [string]$text, [bool]$checked) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Left = $x; $c.Top = $y; $c.Width = $w; $c.Text = $text; $c.Checked = $checked
    $parent.Controls.Add($c)
    return $c
}
function Add-Group([int]$x, [int]$y, [int]$w, [int]$h, [string]$text) {
    $g = New-Object Windows.Forms.GroupBox
    $g.Left = $x; $g.Top = $y; $g.Width = $w; $g.Height = $h; $g.Text = $text
    $form.Controls.Add($g)
    return $g
}

# --- common settings ---
$gCommon = Add-Group 12 12 880 86 '通用（两台都会用到）'
Add-Label $gCommon 24 29 80 '运维账号'
$script:tbOpsUser = Add-Text $gCommon 110 26 160 ([string](Cfg 'opsUser' 'zcode_ops'))
Add-Label $gCommon 300 29 70 '运维口令'
$script:tbOpsPass = Add-Text $gCommon 376 26 160 ([string](Cfg 'opsPassword' '')) -Password
Add-Label $gCommon 566 29 60 '现场名'
$script:tbSite = Add-Text $gCommon 630 26 230 ([string](Cfg 'siteName' ''))

# --- local connect (02) ---
$gLocal = Add-Group 12 106 880 190 '本机连接（02：连跳板机 / 建端口转发）'
Add-Label $gLocal 24 29 90 '跳板机 IP'
$script:tbJump = Add-Text $gLocal 120 26 280 ([string](Cfg 'jumpHost' ''))
Add-Label $gLocal 420 29 100 '目标服务器 IP'
$script:tbTarget = Add-Text $gLocal 524 26 300 ([string](Cfg 'targetServer' ''))
Add-Label $gLocal 24 65 60 'MySQL'
$script:tbDb = Add-Text $gLocal 100 62 70 ([string](Cfg 'dbPort' 13306))
Add-Label $gLocal 190 65 60 'Web'
$script:tbWeb = Add-Text $gLocal 260 62 70 ([string](Cfg 'webPort' 18080))
Add-Label $gLocal 350 65 60 'RDP'
$script:tbRdp = Add-Text $gLocal 420 62 70 ([string](Cfg 'rdpPort' 13389))
Add-Label $gLocal 510 65 90 '额外转发'
$extraText = (@(Cfg 'extraForwards' @()) -join "`r`n")
$script:tbExtra = Add-Text $gLocal 610 58 290 $extraText -Multiline -h 56
Add-Label $gLocal 24 122 400 '额外格式：23389:10.0.0.20:3389（每行一条，可留空）'
Add-Btn $gLocal 24 142 120 '只读检查' {
    if ([string]::IsNullOrWhiteSpace($script:tbJump.Text)) {
        [void][Windows.Forms.MessageBox]::Show('请先填写跳板机的 Tailscale IP。', '提示')
        return
    }
    Save-Config
    Start-Engine 'run.ps1' @('-Mode', '2', '-VerifyOnly')
} | Out-Null
Add-Btn $gLocal 156 142 120 '连接 / 修复' {
    if ([string]::IsNullOrWhiteSpace($script:tbJump.Text)) {
        [void][Windows.Forms.MessageBox]::Show('请先填写跳板机的 Tailscale IP。', '提示')
        return
    }
    Save-Config
    Start-Engine 'run.ps1' @('-Mode', '2')
} | Out-Null

# --- site setup (01) ---
$gSite = Add-Group 12 304 880 120 '现场初始化（01：装 Tailscale / 开 WinRM / 建运维账号）'
Add-Label $gSite 24 29 80 'auth key'
$script:tbAuthKey = Add-Text $gSite 110 26 360 ([string](Cfg 'authKey' '')) -Password
$script:chkOnline = Add-Check $gSite 500 28 340 '在线下载安装包（不用内置 MSI）' ([bool](Cfg 'useOnlineInstaller' $false))
Add-Btn $gSite 24 70 150 '开始初始化' {
    if ([string]::IsNullOrWhiteSpace($script:tbAuthKey.Text) -or [string]::IsNullOrWhiteSpace($script:tbOpsPass.Text)) {
        [void][Windows.Forms.MessageBox]::Show('请填写 auth key 和运维口令。', '提示')
        return
    }
    $r = [Windows.Forms.MessageBox]::Show('这会安装 Tailscale、开启 WinRM、创建运维账号。仅限隔离测试机，继续？', '确认', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    Save-Config
    $args = @('-Mode', '1', '-AllowExperimentalSiteSetup')
    if ($script:chkOnline.Checked) { $args += '-OnlineInstaller' }
    Start-Engine 'run.ps1' $args
} | Out-Null
Add-Label $gSite 200 76 660 '实验功能：仅隔离测试机使用；成功后把 access-result.txt 或跳板机 Tailscale IP 带到本机。'

# --- undo (03) ---
$gUndo = Add-Group 12 432 880 100 '撤销（03）'
Add-Label $gUndo 24 29 60 '范围'
$script:cmbScope = New-Object Windows.Forms.ComboBox
$script:cmbScope.Left = 100; $script:cmbScope.Top = 26; $script:cmbScope.Width = 120
$script:cmbScope.DropDownStyle = 'DropDownList'
[void]$script:cmbScope.Items.AddRange(@('Site', 'Local', 'All'))
$script:cmbScope.SelectedIndex = 0
$gUndo.Controls.Add($script:cmbScope)
$script:chkRemove = Add-Check $gUndo 250 28 180 '同时卸载 Tailscale' $false
$script:chkUnjoin = Add-Check $gUndo 440 28 180 '同时登出节点' $false
Add-Btn $gUndo 24 60 150 '执行撤销' {
    $scope = [string]$script:cmbScope.SelectedItem
    if (-not $scope) { $scope = 'Site' }
    $r = [Windows.Forms.MessageBox]::Show(("将在 $scope 范围执行撤销（03-undo -Force）。继续？"), '确认', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $args = @('-Scope', $scope, '-Force')
    if ($scope -ne 'Local') {
        if ($script:chkRemove.Checked) { $args += '-RemoveTailscale' }
        if ($script:chkUnjoin.Checked) { $args += '-UnjoinTailscale' }
    }
    Start-Engine '03-undo.ps1' $args
} | Out-Null

# --- log + footer ---
Add-Label $form 12 544 100 '输出日志' | Out-Null
$script:log = New-Object Windows.Forms.TextBox
$script:log.Left = 12; $script:log.Top = 566; $script:log.Width = 880; $script:log.Height = 180
$script:log.Multiline = $true; $script:log.ReadOnly = $true; $script:log.ScrollBars = 'Vertical'
$script:log.Font = New-Object Drawing.Font('Consolas', 8.5)
$script:log.BackColor = [Drawing.Color]::White
$form.Controls.Add($script:log)
Add-Btn $form 12 756 120 '保存配置' { Save-Config; $script:status.Text = '已写入 config.json' } | Out-Null
Add-Btn $form 144 756 120 '打开工具目录' { Start-Process explorer.exe $script:root } | Out-Null
$script:status = Add-Label $form 280 762 600 '就绪'

# --- config persistence ---
function Save-Config {
    $obj = [ordered]@{
        authKey = $script:tbAuthKey.Text.Trim()
        opsUser = $script:tbOpsUser.Text.Trim()
        opsPassword = $script:tbOpsPass.Text
        siteName = $script:tbSite.Text.Trim()
        jumpHost = $script:tbJump.Text.Trim()
        targetServer = $script:tbTarget.Text.Trim()
        dbPort = (ToInt $script:tbDb.Text 13306)
        webPort = (ToInt $script:tbWeb.Text 18080)
        rdpPort = (ToInt $script:tbRdp.Text 13389)
        extraForwards = @($script:tbExtra.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        advertiseRoutes = @()
        useOnlineInstaller = [bool]$script:chkOnline.Checked
        profilePath = ''
    }
    [IO.File]::WriteAllText($configPath, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

# --- engine runner (child process; secrets stay in config.json, not the command line) ---
$script:io = $null
$script:proc = $null
function Read-IntoLog {
    if (-not $script:io) { return }
    foreach ($k in @('out', 'err')) {
        $p = $script:io[$k]
        if ($p -and (Test-Path -LiteralPath $p)) {
            $txt = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            if ($txt) {
                $pk = $k + 'pos'
                $pos = [int]$script:io[$pk]
                if ($txt.Length -gt $pos) {
                    $script:log.AppendText($txt.Substring($pos))
                    $script:io[$pk] = $txt.Length
                }
            }
        }
    }
}
function Start-Engine([string]$scriptName, [string[]]$argList) {
    if ($script:proc -and -not $script:proc.HasExited) {
        [void][Windows.Forms.MessageBox]::Show('已有任务在运行，请等待完成。', '提示')
        return
    }
    $script:io = @{
        out = (Join-Path $env:TEMP ('kit-gui-out-' + [guid]::NewGuid().ToString('N') + '.log'))
        err = (Join-Path $env:TEMP ('kit-gui-err-' + [guid]::NewGuid().ToString('N') + '.log'))
        opos = 0; epos = 0
    }
    $script:log.AppendText("`r`n===== $scriptName $($argList -join ' ') =====`r`n")
    $argString = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $script:root $scriptName) + '"'
    foreach ($a in $argList) { $argString += ' ' + $a }
    $script:proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argString -PassThru -WindowStyle Hidden -RedirectStandardOutput $script:io.out -RedirectStandardError $script:io.err
    $script:status.Text = "运行中：$scriptName"
    $script:timer.Start()
}

$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 600
$script:timer.Add_Tick({
    Read-IntoLog
    $script:log.SelectionStart = $script:log.Text.Length
    $script:log.ScrollToCaret()
    if ($script:proc -and $script:proc.HasExited) {
        Start-Sleep -Milliseconds 200
        Read-IntoLog
        $script:timer.Stop()
        $code = $null
        try { $code = $script:proc.ExitCode } catch { }
        $script:log.AppendText("`r`n===== 结束 (exit=$code) =====`r`n")
        $script:status.Text = '就绪'
        $script:proc = $null
    }
})

[void]$form.ShowDialog()
