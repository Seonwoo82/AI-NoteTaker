param(
    [ValidateSet('build','test','audio-smoke','ui-audio-smoke','run','publish','smoke-ui','smoke-desktop')][string]$Task = 'build',
    [ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64',
    [string]$ArtifactRoot = (Join-Path $PSScriptRoot 'artifacts')
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$localDotnet = Join-Path $repoRoot '.tools\dotnet\dotnet.exe'
if (Test-Path -LiteralPath $localDotnet) { $dotnetPath = $localDotnet }
elseif (Get-Command dotnet -ErrorAction SilentlyContinue) { $dotnetPath = (Get-Command dotnet).Source }
else { throw '.NET 10 SDK가 필요합니다. Windows/README.md의 설치 안내를 확인해 주세요.' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$project = Join-Path $PSScriptRoot 'NoteTaker.Windows\NoteTaker.Windows.csproj'
switch ($Task) {
    'build' { & $dotnetPath build $project -c Release --nologo }
    'test' { & $dotnetPath test (Join-Path $PSScriptRoot 'NoteTaker.Tests\NoteTaker.Tests.csproj') -c Release --nologo }
    'audio-smoke' {
        $previousAudioSmoke = $env:NOTETAKER_AUDIO_SMOKE
        try {
            $env:NOTETAKER_AUDIO_SMOKE = '1'
            & $dotnetPath test (Join-Path $PSScriptRoot 'NoteTaker.Tests\NoteTaker.Tests.csproj') -c Release --filter 'Category=Hardware' --nologo
        }
        finally { $env:NOTETAKER_AUDIO_SMOKE = $previousAudioSmoke }
    }
    'run' { & $dotnetPath run --project $project -c Release }
    'publish' {
        [xml]$projectXml = Get-Content -LiteralPath $project
        $version = [string]$projectXml.Project.PropertyGroup.Version
        if ($version -notmatch '^\d+\.\d+\.\d+([-.][A-Za-z0-9.-]+)?$') { throw '배포 버전 형식을 확인해 주세요.' }
        $output = Join-Path $ArtifactRoot "$version\portable-$Runtime"
        & $dotnetPath publish $project -c Release -r $Runtime --self-contained true -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false -o $output --nologo
        if ($LASTEXITCODE -eq 0) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination $output
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'EXECUTION_PLAN.md') -Destination $output
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'FULL-PORT-PLAN.md') -Destination $output
            $docsOutput = Join-Path $output 'docs/implementation'
            New-Item -ItemType Directory -Force $docsOutput | Out-Null
            foreach ($doc in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'docs/implementation') -Filter '*.md' -File) {
                Copy-Item -LiteralPath $doc.FullName -Destination $docsOutput
            }
            $evaluationOutput = $output
            New-Item -ItemType Directory -Force $evaluationOutput | Out-Null
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'evaluation') -Destination $evaluationOutput -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'compare-results.ps1') -Destination $evaluationOutput
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.md') -Destination $output
            $sdkRoot = Split-Path -Parent $dotnetPath
            foreach ($noticeName in @('LICENSE.txt','ThirdPartyNotices.txt')) {
                $noticePath = Join-Path $sdkRoot $noticeName
                if (!(Test-Path -LiteralPath $noticePath)) { throw ".NET 배포 고지 파일을 찾지 못했습니다: $noticePath" }
                Copy-Item -LiteralPath $noticePath -Destination (Join-Path $output "DOTNET-$noticeName")
            }
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'licenses') -Destination $output -Recurse -Force
            Compress-Archive -Path (Join-Path $output '*') -DestinationPath (Join-Path $ArtifactRoot "AI-NoteTaker-$version-$Runtime.zip") -Force
            Write-Output "실행 파일: $output\AI-NoteTaker.exe"
        }
    }
    'smoke-ui' {
        $output = Join-Path $ArtifactRoot 'ui-smoke'
        & $dotnetPath run --project $project -c Release -- --smoke-ui $output
    }
    'smoke-desktop' {
        $output = Join-Path $ArtifactRoot 'desktop-smoke'
        & $dotnetPath run --project $project -c Release -- --smoke-desktop $output
    }
    'ui-audio-smoke' {
        $previousUiAudioSmoke = $env:NOTETAKER_UI_AUDIO_SMOKE
        try {
            $env:NOTETAKER_UI_AUDIO_SMOKE = '1'
            & $dotnetPath run --project $project -c Release -- --smoke-ui (Join-Path $ArtifactRoot 'ui-audio-smoke')
        }
        finally { $env:NOTETAKER_UI_AUDIO_SMOKE = $previousUiAudioSmoke }
    }
}
if ($LASTEXITCODE -ne 0) { throw "dotnet 작업 실패: $LASTEXITCODE" }
