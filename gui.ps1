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
. (Join-Path $script:root 'zc-config.ps1')
. (Join-Path $script:root 'zc-process.ps1')
$script:CredentialRoot = $null
$script:LogRoot = $null
$script:actionButtons = @()
$script:inputControls = @()
$script:undoPreviewSignature = $null
$script:activeAction = ''

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList (Get-ZcPowerShellArguments -ScriptPath $PSCommandPath) -Verb RunAs
    exit
}

$script:cfg = $null
if (Test-Path -LiteralPath $configPath) {
    $script:cfg = Read-ZcConfig -Path $configPath -AllowMissingCredentials
}
function Cfg([string]$name, $default) {
    if ($script:cfg -and ($script:cfg.PSObject.Properties.Name -contains $name) -and $null -ne $script:cfg.$name) { return $script:cfg.$name }
    return $default
}
function ToInt([string]$s, [int]$def) {
    $v = 0
    if ([int]::TryParse($s.Trim(), [ref]$v)) { return $v }
    throw '端口必须填写整数。'
}

$form = New-Object Windows.Forms.Form
$form.Text = '现场远程接入工具'
$form.ClientSize = New-Object Drawing.Size(920, ([Math]::Min(840, [Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - 90)))
$form.AutoScroll = $true
$form.AutoScrollMinSize = New-Object Drawing.Size(920, 840)
$form.StartPosition = 'CenterScreen'
$form.MaximizeBox = $false
$form.FormBorderStyle = 'FixedSingle'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

function Add-Label($parent, [int]$x, [int]$y, [int]$w, [string]$text, [switch]$PassThru) {
    $l = New-Object Windows.Forms.Label
    $l.Left = $x; $l.Top = $y; $l.Width = $w; $l.Text = $text
    $parent.Controls.Add($l)
    if ($PassThru) { return $l }
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
    $script:actionButtons += $b
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
$gLocal = Add-Group 12 106 880 210 '本机连接（在你的电脑上操作）'
Add-Label $gLocal 24 29 90 '连接方式'
$script:cmbMode = New-Object Windows.Forms.ComboBox
$script:cmbMode.Left = 120; $script:cmbMode.Top = 26; $script:cmbMode.Width = 280
$script:cmbMode.DropDownStyle = 'DropDownList'
[void]$script:cmbMode.Items.AddRange(@('直连另一台电脑', '经跳板机访问内网服务器'))
$script:cmbMode.SelectedIndex = $(if ((Cfg 'connectionMode' 'Direct') -eq 'Forward') {1} else {0})
$gLocal.Controls.Add($script:cmbMode)
Add-Label $gLocal 420 29 430 '直连只验证远程命令；转发模式另填服务器地址。'
Add-Label $gLocal 24 65 90 '对端 Tailscale IP'
$script:tbJump = Add-Text $gLocal 120 62 280 ([string](Cfg 'jumpHost' ''))
Add-Label $gLocal 420 65 100 '目标服务器 IP'
$script:tbTarget = Add-Text $gLocal 524 62 300 ([string](Cfg 'targetServer' ''))
Add-Label $gLocal 24 101 60 'MySQL'
$script:tbDb = Add-Text $gLocal 100 98 70 ([string](Cfg 'dbPort' 13306))
Add-Label $gLocal 190 101 60 'Web'
$script:tbWeb = Add-Text $gLocal 260 98 70 ([string](Cfg 'webPort' 18080))
Add-Label $gLocal 350 101 60 'RDP'
$script:tbRdp = Add-Text $gLocal 420 98 70 ([string](Cfg 'rdpPort' 13389))
Add-Label $gLocal 510 101 90 '额外转发'
$extraText = (@(Cfg 'extraForwards' @()) -join "`r`n")
$script:tbExtra = Add-Text $gLocal 610 94 230 $extraText -Multiline -h 56
Add-Label $gLocal 24 138 550 '额外格式：23389:10.0.0.20:3389；首次接入先用“连接 / 配置”。'
Add-Btn $gLocal 24 166 120 '只读检查' {
    Invoke-GuiAction {
        Assert-ConnectionFields
        Save-Config
        Start-Engine 'run.ps1' @('-Mode', '2', '-VerifyOnly')
    }
} | Out-Null
Add-Btn $gLocal 156 166 120 '连接 / 配置' {
    Invoke-GuiAction {
        Assert-ConnectionFields
        Save-Config
        Start-Engine 'run.ps1' @('-Mode', '2')
    }
} | Out-Null

# --- site setup (01) ---
$gSite = Add-Group 12 324 880 120 '对端初始化（在另一台电脑上操作；当前仍限隔离测试机）'
Add-Label $gSite 24 29 80 'auth key'
$script:tbAuthKey = Add-Text $gSite 110 26 360 ([string](Cfg 'authKey' '')) -Password
$script:chkOnline = Add-Check $gSite 500 28 340 '在线下载安装包（不用内置 MSI）' ([bool](Cfg 'useOnlineInstaller' $false))
Add-Btn $gSite 24 70 150 '开始初始化' {
    if ([string]::IsNullOrWhiteSpace($script:tbAuthKey.Text) -or [string]::IsNullOrWhiteSpace($script:tbOpsPass.Text)) {
        [void][Windows.Forms.MessageBox]::Show('请填写 auth key 和运维口令。', '提示')
        return
    }
    if (-not (Confirm-GuiAction '这会安装 Tailscale、开启 WinRM、创建运维账号。仅限隔离测试机，继续？')) { return }
    Invoke-GuiAction {
        Save-Config
        $engineArgs = @('-Mode', '1', '-AllowExperimentalSiteSetup')
        if ($script:chkOnline.Checked) { $engineArgs += '-OnlineInstaller' }
        Start-Engine 'run.ps1' $engineArgs -Action 'SiteSetup'
    }
} | Out-Null
Add-Label $gSite 200 76 660 '实验功能：仅隔离测试机使用；成功后把 access-result.txt 或跳板机 Tailscale IP 带到本机。'

# --- undo (03) ---
$gUndo = Add-Group 12 452 880 130 '撤销（先预览本次会影响的记录，再执行）'
Add-Label $gUndo 24 29 60 '范围'
$script:cmbScope = New-Object Windows.Forms.ComboBox
$script:cmbScope.Left = 100; $script:cmbScope.Top = 26; $script:cmbScope.Width = 120
$script:cmbScope.DropDownStyle = 'DropDownList'
[void]$script:cmbScope.Items.AddRange(@('Site', 'Local', 'All'))
$script:cmbScope.SelectedIndex = 1
$gUndo.Controls.Add($script:cmbScope)
$script:chkRemove = Add-Check $gUndo 250 28 180 '同时卸载 Tailscale' $false
$script:chkUnjoin = Add-Check $gUndo 440 28 180 '同时登出节点' $false
Add-Btn $gUndo 24 60 150 '预览撤销' {
    Invoke-GuiAction {
        $script:undoPreviewSignature = $null
        Start-Engine '03-undo.ps1' ((Get-UndoArguments) + @('-DryRun')) -Action 'UndoPreview'
    }
} | Out-Null
Add-Btn $gUndo 190 60 150 '执行撤销' {
    Invoke-GuiAction {
        $engineArgs = @(Get-UndoArguments)
        if ($script:undoPreviewSignature -cne ($engineArgs -join "`n")) { throw '请先对当前范围、现场名和卸载选项成功执行一次“预览撤销”，并查看输出。' }
        $siteHint = $(if ($script:tbSite.Text.Trim()) {$script:tbSite.Text.Trim()} else {'当前主机该范围的全部现场'})
        if (-not (Confirm-GuiAction "将执行日志中的撤销计划。范围：$($script:cmbScope.SelectedItem)；现场：$siteHint。继续？")) { return }
        $script:undoPreviewSignature = $null
        Start-Engine '03-undo.ps1' ($engineArgs + @('-Force')) -Action 'Undo'
    }
} | Out-Null
Add-Label $gUndo 24 100 820 'Local 撤销本机配置；Site 必须在对端运行。填写现场名时，仅选择该现场的运行记录。' | Out-Null

# --- log + footer ---
Add-Label $form 12 594 100 '输出日志' | Out-Null
$script:log = New-Object Windows.Forms.TextBox
$script:log.Left = 12; $script:log.Top = 618; $script:log.Width = 880; $script:log.Height = 160
$script:log.Multiline = $true; $script:log.ReadOnly = $true; $script:log.ScrollBars = 'Vertical'
$script:log.Font = New-Object Drawing.Font('Consolas', 8.5)
$script:log.BackColor = [Drawing.Color]::White
$form.Controls.Add($script:log)
Add-Btn $form 12 792 120 '保存配置' { Invoke-GuiAction { Save-Config; $script:status.Text = '设置已保存；凭据已加密保存在当前 Windows 用户下' } } | Out-Null
Add-Btn $form 144 792 120 '打开工具目录' { Start-Process explorer.exe ('"' + $script:root + '"') } | Out-Null
$script:status = Add-Label $form 280 798 600 '就绪；首次接入请选择“连接 / 配置”' -PassThru
$script:inputControls = @($script:tbOpsUser,$script:tbOpsPass,$script:tbSite,$script:tbJump,$script:tbTarget,$script:tbDb,$script:tbWeb,$script:tbRdp,$script:tbExtra,$script:tbAuthKey,$script:chkOnline,$script:cmbMode,$script:cmbScope,$script:chkRemove,$script:chkUnjoin)

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
        connectionMode = $(if ($script:cmbMode.SelectedIndex -eq 1) {'Forward'} else {'Direct'})
        credentialId = [string](Cfg 'credentialId' '')
    }
    foreach ($port in @($obj.dbPort,$obj.webPort,$obj.rdpPort)) { if ($port -lt 1 -or $port -gt 65535) { throw '端口必须在 1 到 65535 之间。' } }
    $script:cfg = Save-ZcConfig -Path $configPath -Config $obj -CredentialRoot $script:CredentialRoot
}

