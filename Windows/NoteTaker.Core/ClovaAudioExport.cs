using NAudio.Wave;

namespace NoteTaker.Core;

public static class ClovaAudioExport
{
    // 90 min at 16 kHz mono PCM16 = 172.8 MB plus header, below both Clova limits.
    public static Task<IReadOnlyList<string>> ExportAsync(string source, string destinationFolder, IProgress<string> progress,
        CancellationToken token, int partSeconds = 90 * 60) => Task.Run<IReadOnlyList<string>>(() =>
    {
        if (partSeconds is < 1 or > 5400) throw new ArgumentOutOfRangeException(nameof(partSeconds));
        string parent = Path.TrimEndingDirectorySeparator(Path.GetFullPath(destinationFolder));
        string folder = Path.Combine(parent, "Clova-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        var files = new List<string>();
        WaveFileWriter? writer = null;
        long bytesInPart = 0, limit = partSeconds * 32000L;
        try
        {
            foreach (var chunk in AudioFiles.ReadTranscriptionChunks(source))
            {
                token.ThrowIfCancellationRequested();
                using var reader = new WaveFileReader(new MemoryStream(chunk));
                var buffer = new byte[64000]; int read;
                while ((read = reader.Read(buffer, 0, buffer.Length)) > 0)
                {
                    int offset = 0;
                    while (offset < read)
                    {
                        token.ThrowIfCancellationRequested();
                        if (writer is null)
                        {
                            string path = Path.Combine(folder, $"audio-{files.Count + 1:D3}.wav"); files.Add(path);
                            writer = new WaveFileWriter(path + ".partial", new WaveFormat(16000, 16, 1)); bytesInPart = 0;
                            progress.Report($"클로바노트용 파일 내보내기 · {files.Count}번째");
                        }
                        int count = (int)Math.Min(read - offset, limit - bytesInPart);
                        writer.Write(buffer, offset, count); offset += count; bytesInPart += count;
                        if (bytesInPart == limit)
                        {
                            writer.Dispose(); writer = null; File.Move(files[^1] + ".partial", files[^1]);
                        }
                    }
                }
            }
            if (writer is not null) { writer.Dispose(); writer = null; File.Move(files[^1] + ".partial", files[^1]); }
            if (files.Count == 0) throw new InvalidDataException("내보낼 오디오가 비어 있습니다.");
            token.ThrowIfCancellationRequested();
            File.WriteAllText(Path.Combine(folder, "사용방법.txt"), "각 WAV를 순서대로 클로바노트에 업로드하세요. 파일은 최대 90분, 약 173MB입니다.\n전사문을 다운로드한 뒤 AI-NoteTaker에서 해당 녹음을 선택하고 전사문 가져오기를 사용하세요.\n분할된 노트의 TXT 내용을 순서대로 합쳐 붙여넣을 수 있습니다. SRT는 각 파일의 시간이 0부터 시작하므로 원본 녹음의 시간에 맞게 조정해야 합니다.\n원본 오디오는 변경되지 않았습니다.");
            return files;
        }
        catch
        {
            writer?.Dispose();
            // Only files in this operation's newly-created directory are removed.
            string full = Path.GetFullPath(folder);
            if (Path.GetDirectoryName(full) == parent && Path.GetFileName(full).StartsWith("Clova-", StringComparison.Ordinal)) Directory.Delete(full, true);
            throw;
        }
    }, token);
}
