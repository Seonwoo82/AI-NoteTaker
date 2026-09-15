param(
    [string]$Archive,
    [string]$Audio = (Join-Path $PSScriptRoot 'artifacts/evaluation/samples/synthetic-meeting-ko.wav'),
    [string]$ModelRoot = (Join-Path $env:LOCALAPPDATA 'AI-NoteTaker'),
    [string]$SpeakerAudio = (Join-Path $PSScriptRoot 'artifacts/voice-research/0-four-speakers-zh.wav'),
    [switch]$AllFeatures
)
$ErrorActionPreference = 'Stop'
if (!$Archive) {
    [xml]$projectXml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'NoteTaker.Windows/NoteTaker.Windows.csproj')
    $packageVersion = [string]$projectXml.Project.PropertyGroup.Version
    $Archive = Join-Path $PSScriptRoot "artifacts/AI-NoteTaker-$packageVersion-win-x64.zip"
}
$Archive = (Resolve-Path -LiteralPath $Archive).Path
$Audio = (Resolve-Path -LiteralPath $Audio).Path
$ModelRoot = (Resolve-Path -LiteralPath $ModelRoot).Path
if ($AllFeatures) { $SpeakerAudio = (Resolve-Path -LiteralPath $SpeakerAudio).Path }
$verifyRoot = Join-Path $PSScriptRoot ('artifacts/verify-package-' + [guid]::NewGuid().ToString('N').Substring(0,8))
Expand-Archive -LiteralPath $Archive -DestinationPath $verifyRoot
$verifyExe = Join-Path $verifyRoot 'AI-NoteTaker.exe'
$checks = [ordered]@{}
$checkFailure = $null
$script:activeCheck = $null
function Invoke-PackageCheck([string]$Name, [string]$Mode, [string[]]$Parameters = @()) {
    $script:activeCheck = $Name
    $checkOutput = Join-Path $verifyRoot "verification/$Name"
    $checkArgs = @($Mode, ('"{0}"' -f $checkOutput)) + @($Parameters | ForEach-Object { '"{0}"' -f $_ })
    Write-Output "Extracted ZIP: $Name"
    $checkProcess = Start-Process -FilePath $verifyExe -ArgumentList $checkArgs -WorkingDirectory $verifyRoot -WindowStyle Hidden -PassThru -Wait
    if ($checkProcess.ExitCode -ne 0) { throw "Extracted ZIP $Name failed. See $checkOutput/error.txt" }
    $checks[$Name] = $true
}
try {
Invoke-PackageCheck 'ui' '--smoke-ui'
foreach ($engine in @('whisper','qwen')) {
    Invoke-PackageCheck $engine '--smoke-ai' @($Audio, $ModelRoot, $engine)
}
if ($AllFeatures) {
    Invoke-PackageCheck 'desktop' '--smoke-desktop'
    Invoke-PackageCheck 'capture-flow' '--smoke-capture-flow' @($Audio, $ModelRoot)
    Invoke-PackageCheck 'participants' '--smoke-participants' @($SpeakerAudio, $ModelRoot)
    Invoke-PackageCheck 'profile' '--smoke-profile' @($SpeakerAudio, $ModelRoot)
    Invoke-PackageCheck 'meeting' '--smoke-meeting' @($ModelRoot)
    Invoke-PackageCheck 'notes' '--smoke-notes' @($ModelRoot)
    Invoke-PackageCheck 'audio-share' '--smoke-audio-share'
}
}
catch {
    $checks[$script:activeCheck] = $false
    $checkFailure = $_
}
$archiveFile = Get-Item -LiteralPath $Archive
$result = [pscustomobject]@{
    Passed=($null -eq $checkFailure); ZipSHA256=(Get-FileHash -LiteralPath $Archive).Hash; ZipBytes=$archiveFile.Length
    Extracted=$verifyRoot; Version=(Get-Item -LiteralPath $verifyExe).VersionInfo.ProductVersion
    Checks=$checks; ModelRoot=$ModelRoot; Audio=$Audio; AllFeatures=[bool]$AllFeatures
    Failure=if ($checkFailure) { [string]$checkFailure } else { $null }
    Scope='Fresh extraction and native WPF/model flows using provided files; no microphone capture. Native audio sharing supplies a generated silent WAV to Windows without selecting a target or sending. Models are outside ZIP. Sync/web-share server round trips are verified separately.'
}
$reportPath = Join-Path (Split-Path -Parent $Archive) ([IO.Path]::GetFileNameWithoutExtension($Archive) + '.verification.json')
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath
$result | ConvertTo-Json -Depth 4
if ($checkFailure) { throw $checkFailure }
