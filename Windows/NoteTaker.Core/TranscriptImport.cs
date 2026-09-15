using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace NoteTaker.Core;

public sealed record ImportedTranscript(string Text, IReadOnlyList<TranscriptSegment> Segments, string Format, byte[] OriginalBytes, string FileName);

public static class TranscriptImport
{
    public const int MaximumBytes = 5_000_000;
    public static ImportedTranscript Read(string path)
    {
        if (new FileInfo(path).Length > MaximumBytes) throw new InvalidDataException("전사문은 5MB 이하의 텍스트 파일을 선택해 주세요.");
        byte[] bytes = File.ReadAllBytes(path);
        string text;
        if (bytes.AsSpan().StartsWith(new byte[] { 0xff, 0xfe })) text = Encoding.Unicode.GetString(bytes.AsSpan(2));
        else if (bytes.AsSpan().StartsWith(new byte[] { 0xfe, 0xff })) text = Encoding.BigEndianUnicode.GetString(bytes.AsSpan(2));
        else
        {
            try { text = new UTF8Encoding(false, true).GetString(bytes); }
            catch (DecoderFallbackException)
            {
                Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
                text = Encoding.GetEncoding(949, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetString(bytes);
            }
        }
        return Parse(text.TrimStart('\uFEFF'), Path.GetFileName(path), bytes);
    }
    public static ImportedTranscript Parse(string text, string fileName = "붙여넣은 전사문.txt", byte[]? original = null)
    {
        if (Encoding.UTF8.GetByteCount(text) > MaximumBytes) throw new InvalidDataException("전사문은 5MB 이하로 가져와 주세요.");
        if (string.IsNullOrWhiteSpace(text)) throw new InvalidDataException("가져올 전사문이 비어 있습니다.");
        var segments = new List<TranscriptSegment>();
        string normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
        string format = Path.GetExtension(fileName).Equals(".srt", StringComparison.OrdinalIgnoreCase) ? "srt" : "text";
        if (format == "srt")
        {
            foreach (var block in Regex.Split(normalized.Trim(), @"\n[ \t]*\n"))
            {
                var lines = block.Split('\n');
                int timeIndex = Array.FindIndex(lines, x => x.Contains("-->"));
                if (timeIndex < 0) throw new InvalidDataException("SRT 시간 표시를 찾지 못했습니다.");
                var match = Regex.Match(lines[timeIndex], @"^(?<start>\d{1,3}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*(?<end>\d{1,3}:\d{2}:\d{2}[,.]\d{3})(?:\s.*)?$");
                if (!match.Success) throw new InvalidDataException("SRT 시간 형식이 올바르지 않습니다.");
                double start = ReadTime(match.Groups["start"].Value), end = ReadTime(match.Groups["end"].Value);
                if (end < start || (segments.Count > 0 && start < segments[^1].StartSeconds)) throw new InvalidDataException("SRT 시간 순서를 확인해 주세요.");
                string content = string.Join("\n", lines.Skip(timeIndex + 1)).Trim();
                if (content.Length > 0) segments.Add(new(start, end, content));
            }
            if (segments.Count == 0) throw new InvalidDataException("SRT에 전사 내용이 없습니다.");
        }
        // Plain text retains speaker/timestamp labels verbatim: do not guess Clova export metadata.
        return new(normalized.Trim(), segments, format, original ?? Encoding.UTF8.GetBytes(text), fileName);
    }
    private static double ReadTime(string value)
    {
        var parts = value.Replace(',', '.').Split(':');
        int hours = int.Parse(parts[0], CultureInfo.InvariantCulture), minutes = int.Parse(parts[1], CultureInfo.InvariantCulture);
        double seconds = double.Parse(parts[2], CultureInfo.InvariantCulture);
        if (minutes >= 60 || seconds >= 60) throw new InvalidDataException("SRT 시간 범위를 확인해 주세요.");
        return hours * 3600 + minutes * 60 + seconds;
    }
    public static async Task SaveAsync(LibraryStore library, Recording recording, ImportedTranscript imported, CancellationToken token)
    {
        if (recording.IsRecording || recording.DeletedAt is not null) throw new InvalidOperationException("저장된 녹음에 전사문을 가져와 주세요.");
        string hash = await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token);
        if (imported.Segments.Any(x => x.EndSeconds > recording.DurationSeconds + 2))
            throw new InvalidDataException("전사문의 시간 범위가 녹음보다 깁니다. 같은 녹음의 전사문인지 확인해 주세요.");
        token.ThrowIfCancellationRequested();
        string directory = Path.Combine(library.DirectoryFor(recording.Id), "ImportedSources"); Directory.CreateDirectory(directory);
        string originalName = Guid.NewGuid().ToString("N") + (imported.Format == "srt" ? ".srt" : ".txt");
        await File.WriteAllBytesAsync(Path.Combine(directory, originalName), imported.OriginalBytes, token);
        string path = library.TranscriptPath(recording.Id);
        if (File.Exists(path))
        {
            string history = Path.Combine(library.DirectoryFor(recording.Id), "TranscriptHistory"); Directory.CreateDirectory(history);
            File.Copy(path, Path.Combine(history, Guid.NewGuid().ToString("N") + ".json"));
        }
        string text = imported.Format == "srt" ? string.Join("\n\n", imported.Segments.Select(x => $"[{Recording.FormatTime(x.StartSeconds)}] {x.Text}")) : imported.Text;
        var cache = new TranscriptCache(hash, "imported-" + imported.Format, "source", [text], true)
        {
            SchemaVersion = 2, Provider = "import", Source = "import", Segments = imported.Segments.ToList(),
            OriginalFile = Path.Combine("ImportedSources", originalName), Fingerprint = "import/" + originalName
        };
        token.ThrowIfCancellationRequested(); JsonDisk.Write(path, cache);
    }
}
