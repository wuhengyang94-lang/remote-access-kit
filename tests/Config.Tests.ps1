#Requires -Version 5.1
# Real current-user DPAPI with synthetic secrets and an isolated temporary store.
$ErrorActionPreference = 'Stop'
$kit = Split-Path $PSScriptRoot -Parent
$root = Join-Path $env:TEMP ('kit-config-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$configPath = Join-Path $root 'config.json'
$script:CredentialRoot = Join-Path $root 'credentials'
$lib = Join-Path $kit 'zc-config.ps1'
if (Test-Path -LiteralPath $lib) { . $lib }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $kit 'gui.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'GUI parse errors.' }
$save = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-Config' }, $true)
$cfgHelper = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Cfg' }, $true)
. ([scriptblock]::Create($cfgHelper[0].Extent.Text))
. ([scriptblock]::Create($save[0].Extent.Text))
$script:cfg = $null
$script:tbAuthKey = [pscustomobject]@{Text='SYNTHETIC-key-value'}
$script:tbOpsUser = [pscustomobject]@{Text='fake_ops'}
$script:tbOpsPass = [pscustomobject]@{Text='SYNTHETIC-password-value'}
$script:tbSite = [pscustomobject]@{Text='offline'}
$script:tbJump = [pscustomobject]@{Text='100.64.0.10'}
$script:tbTarget = [pscustomobject]@{Text=''}
$script:tbDb = [pscustomobject]@{Text='13306'}
$script:tbWeb = [pscustomobject]@{Text='18080'}
$script:tbRdp = [pscustomobject]@{Text='13389'}
$script:tbExtra = [pscustomobject]@{Lines=@()}
$script:chkOnline = [pscustomobject]@{Checked=$false}
$script:cmbMode = [pscustomobject]@{SelectedIndex=0;SelectedItem='Direct'}
function ToInt([string]$s, [int]$default) { $v=0; if ([int]::TryParse($s,[ref]$v)) { return $v }; return $default }
function Assert-True([bool]$value,[string]$message) { if (-not $value) { throw "ASSERT: $message" } }
$passed=0
Save-Config
$public = [IO.File]::ReadAllText($configPath)
Assert-True (-not ($public -match 'SYNTHETIC-password-value|SYNTHETIC-key-value')) 'Public config must not contain plaintext credentials.'
$passed++
$loaded = Read-ZcConfig -Path $configPath -CredentialRoot $script:CredentialRoot
Assert-True ($loaded.opsPassword -ceq $script:tbOpsPass.Text -and $loaded.authKey -ceq $script:tbAuthKey.Text) 'DPAPI credentials must round-trip for the current Windows user.'
$passed++
$vaultText = @(Get-ChildItem -LiteralPath $script:CredentialRoot -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
Assert-True (-not ($vaultText -match 'SYNTHETIC-password-value|SYNTHETIC-key-value')) 'The local credential store must contain ciphertext only.'
$passed++
$acl = Get-Acl -LiteralPath $script:CredentialRoot
Assert-True ($acl.AreAccessRulesProtected) 'Credential directory must disable inherited permissions.'
$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$allowed = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
Assert-True (@($allowed | Where-Object { $_ -notin @($userSid,'S-1-5-18') }).Count -eq 0) 'Credential ACL must allow only the current user and SYSTEM.'
$passed++
$message=''
try { Read-ZcConfig -Path $configPath -CredentialRoot (Join-Path $root 'other-user-store') | Out-Null } catch { $message=$_.Exception.Message }
Assert-True ($message -match 'credential|Credential') 'A config copied without its private store must report missing credentials.'
$passed++
$legacy = Join-Path $root 'legacy.json'
$copyPath=Join-Path $root 'copied-config.json'
Copy-Item -LiteralPath $configPath -Destination $copyPath
$message=''
try { Read-ZcConfig -Path $copyPath -CredentialRoot $script:CredentialRoot | Out-Null } catch { $message=$_.Exception.Message }
Assert-True ($message -match 'credential|Credential') 'A copied config must not silently borrow credentials belonging to another config path.'
$passed++
[IO.File]::WriteAllText($legacy,'{"opsUser":"fake_ops","opsPassword":"legacy-password","authKey":"legacy-key","jumpHost":"100.64.0.10"}')
$legacyCfg=Read-ZcConfig -Path $legacy -CredentialRoot $script:CredentialRoot -WarningAction SilentlyContinue
Assert-True ($legacyCfg.opsPassword -eq 'legacy-password') 'Legacy command-line configs must remain readable.'
Save-ZcConfig -Path $legacy -Config $legacyCfg -CredentialRoot $script:CredentialRoot | Out-Null
Assert-True (-not ([IO.File]::ReadAllText($legacy) -match 'legacy-password|legacy-key')) 'Saving a legacy config must migrate plaintext secrets.'
$passed++
Write-Output "PASS: $passed offline configuration checks (synthetic DPAPI data; no remote access)."
Write-Output "TEMP: $root"
