param(
    [string]$Archive = (Join-Path $PSScriptRoot 'artifacts/AI-NoteTaker-0.3.0-win-x64.zip'),
    [string]$Audio = (Join-Path $PSScriptRoot 'artifacts/evaluation/samples/synthetic-meeting-ko.wav'),
    [string]$ModelRoot = (Join-Path $env:LOCALAPPDATA 'AI-NoteTaker')
)
$ErrorActionPreference = 'Stop'
$verifyRoot = Join-Path $PSScriptRoot ('artifacts/verify-package-' + [guid]::NewGuid().ToString('N').Substring(0,8))
Expand-Archive -LiteralPath $Archive -DestinationPath $verifyRoot
$verifyExe = Join-Path $verifyRoot 'AI-NoteTaker.exe'
$uiOutput = Join-Path $verifyRoot 'verification/ui'
$uiProcess = Start-Process -FilePath $verifyExe -ArgumentList @('--smoke-ui', ('"{0}"' -f $uiOutput)) -WindowStyle Hidden -PassThru -Wait
if ($uiProcess.ExitCode -ne 0) { throw "Extracted ZIP UI failed. See $uiOutput/error.txt" }
foreach ($engine in @('whisper','qwen')) {
    $aiOutput = Join-Path $verifyRoot "verification/$engine"
    $testArgs = @('--smoke-ai', ('"{0}"' -f $aiOutput), ('"{0}"' -f ([System.IO.Path]::GetFullPath($Audio))), ('"{0}"' -f ([System.IO.Path]::GetFullPath($ModelRoot))), $engine)
    $aiProcess = Start-Process -FilePath $verifyExe -ArgumentList $testArgs -WindowStyle Hidden -PassThru -Wait
    if ($aiProcess.ExitCode -ne 0) { throw "Extracted ZIP $engine failed. See $aiOutput/error.txt" }
}
$archiveFile = Get-Item -LiteralPath $Archive
$result = [pscustomobject]@{
    Passed=$true; ZipSHA256=(Get-FileHash -LiteralPath $Archive).Hash; ZipBytes=$archiveFile.Length
    Extracted=$verifyRoot; Version=(Get-Item -LiteralPath $verifyExe).VersionInfo.ProductVersion
    UI=$true; Whisper=$true; Qwen=$true
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'artifacts/0.3.0/verification.json')
$result | ConvertTo-Json
