#Requires -Version 5.1
# GUI child-process plumbing; this module never runs an engine by itself.
function ConvertTo-ZcProcessArgument {
    param([AllowEmptyString()][string]$Value)
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return ('"' + $escaped + '"')
}

function Get-ZcPowerShellArguments {
    param([string]$ScriptPath, [string[]]$Arguments = @())
    $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-ZcProcessArgument $ScriptPath)
    foreach ($argument in $Arguments) { $line += ' ' + (ConvertTo-ZcProcessArgument $argument) }
    return $line
}

function Invoke-ZcNativeProcess {
    param([string]$FilePath, [string[]]$Arguments=@(), [ValidateRange(1,600)][int]$TimeoutSec=30)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $FilePath
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-ZcProcessArgument $_ }) -join ' ')
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill(); [void]$process.WaitForExit(2000) } catch { }
            return [pscustomobject]@{ExitCode=-1;Text='TIMEOUT'}
        }
        return [pscustomobject]@{ExitCode=$process.ExitCode;Text=($out.Result + $err.Result)}
    } finally { $process.Dispose() }
}

function Start-ZcScriptProcess {
    param([string]$ScriptPath, [string[]]$Arguments = @(), [string]$LogRoot)
    if (-not $LogRoot) { $LogRoot = Join-Path $env:LOCALAPPDATA 'ZCodeRemoteAccess\process-logs' }
    $privateRoot = Initialize-ZcPrivateDirectory $LogRoot
    $directory = Join-Path $privateRoot ('run-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $out = Join-Path $directory 'stdout.log'; $err = Join-Path $directory 'stderr.log'
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList (Get-ZcPowerShellArguments -ScriptPath $ScriptPath -Arguments $Arguments) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    # PS 5.1 can lose ExitCode after a short-lived redirected process exits.
    $null = $process.Handle
    return [pscustomobject]@{Process=$process;OutPath=$out;ErrPath=$err;Directory=$directory;Root=$privateRoot;OutPosition=0;ErrPosition=0}
}

function Get-ZcProcessResult {
    param($Job)
    if (-not $Job.Process.HasExited) { throw 'The process is still running.' }
    $Job.Process.WaitForExit()
    $code = $Job.Process.ExitCode
    if ($null -eq $code) { throw 'The child process exit code is unavailable; success cannot be verified.' }
    return [pscustomobject]@{ExitCode=[int]$code;Succeeded=([int]$code -eq 0)}
}

function Close-ZcProcessJob {
    param($Job)
    if (-not $Job -or -not $Job.Process.HasExited) { return }
    $directory = [IO.Path]::GetFullPath([string]$Job.Directory)
    $prefix = [IO.Path]::GetFullPath([string]$Job.Root).TrimEnd('\') + '\'
    if (-not $directory.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $directory -Leaf) -notmatch '^run-[0-9a-f]{32}$') {
        throw 'Refusing to clean an unexpected process log directory.'
    }
    $Job.Process.Dispose()
    foreach ($name in @('stdout.log','stderr.log')) {
        $path = Join-Path $directory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if (Test-Path -LiteralPath $directory) { [IO.Directory]::Delete($directory, $false) }
}
