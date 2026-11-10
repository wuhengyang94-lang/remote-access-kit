#Requires -Version 5.1
# Portable settings contain no credentials. Secrets use current-user DPAPI.
function Initialize-ZcPrivateDirectory {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory($full)
    # Read/write only the DACL; requesting SACL/owner changes can require
    # SeSecurityPrivilege even when the caller owns this new directory.
    $security = [IO.Directory]::GetAccessControl($full, [Security.AccessControl.AccessControlSections]::Access)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($existing in @($security.Access)) { [void]$security.RemoveAccessRuleSpecific($existing) }
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($sidText in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, 'None', 'Allow')
        [void]$security.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($full, $security)
    return $full
}

function Get-ZcCredentialRoot {
    param([string]$Override)
    if ($Override) { return [IO.Path]::GetFullPath($Override) }
    return (Join-Path $env:LOCALAPPDATA 'ZCodeRemoteAccess\credentials')
}

function ConvertTo-ZcConfigMap {
    param($Config)
    $copy = [ordered]@{}
    if ($Config -is [Collections.IDictionary]) {
        foreach ($key in $Config.Keys) { $copy[[string]$key] = $Config[$key] }
    } else {
        foreach ($property in $Config.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    }
    return $copy
}

function Protect-ZcText {
    param([string]$Text)
    if (-not $Text) { return '' }
    return (ConvertFrom-SecureString (ConvertTo-SecureString $Text -AsPlainText -Force))
}

function Unprotect-ZcText {
    param([string]$Ciphertext)
    if (-not $Ciphertext) { return '' }
    $secure = ConvertTo-SecureString $Ciphertext -ErrorAction Stop
    $buffer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($buffer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($buffer) }
}

function Save-ZcConfig {
    param([string]$Path, $Config, [string]$CredentialRoot)
    $values = ConvertTo-ZcConfigMap $Config
    $priorId = [string]$values['credentialId']
    if ($priorId -and $priorId -notmatch '^[0-9a-fA-F]{32}$') { throw 'Invalid credential ID in configuration.' }
    # Each save publishes a new immutable credential record before atomically
    # replacing the public reference, avoiding mismatched credentials on error.
    $id = [guid]::NewGuid().ToString('N')
    $binding = [IO.Path]::GetFullPath($Path)
    $privateRoot = Initialize-ZcPrivateDirectory (Get-ZcCredentialRoot $CredentialRoot)
    $secretPath = Join-Path $privateRoot ($id + '.json')
    $secret = [ordered]@{
        schema = 1
        userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        configPath = $binding
        opsPasswordProtected = Protect-ZcText ([string]$values['opsPassword'])
        authKeyProtected = Protect-ZcText ([string]$values['authKey'])
    }
    $encoding = New-Object Text.UTF8Encoding($false)
    $secretTemp = Join-Path $privateRoot ([guid]::NewGuid().ToString('N') + '.tmp')
    $publicTemp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $committed = $false
    try {
        [IO.File]::WriteAllText($secretTemp, ($secret | ConvertTo-Json -Depth 4), $encoding)
        # Replacing the file gives it the private directory's inherited ACL.
        Move-Item -LiteralPath $secretTemp -Destination $secretPath -Force -ErrorAction Stop
        $values['credentialId'] = $id
        $values['opsPassword'] = ''
        $values['authKey'] = ''
        [IO.File]::WriteAllText($publicTemp, ($values | ConvertTo-Json -Depth 8), $encoding)
        Move-Item -LiteralPath $publicTemp -Destination $Path -Force -ErrorAction Stop
        $committed = $true
    } finally {
        foreach ($temporary in @($secretTemp, $publicTemp)) {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
        if (-not $committed -and (Test-Path -LiteralPath $secretPath)) { Remove-Item -LiteralPath $secretPath -Force }
    }
    if ($priorId) {
        $priorPath = Join-Path $privateRoot ($priorId + '.json')
        if (Test-Path -LiteralPath $priorPath) {
            try {
                $prior = Get-Content -LiteralPath $priorPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$prior.configPath -eq $binding) { Remove-Item -LiteralPath $priorPath -Force -ErrorAction Stop }
            } catch { Write-Warning 'Old encrypted credential record could not be removed.' }
        }
    }
    return [pscustomobject]$values
}

function Read-ZcConfig {
    [CmdletBinding()]
    param([string]$Path, [string]$CredentialRoot, [switch]$AllowMissingCredentials)
    $values = ConvertTo-ZcConfigMap (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    if (-not $values.Contains('connectionMode')) {
        $values['connectionMode'] = $(if ($values['targetServer']) { 'Forward' } else { 'Direct' })
    }
    $id = [string]$values['credentialId']
    if ($id) {
        if ($id -notmatch '^[0-9a-fA-F]{32}$') { throw 'Invalid credential ID in configuration.' }
        $secretPath = Join-Path (Get-ZcCredentialRoot $CredentialRoot) ($id + '.json')
        try {
            if (-not (Test-Path -LiteralPath $secretPath)) { throw 'Missing credential store.' }
            $secret = Get-Content -LiteralPath $secretPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($secret.userSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'Credential user mismatch.' }
            if ([string]$secret.configPath -ne [IO.Path]::GetFullPath($Path)) { throw 'Credential config path mismatch.' }
            $values['opsPassword'] = Unprotect-ZcText ([string]$secret.opsPasswordProtected)
            $values['authKey'] = Unprotect-ZcText ([string]$secret.authKeyProtected)
        } catch {
            if (-not $AllowMissingCredentials) { throw 'Credentials are unavailable for this Windows user. Open the GUI and enter them again on this PC.' }
            $values['opsPassword'] = ''; $values['authKey'] = ''
            Write-Warning 'Credentials are unavailable on this PC; enter them again in the GUI.'
        }
    } elseif ($values['opsPassword'] -or $values['authKey']) {
        Write-Warning 'Legacy plaintext credentials detected. Save settings in the GUI to move them to the private DPAPI store.'
    }
    return [pscustomobject]$values
}
