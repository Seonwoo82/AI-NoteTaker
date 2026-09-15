using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using Whisper.net;

namespace NoteTaker.Core;

/// <summary>Capture original token bytes before separate UTF-8 decoding can lose Korean/CJK byte pieces.</summary>
public sealed class WhisperUtf8Capture : IStringPool
{
    private readonly System.Runtime.CompilerServices.ConditionalWeakTable<string, byte[]> bytes = new();
    public string GetStringUtf8(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) return "";
        int count = 0; while (count < 1_048_576 && Marshal.ReadByte(pointer, count) != 0) count++;
        if (count == 1_048_576) throw new InvalidDataException("Whisper 문자열이 너무 큽니다.");
        byte[] data = new byte[count]; Marshal.Copy(pointer, data, 0, count);
        string value = new(Encoding.UTF8.GetString(data).AsSpan());
        if (value.Length > 0) bytes.Add(value, data);
        return value;
    }
    public byte[] Bytes(string? text) => string.IsNullOrEmpty(text) ? [] : bytes.TryGetValue(text, out var data) ? data : throw new InvalidDataException("Whisper 원본 토큰을 읽지 못했습니다.");
    public void ReturnString(string? value) { if (value is not null) bytes.Remove(value); }
}
public sealed record EncodedTranscriptToken(byte[] Bytes, double StartSeconds, double EndSeconds);
public static class WhisperTokenAlignment
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    public static List<TranscriptWord> Align(string text, IReadOnlyList<EncodedTranscriptToken> tokens)
    {
        if (tokens.Count == 0) return [];
        byte[] joined = tokens.SelectMany(t => t.Bytes).ToArray();
        try { if (StrictUtf8.GetString(joined) != text) return []; } catch (DecoderFallbackException) { return []; }
        var boundaries = StringInfo.ParseCombiningCharacters(text).Append(text.Length).ToHashSet();
        var result = new List<TranscriptWord>(); var pending = new List<byte>(); int offset = 0; double start = 0, end = 0, previous = 0;
        foreach (var token in tokens)
        {
            if (!double.IsFinite(token.StartSeconds) || !double.IsFinite(token.EndSeconds) || token.StartSeconds < previous || token.EndSeconds < token.StartSeconds) return [];
            previous = token.StartSeconds;
            if (pending.Count == 0) { start = token.StartSeconds; end = token.EndSeconds; }
            pending.AddRange(token.Bytes); end = Math.Max(end, token.EndSeconds);
            string value;
            try { value = StrictUtf8.GetString(pending.ToArray()); } catch (DecoderFallbackException) { continue; }
            if (!boundaries.Contains(offset + value.Length)) continue;
            result.Add(new(start, end, value)); offset += value.Length; pending.Clear();
        }
        return pending.Count == 0 && offset == text.Length ? result : [];
    }
    public static List<TranscriptWord> Align(SegmentData segment, WhisperUtf8Capture capture)
    {
        // This pinned multilingual Whisper model uses ordinary vocabulary IDs below EOT 50257.
        // Control/timestamp tokens are not transcript text. Native t0/t1 are centiseconds.
        var tokens = segment.Tokens.Where(t => t.Id < 50257).Select(t => new EncodedTranscriptToken(capture.Bytes(t.Text), t.Start / 100d, t.End / 100d)).ToList();
        return Align(segment.Text, tokens);
    }
}
