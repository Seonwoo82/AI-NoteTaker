using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace NoteTaker.Core;

public static class AudioFiles
{
    public const int SampleRate = 48000;
    public static WaveFormat RecordingFormat => new(SampleRate, 16, 2);

    // Inspect the finalized PCM file, never the elapsed UI/session clock. Digital
    // silence with frames is valid (WASAPI loopback can supply no callbacks).
    public static double RecordedDuration(string path)
    {
        using var reader = new WaveFileReader(path);
        var format = reader.WaveFormat;
        if (format.Encoding != WaveFormatEncoding.Pcm || format.SampleRate <= 0 ||
            format.Channels <= 0 || format.BitsPerSample != 16 || format.BlockAlign != format.Channels * 2)
            throw new InvalidDataException("녹음 파일의 PCM 형식이 올바르지 않습니다.");
        if (reader.Length == 0) return 0;
        if (reader.Length % format.BlockAlign != 0)
            throw new InvalidDataException("녹음 파일의 마지막 오디오 프레임이 불완전합니다.");
        var frame = new byte[format.BlockAlign];
        if (reader.Read(frame, 0, frame.Length) != frame.Length)
            throw new InvalidDataException("녹음 파일의 오디오 데이터를 읽을 수 없습니다.");
        double duration = (double)(reader.Length / format.BlockAlign) / format.SampleRate;
        if (!double.IsFinite(duration) || duration <= 0)
            throw new InvalidDataException("녹음 파일의 길이가 올바르지 않습니다.");
        return duration;
    }

    public static double ConvertToWave(string source, string destination, CancellationToken token)
    {
        using var reader = new AudioFileReader(source);
        return ConvertToWave(reader, destination, token);
    }
    internal static double ConvertToWave(IWaveProvider reader, string destination, CancellationToken token)
    {
        using var converter = new MediaFoundationResampler(reader, RecordingFormat) { ResamplerQuality = 60 };
        using var writer = new WaveFileWriter(destination, RecordingFormat);
        var buffer = new byte[RecordingFormat.AverageBytesPerSecond];
        int read;
        while ((read = converter.Read(buffer, 0, buffer.Length)) > 0)
        {
            token.ThrowIfCancellationRequested();
            writer.Write(buffer, 0, read);
        }
        if (writer.Length == 0) throw new InvalidDataException("오디오 데이터가 비어 있습니다.");
        return (double)writer.Length / RecordingFormat.AverageBytesPerSecond;
    }

    // Fixed-size 16 kHz mono WAV chunks bound upload size and memory for long meetings.
    public static IEnumerable<byte[]> ReadTranscriptionChunks(string path, int seconds = 120)
    {
        if (seconds is < 1 or > 120) throw new ArgumentOutOfRangeException(nameof(seconds));
        using var reader = new AudioFileReader(path);
        ISampleProvider samples = reader;
        if (samples.WaveFormat.Channels == 2) samples = new StereoToMonoSampleProvider(samples);
        if (samples.WaveFormat.Channels != 1) throw new InvalidDataException("모노 또는 스테레오 오디오만 전사할 수 있습니다.");
        samples = new WdlResamplingSampleProvider(samples, 16000);
        var pcm = new SampleToWaveProvider16(samples);
        var buffer = new byte[16000 * 2 * seconds];
        while (true)
        {
            var count = 0;
            while (count < buffer.Length)
            {
                int read = pcm.Read(buffer, count, buffer.Length - count);
                if (read == 0) break;
                count += read;
            }
            if (count == 0) yield break;
            using var output = new MemoryStream();
            using (var writer = new WaveFileWriter(new NAudio.Utils.IgnoreDisposeStream(output), pcm.WaveFormat))
                writer.Write(buffer, 0, count);
            yield return output.ToArray();
        }
    }

    public static bool IsDigitalSilence(byte[] wav)
    {
        using var reader = new WaveFileReader(new MemoryStream(wav, writable: false));
        if (reader.WaveFormat.Encoding != WaveFormatEncoding.Pcm || reader.WaveFormat.BitsPerSample != 16)
            return false;
        var buffer = new byte[32000]; int count;
        while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
            for (int i = 0; i + 1 < count; i += 2)
                if (Math.Abs((int)BitConverter.ToInt16(buffer, i)) > 1) return false;
        return true;
    }

    public static void RepairInterruptedWave(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        using var reader = new BinaryReader(file, System.Text.Encoding.ASCII, leaveOpen: true);
        using var writer = new BinaryWriter(file, System.Text.Encoding.ASCII, leaveOpen: true);
        if (file.Length < 44 || new string(reader.ReadChars(4)) != "RIFF") throw new InvalidDataException("WAV 헤더가 손상되었습니다.");
        file.Position = 8;
        if (new string(reader.ReadChars(4)) != "WAVE") throw new InvalidDataException("WAV 형식이 아닙니다.");
        int blockAlign = 0;
        while (file.Position + 8 <= file.Length)
        {
            var tag = new string(reader.ReadChars(4));
            var length = reader.ReadUInt32();
            var start = file.Position;
            if (tag == "fmt " && length >= 16)
            {
                if (reader.ReadUInt16() != 1) throw new InvalidDataException("PCM 녹음만 복구할 수 있습니다.");
                file.Position = start + 12;
                blockAlign = reader.ReadUInt16();
            }
            if (tag == "data" && blockAlign > 0)
            {
                long dataLength = (file.Length - start) / blockAlign * blockAlign;
                if (dataLength > uint.MaxValue - start) throw new InvalidDataException("WAV 크기 제한을 초과했습니다.");
                file.SetLength(start + dataLength);
                file.Position = start - 4;
                writer.Write((uint)dataLength);
                file.Position = 4;
                writer.Write((uint)(file.Length - 8));
                file.Flush(true);
                return;
            }
            file.Position = start + length + (length % 2);
        }
        throw new InvalidDataException("WAV 데이터 영역을 찾을 수 없습니다.");
    }
}
