param([string]$Output = (Join-Path $PSScriptRoot '../artifacts/evaluation/samples/synthetic-meeting-ko.wav'))
$ErrorActionPreference = 'Stop'
$voice = New-Object -ComObject SAPI.SpVoice
$korean = @($voice.GetVoices() | Where-Object { $_.GetDescription() -match 'Heami|Korean|한국' }) | Select-Object -First 1
if (!$korean) { throw 'Windows 한국어 음성(예: Microsoft Heami Desktop)이 필요합니다.' }
$voice.Voice = $korean
$voice.Rate = 0
$stream = New-Object -ComObject SAPI.SpFileStream
$stream.Format.Type = 22
$fullOutput = [System.IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force (Split-Path -Parent $fullOutput) | Out-Null
try {
    $stream.Open($fullOutput, 3)
    $voice.AudioOutputStream = $stream
    [void]$voice.Speak((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'reference-ko.txt') -Raw -Encoding utf8))
}
finally { $stream.Close() }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'reference-ko.txt') -Destination ([System.IO.Path]::ChangeExtension($fullOutput, '.txt')) -Force
Write-Output $fullOutput