# --- engine runner (child process; secrets stay in config.json, not the command line) ---
$script:io = $null
$script:proc = $null
$script:job = $null
function Invoke-GuiAction([scriptblock]$Action) {
    try { & $Action } catch {
        $message = $_.Exception.Message
        $script:status.Text = '未执行：' + $message
        $script:log.AppendText("`r`n[FAIL] $message`r`n")
        Show-GuiError $message
    }
}
function Confirm-GuiAction([string]$Text) {
    return ([Windows.Forms.MessageBox]::Show($Text, '确认', 'YesNo', 'Warning') -eq 'Yes')
}
function Show-GuiError([string]$Text) {
    [void][Windows.Forms.MessageBox]::Show($Text, '操作未完成', 'OK', 'Error')
}
function Assert-ConnectionFields {
    if (-not $script:tbJump.Text.Trim()) { throw '请填写对端电脑的 Tailscale IP。' }
    if (-not $script:tbOpsUser.Text.Trim() -or -not $script:tbOpsPass.Text) { throw '请填写对端的运维账号和口令。' }
    if ($script:cmbMode.SelectedIndex -eq 1 -and -not $script:tbTarget.Text.Trim()) { throw '转发模式必须明确填写目标服务器的内网 IP。' }
}
function Update-ConnectionFields {
    $forward = $script:cmbMode.SelectedIndex -eq 1
    foreach ($control in @($script:tbTarget,$script:tbDb,$script:tbWeb,$script:tbRdp,$script:tbExtra)) { $control.Enabled = $forward }
    $optional = [string]$script:cmbScope.SelectedItem -ne 'Local'
    $script:chkRemove.Enabled = $optional; $script:chkUnjoin.Enabled = $optional
}
function Set-GuiBusy([bool]$Busy) {
    foreach ($control in @($script:actionButtons) + @($script:inputControls)) { if ($control) { $control.Enabled = -not $Busy } }
    if (-not $Busy -and $script:cmbMode) { Update-ConnectionFields }
}
function Get-UndoArguments {
    $scope = [string]$script:cmbScope.SelectedItem
    $engineArgs = @('-Scope', $scope)
    if ($script:tbSite.Text.Trim()) { $engineArgs += @('-SiteName', $script:tbSite.Text.Trim()) }
    if ($scope -ne 'Local') {
        if ($script:chkRemove.Checked) { $engineArgs += '-RemoveTailscale' }
        if ($script:chkUnjoin.Checked) { $engineArgs += '-UnjoinTailscale' }
    }
    return $engineArgs
}
function Read-IntoLog {
    if (-not $script:job) { return }
    foreach ($stream in @(@('OutPath','OutPosition'),@('ErrPath','ErrPosition'))) {
        $p = [string]$script:job.($stream[0])
        if ($p -and (Test-Path -LiteralPath $p)) {
            $txt = Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($txt) {
                $pos = [int]$script:job.($stream[1])
                if ($txt.Length -gt $pos) {
                    $script:log.AppendText($txt.Substring($pos))
                    $script:job.($stream[1]) = $txt.Length
                }
            }
        }
    }
}
function Start-Engine([string]$scriptName, [string[]]$argList, [string]$Action = '') {
    if ($script:proc -and -not $script:proc.HasExited) {
        [void][Windows.Forms.MessageBox]::Show('已有任务在运行，请等待完成。', '提示')
        return
    }
    if ($Action -ne 'UndoPreview') { $script:undoPreviewSignature = $null }
    $script:activeAction = $Action
    $script:activeArguments = @($argList)
    $script:log.AppendText("`r`n===== $scriptName $($argList -join ' ') =====`r`n")
    $script:job = Start-ZcScriptProcess -ScriptPath (Join-Path $script:root $scriptName) -Arguments $argList -LogRoot $script:LogRoot
    $script:proc = $script:job.Process
    Set-GuiBusy $true
    $script:status.Text = "运行中：$scriptName"
    $script:timer.Start()
}

