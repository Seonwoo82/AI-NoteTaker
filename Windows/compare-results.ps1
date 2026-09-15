param([string]$EvaluationRoot = (Join-Path $PSScriptRoot 'artifacts/evaluation'))
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
public static class KoreanCer {
  public static int Distance(string a, string b) {
    var previous = new int[b.Length + 1];
    for (int j = 0; j <= b.Length; j++) previous[j] = j;
    for (int i = 1; i <= a.Length; i++) {
      var next = new int[b.Length + 1]; next[0] = i;
      for (int j = 1; j <= b.Length; j++) next[j] = Math.Min(Math.Min(previous[j] + 1, next[j-1] + 1), previous[j-1] + (a[i-1] == b[j-1] ? 0 : 1));
      previous = next;
    }
    return previous[b.Length];
  }
}
'@
function Normalize-Transcript([string]$Text, [bool]$Numbers) {
    $value = ($Text.Normalize().ToLowerInvariant() -replace '[^\p{L}\p{N}]', '')
    if ($Numbers) {
        # Explicit equivalences for this synthetic fixture only, not a general Korean normalizer.
        $value = $value.Replace('다섯건','5건').Replace('삼백만원','300만원').Replace('구월','9월').Replace('이십일','20일').Replace('두시','2시')
    }
    return $value
}
$referenceText = Get-Content -LiteralPath (Join-Path $EvaluationRoot 'samples/synthetic-meeting-ko.txt') -Raw -Encoding utf8
$referenceRaw = Normalize-Transcript $referenceText $false
$referenceNormalized = Normalize-Transcript $referenceText $true
$results = foreach ($entry in @('whisper-measured','qwen17-measured','qwen06-measured-final')) {
    $result = Get-Content -LiteralPath (Join-Path $EvaluationRoot "$entry/result.json") -Raw | ConvertFrom-Json
    $raw = Normalize-Transcript ($result.transcript.chunks -join ' ') $false
    $normalized = Normalize-Transcript ($result.transcript.chunks -join ' ') $true
    [pscustomobject]@{
        Run = $entry; Seconds = $result.transcriptionSeconds; RTF = $result.realTimeFactor
        RawEdits = [KoreanCer]::Distance($referenceRaw, $raw); RawReferenceCharacters = $referenceRaw.Length
        NormalizedEdits = [KoreanCer]::Distance($referenceNormalized, $normalized); NormalizedReferenceCharacters = $referenceNormalized.Length
        NormalizedCER = [KoreanCer]::Distance($referenceNormalized, $normalized) / $referenceNormalized.Length
        SampledWorkingSetMB = $result.asrPeakCombinedWorkingSetMb; WholeDevicePeakMiB = $result.asrPeakWholeDeviceMemoryMiB
    }
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvaluationRoot 'comparison.json') -Encoding utf8
$results | Format-Table
