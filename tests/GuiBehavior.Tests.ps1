#Requires -Version 5.1
# Build real WinForms controls and invoke their real Click handlers. Child
# engines and confirmation/error dialogs are replaced; no system setup runs.
$ErrorActionPreference='Stop'
$sourceKit=Split-Path $PSScriptRoot -Parent
$testWorkspace=Join-Path $env:TEMP ('kit-gui-behavior-'+[guid]::NewGuid().ToString('N'))
$sandbox=Join-Path $testWorkspace 'folder with spaces'
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
foreach($lib in @('zc-config.ps1','zc-process.ps1','config.json')){Copy-Item -LiteralPath (Join-Path $sourceKit $lib) -Destination (Join-Path $sandbox $lib)}
$guiSource=[IO.File]::ReadAllText((Join-Path $sourceKit 'gui.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($guiSource,[ref]$tokens,[ref]$errors)
$exclude=@($ast.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('if (-not $principal.IsInRole(') -or $_.Extent.Text -eq '[void]$form.ShowDialog()' })
if($exclude.Count -ne 2){throw 'Expected exactly the elevation guard and dialog entry to be omitted in this harness.'}
foreach($statement in ($exclude | Sort-Object {$_.Extent.StartOffset} -Descending)){$guiSource=$guiSource.Remove($statement.Extent.StartOffset,$statement.Extent.EndOffset-$statement.Extent.StartOffset)}
$guiPath=Join-Path $sandbox 'gui-test.ps1'
[IO.File]::WriteAllText($guiPath,$guiSource,[Text.UTF8Encoding]::new($true))
$stub=@'
param([int]$Mode,[switch]$VerifyOnly,[switch]$AllowExperimentalSiteSetup,[switch]$OnlineInstaller)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'zc-config.ps1')
$cfg=Read-ZcConfig -Path (Join-Path $PSScriptRoot 'config.json') -CredentialRoot $env:KIT_GUI_TEST_VAULT
if($cfg.opsPassword -ne 'synthetic-password'){throw 'Private credentials did not reach the stub.'}
[ordered]@{Mode=$Mode;VerifyOnly=[bool]$VerifyOnly;ConnectionMode=$cfg.connectionMode;Target=$cfg.targetServer;Online=[bool]$OnlineInstaller} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'received.json') -Encoding UTF8
if($Mode -eq 1){
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'access-result.txt'),'JumpHost=100.64.0.20')
$public=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$public.jumpHost='100.64.0.20'
$public | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Encoding UTF8
}
Write-Output 'STUB_EXECUTED'
if($env:KIT_GUI_TEST_EXIT){exit ([int]$env:KIT_GUI_TEST_EXIT)}
exit 0
'@
[IO.File]::WriteAllText((Join-Path $sandbox 'run.ps1'),$stub)
$undoStub=@'
param([string]$Scope,[string]$SiteName,[switch]$DryRun,[switch]$Force,[switch]$RemoveTailscale,[switch]$UnjoinTailscale)
[ordered]@{Scope=$Scope;SiteName=$SiteName;DryRun=[bool]$DryRun;Force=[bool]$Force} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'undo-received.json') -Encoding UTF8
Write-Output 'STUB_UNDO_PLAN_OR_EXECUTION'
exit 0
'@
[IO.File]::WriteAllText((Join-Path $sandbox '03-undo.ps1'),$undoStub)
$priorVault=$env:KIT_GUI_TEST_VAULT;$priorExit=$env:KIT_GUI_TEST_EXIT
try {
    . $guiPath
    $script:CredentialRoot=Join-Path $testWorkspace 'credentials'
    $script:LogRoot=Join-Path $testWorkspace 'logs'
    $env:KIT_GUI_TEST_VAULT=$script:CredentialRoot
    $env:KIT_GUI_TEST_EXIT=''
    $script:alerts=New-Object Collections.ArrayList
    function Confirm-GuiAction([string]$Text){return $true}
    function Show-GuiError([string]$Text){[void]$script:alerts.Add($Text)}
    $script:tbOpsUser.Text='fake_ops';$script:tbOpsPass.Text='synthetic-password';$script:tbSite.Text='offline'
    $script:tbJump.Text='100.64.0.10'
    function Invoke-TestClick([int]$Index){
        $button=$script:actionButtons[$Index]
        $method=$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
        [void]$method.Invoke($button,@([EventArgs]::Empty))
    }
    function Wait-TestJob {
        $deadline=(Get-Date).AddSeconds(15)
        while($script:proc -and -not $script:proc.HasExited -and (Get-Date) -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 40}
        if($script:proc -and -not $script:proc.HasExited){$script:proc.Kill();throw 'GUI stub exceeded 15 seconds.'}
        if($script:job){Complete-Engine}
    }
    function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw "ASSERT: $Message"}}
    $passed=0
    Invoke-TestClick 1
    Assert-True (-not $script:actionButtons[1].Enabled) 'Action buttons must be disabled while a job is active.'
    Wait-TestJob
    $received=Get-Content -LiteralPath (Join-Path $sandbox 'received.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($received.Mode -eq 2 -and $received.ConnectionMode -eq 'Direct' -and -not $received.Target) 'Direct connect Click must launch direct access with no target server.'
    Assert-True ($script:log.Text -match 'exit=0') 'GUI must report successful completion.'
    $passed++
    Invoke-TestClick 0;Wait-TestJob
    $received=Get-Content -LiteralPath (Join-Path $sandbox 'received.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($received.VerifyOnly) 'Read-only Click must reach the engine as VerifyOnly.'
    $passed++
    $script:cmbMode.SelectedIndex=1;$script:tbTarget.Text='10.0.0.10'
    Invoke-TestClick 1;Wait-TestJob
    $received=Get-Content -LiteralPath (Join-Path $sandbox 'received.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($received.ConnectionMode -eq 'Forward' -and $received.Target -eq '10.0.0.10') 'Forward Click must preserve the server address.'
    $passed++
    $env:KIT_GUI_TEST_EXIT='7'
    Invoke-TestClick 1;Wait-TestJob
    Assert-True ($script:status.Text -match '7') 'A child failure must remain visible in the status.'
    $env:KIT_GUI_TEST_EXIT=''
    $passed++
    Invoke-TestClick 4
    Assert-True ($script:alerts.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $sandbox 'undo-received.json'))) 'Undo execution must require a preview.'
    $script:alerts.Clear()
    Invoke-TestClick 3;Wait-TestJob
    Assert-True ([bool]$script:undoPreviewSignature) 'A successful undo preview must be recorded.'
    Invoke-TestClick 1;Wait-TestJob
    Assert-True (-not $script:undoPreviewSignature) 'A connection after preview changes journals and must invalidate the old undo preview.'
    Invoke-TestClick 3;Wait-TestJob
    Invoke-TestClick 4;Wait-TestJob
    $undo=Get-Content -LiteralPath (Join-Path $sandbox 'undo-received.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($undo.Force -and -not $undo.DryRun -and $undo.Scope -eq 'Local' -and $undo.SiteName -eq 'offline') 'The reviewed undo selection must reach execution.'
    $passed++
    $script:tbAuthKey.Text='synthetic-key';$script:chkOnline.Checked=$true
    Invoke-TestClick 2;Wait-TestJob
    $received=Get-Content -LiteralPath (Join-Path $sandbox 'received.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $saved=Read-ZcConfig -Path (Join-Path $sandbox 'config.json') -CredentialRoot $script:CredentialRoot
    Assert-True ($received.Mode -eq 1 -and $received.Online -and $script:tbJump.Text -eq '100.64.0.20' -and -not $saved.authKey -and -not $script:tbAuthKey.Text) 'Initialization must refresh the address and clear the stored auth key.'
    $passed++
    Assert-True ($script:alerts.Count -eq 0) 'No unexpected GUI error dialog is allowed.'
    Assert-True (-not ([IO.File]::ReadAllText((Join-Path $sandbox 'config.json')) -match 'synthetic-password|synthetic-key')) 'GUI actions must not persist plaintext secrets.'
    $passed++
    $form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-20000,-20000)
    $form.ShowInTaskbar=$false
    $form.Show();$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $png=Join-Path $testWorkspace 'gui.png';$bitmap.Save($png,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose()
    Write-Output "PASS: $passed GUI event checks (actual controls; stub engines and dialogs; no remote access)."
    Write-Output "PREVIEW: $png"
} finally {
    if($script:proc -and -not $script:proc.HasExited){$script:proc.Kill()}
    if($form){$form.Dispose()}
    $env:KIT_GUI_TEST_VAULT=$priorVault;$env:KIT_GUI_TEST_EXIT=$priorExit
}
