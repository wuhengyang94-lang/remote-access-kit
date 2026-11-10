#Requires -Version 5.1
# Explicit allowlist plus a fresh public template: never package live settings.
[CmdletBinding()]
param([string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'remote-access-kit.zip'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$files=@(
    '01-jump-setup.ps1','02-connect-site.ps1','03-undo.ps1','zc-state.ps1',
    'zc-config.ps1','zc-process.ps1','run.ps1','gui.ps1','start.cmd','gui.cmd',
    'README.md','Build-Package.ps1','tools/tailscale-setup-1.104.1-amd64.msi',
    'tests/Forwarding.Tests.ps1','tests/Launcher.Tests.ps1','tests/State.Tests.ps1',
    'tests/JoinRetry.Tests.ps1','tests/Recovery.Tests.ps1','tests/Config.Tests.ps1',
    'tests/Process.Tests.ps1','tests/Direct.Tests.ps1','tests/EngineModes.Tests.ps1',
    'tests/GuiBehavior.Tests.ps1','tests/SiteResult.Tests.ps1','tests/ClientReadiness.Tests.ps1',
    'tests/ProfileFiles.Tests.ps1'
)
$validation='docs/validation-2026-11-10.md'
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot $validation)){$files += $validation}
foreach($file in $files){if(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)){throw "Required package file is missing: $file"}}
$template=[ordered]@{
    authKey='';opsUser='zcode_ops';opsPassword='';siteName='';jumpHost='';targetServer=''
    connectionMode='Direct';credentialId='';dbPort=13306;webPort=18080;rdpPort=13389
    extraForwards=@();advertiseRoutes=@();useOnlineInstaller=$false;profilePath=''
}
$output=[IO.Path]::GetFullPath($OutputPath)
$parent=Split-Path $output -Parent
if(-not (Test-Path -LiteralPath $parent -PathType Container)){throw 'The output directory does not exist.'}
$temporary=$output+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
$encoding=New-Object Text.UTF8Encoding($false)
$manifest=New-Object Collections.ArrayList
$archive=$null;$stream=$null
try{
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    foreach($file in $files){
        $path=Join-Path $PSScriptRoot $file
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$path,$file,[IO.Compression.CompressionLevel]::Optimal)
        [void]$manifest.Add([ordered]@{path=$file;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash})
    }
    $configBytes=$encoding.GetBytes(($template | ConvertTo-Json -Depth 6))
    $configEntry=$archive.CreateEntry('config.json')
    $entryStream=$configEntry.Open();try{$entryStream.Write($configBytes,0,$configBytes.Length)}finally{$entryStream.Dispose()}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$configHash=[BitConverter]::ToString($sha.ComputeHash($configBytes)).Replace('-','')}finally{$sha.Dispose()}
    [void]$manifest.Add([ordered]@{path='config.json';sha256=$configHash})
    $manifestBytes=$encoding.GetBytes(([ordered]@{name='remote-access-kit';build='2026-11-10-local';createdUtc=(Get-Date).ToUniversalTime().ToString('o');files=@($manifest)} | ConvertTo-Json -Depth 8))
    $entry=$archive.CreateEntry('package-manifest.json');$entryStream=$entry.Open()
    try{$entryStream.Write($manifestBytes,0,$manifestBytes.Length)}finally{$entryStream.Dispose()}
    $archive.Dispose();$archive=$null;$stream.Dispose();$stream=$null
    Move-Item -LiteralPath $temporary -Destination $output -Force -ErrorAction Stop
}finally{
    if($archive){$archive.Dispose()};if($stream){$stream.Dispose()}
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
}
[pscustomobject]@{Path=$output;Bytes=(Get-Item -LiteralPath $output).Length;SHA256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash;Entries=($files.Count+2)}
