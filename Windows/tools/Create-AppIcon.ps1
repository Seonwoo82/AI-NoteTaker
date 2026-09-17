$ErrorActionPreference = 'Stop'
$windowsRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $windowsRoot
$sourceRoot = Join-Path $repositoryRoot 'NoteTaker/Resources/Assets.xcassets/AppIcon.appiconset'
$frames = @(
    @{ Size = 16; File = 'app-icon-16x16@1x.png' },
    @{ Size = 32; File = 'app-icon-32x32@1x.png' },
    @{ Size = 64; File = 'app-icon-32x32@2x.png' },
    @{ Size = 128; File = 'app-icon-128x128@1x.png' },
    @{ Size = 256; File = 'app-icon-256x256@1x.png' }
)
# Wrap the existing PNG bytes in the Windows ICO container; no resampling or artwork changes.
foreach ($frame in $frames) {
    $frame.Bytes = [IO.File]::ReadAllBytes((Join-Path $sourceRoot $frame.File))
    $widthBytes = [byte[]]$frame.Bytes[16..19]; [Array]::Reverse($widthBytes)
    $heightBytes = [byte[]]$frame.Bytes[20..23]; [Array]::Reverse($heightBytes)
    if ([BitConverter]::ToInt32($widthBytes, 0) -ne $frame.Size -or [BitConverter]::ToInt32($heightBytes, 0) -ne $frame.Size) { throw 'Unexpected source icon dimensions.' }
}
$assets = Join-Path $windowsRoot 'NoteTaker.Windows/Assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
$destination = Join-Path $assets 'App.ico'
$stream = [IO.File]::Create($destination)
$writer = [IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($frame in $frames) {
        $dimension = if ($frame.Size -eq 256) { 0 } else { $frame.Size }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$frame.Bytes.Length); $writer.Write([uint32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
}
finally { $writer.Dispose(); $stream.Dispose() }
Get-FileHash -LiteralPath $destination
