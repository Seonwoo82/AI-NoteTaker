using NAudio.MediaFoundation;
using NAudio.Wave;

namespace NoteTaker.Core;

public static class SyncAudio
{
    public static Task EncodeAsync(string wav, string destination, CancellationToken token) => Task.Run(() =>
    {
        token.ThrowIfCancellationRequested(); RequireDifferent(wav, destination); MediaFoundationApi.Startup();
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".m4a";
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        try
        {
            using (var reader = new WaveFileReader(wav))
            {
                if (reader.WaveFormat.Encoding != WaveFormatEncoding.Pcm || reader.WaveFormat.BitsPerSample != 16 || reader.WaveFormat.Channels is < 1 or > 2) throw new InvalidDataException("동기화할 PCM 오디오 형식이 올바르지 않습니다.");
                MediaFoundationEncoder.EncodeToAac(new CancellableWave(reader, token), temporary, 128000);
            }
            token.ThrowIfCancellationRequested();
            if (new FileInfo(temporary).Length > SyncJson.AudioLimit) throw new InvalidDataException("변환한 오디오가 95 MiB 동기화 제한을 초과했습니다. 원본은 이 PC에 보존됩니다.");
            File.Move(temporary, destination, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }, token);
    public static Task<double> DecodeAsync(string m4a, string destination, CancellationToken token) => Task.Run(() =>
    {
        token.ThrowIfCancellationRequested(); RequireDifferent(m4a, destination);
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".wav";
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        try
        {
            double duration = AudioFiles.ConvertToWave(m4a, temporary, token); token.ThrowIfCancellationRequested(); File.Move(temporary, destination, true); return duration;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }, token);
    private static void RequireDifferent(string source, string destination)
    {
        if (string.Equals(Path.GetFullPath(source), Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("변환 결과는 원본과 다른 파일에 저장해야 합니다.");
    }
    private sealed class CancellableWave(IWaveProvider source, CancellationToken token) : IWaveProvider
    {
        public WaveFormat WaveFormat => source.WaveFormat;
        public int Read(byte[] buffer, int offset, int count) { token.ThrowIfCancellationRequested(); return source.Read(buffer, offset, count); }
    }
}