function Complete-Engine {
    $script:timer.Stop()
    try {
        $result = Get-ZcProcessResult -Job $script:job
        Read-IntoLog
        $script:log.AppendText("`r`n===== 结束 (exit=$($result.ExitCode)) =====`r`n")
        if (-not $result.Succeeded) {
            $script:undoPreviewSignature = $null
            $script:status.Text = "执行失败（退出码 $($result.ExitCode)），请查看输出日志"
        } else {
            $script:status.Text = '执行成功'
            if ($script:activeAction -eq 'UndoPreview') {
                $script:undoPreviewSignature = (@($script:activeArguments | Where-Object {$_ -ne '-DryRun'}) -join "`n")
                $script:status.Text = '预览成功；查看日志后可执行撤销'
            } elseif ($script:activeAction -eq 'SiteSetup') {
                $script:cfg = Read-ZcConfig -Path $configPath -CredentialRoot $script:CredentialRoot -AllowMissingCredentials
                $script:tbJump.Text = [string]$script:cfg.jumpHost
                $script:tbAuthKey.Text = ''
                Save-Config
                $script:status.Text = '初始化成功；对端地址已回填，入网密钥已从本地存储移除'
            }
        }
    } catch {
        $script:undoPreviewSignature = $null
        $script:status.Text = '无法确认结果：' + $_.Exception.Message
        $script:log.AppendText("`r`n[FAIL] $($_.Exception.Message)`r`n")
    } finally {
        try { Close-ZcProcessJob -Job $script:job } catch { $script:log.AppendText("`r`n[warn] Log cleanup: $($_.Exception.Message)`r`n") }
        $script:job = $null; $script:proc = $null
        Set-GuiBusy $false
    }
}

$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 600
$script:timer.Add_Tick({
    Read-IntoLog
    $script:log.SelectionStart = $script:log.Text.Length
    $script:log.ScrollToCaret()
    if ($script:proc -and $script:proc.HasExited) {
        Complete-Engine
    }
})

$script:cmbMode.Add_SelectedIndexChanged({ Update-ConnectionFields })
$script:cmbScope.Add_SelectedIndexChanged({ Update-ConnectionFields })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:proc -and -not $script:proc.HasExited) {
        $eventArgs.Cancel = $true
        [void][Windows.Forms.MessageBox]::Show('任务仍在执行，请等待结束后关闭，避免留下后台操作。', '任务执行中')
    } elseif ($script:job) { Complete-Engine }
})
Update-ConnectionFields

[void]$form.ShowDialog()
