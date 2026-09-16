param(
    [Parameter(Mandatory)][string]$PackageDirectory
)
$ErrorActionPreference = 'Stop'
$packageRoot = (Resolve-Path -LiteralPath $PackageDirectory).Path
foreach ($name in @('AI-NoteTaker.exe', 'AI-NoteTaker.dll', 'NoteTaker.Core.dll', 'NAudio.Core.dll')) {
    if (!(Test-Path -LiteralPath (Join-Path $packageRoot $name) -PathType Leaf)) { throw "Package file missing: $name" }
}
$localDotnet = Join-Path (Split-Path -Parent $PSScriptRoot) '.tools/dotnet/dotnet.exe'
if (Test-Path -LiteralPath $localDotnet) { $dotnetPath = $localDotnet }
elseif (Get-Command dotnet -ErrorAction SilentlyContinue) { $dotnetPath = (Get-Command dotnet).Source }
else { throw '.NET 10 SDK is required for the package recording check.' }

$checkRoot = Join-Path $PSScriptRoot 'tools/RecordingCompletionCheck'
& $dotnetPath build (Join-Path $checkRoot 'RecordingCompletionCheck.csproj') -c Release "-p:PackageRoot=$packageRoot" --nologo
if ($LASTEXITCODE -ne 0) { throw "Recording check build failed: $LASTEXITCODE" }
$checkDll = Join-Path $checkRoot 'bin/Release/net10.0-windows10.0.19041.0/RecordingCompletionCheck.dll'
$output = Join-Path $PSScriptRoot ('artifacts/recording-completion-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# The harness opens isolated WPF fixture windows. Never run it while desktop use is paused.
$process = Start-Process -FilePath $dotnetPath -ArgumentList ('"' + $checkDll + '"'), ('"' + $packageRoot + '"'), ('"' + $output + '"') -WindowStyle Hidden -PassThru
Write-Output "Recording check process: $($process.Id), output: $output"
if (!$process.WaitForExit(60000)) { throw "Recording check is still running (PID $($process.Id)). Inspect it before another run: $output" }
if ($process.ExitCode -ne 0) {
    $errorPath = Join-Path $output 'error.txt'
    if (Test-Path -LiteralPath $errorPath) { Get-Content -LiteralPath $errorPath | Write-Output }
    throw "Recording check failed: $($process.ExitCode)"
}
$report = Get-Content -LiteralPath (Join-Path $output 'result.json') -Raw | ConvertFrom-Json
if (!$report.passed) { throw 'Recording check did not report success.' }
foreach ($entry in @(
    @{ Name = 'AI-NoteTaker.dll'; ReportPath = $report.appAssembly; Hash = $report.appAssemblySha256 },
    @{ Name = 'NoteTaker.Core.dll'; ReportPath = $report.coreAssembly; Hash = $report.coreAssemblySha256 }
)) {
    $expected = Join-Path $packageRoot $entry.Name
    if ($entry.ReportPath -ne $expected -or $entry.Hash -ne (Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash) {
        throw "Recording check loaded a different package assembly: $($entry.Name)"
    }
}
Write-Output "PASS: empty completion, retry, exit and WPF restart. Report: $output/result.json"
