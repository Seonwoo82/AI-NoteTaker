using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace NoteTaker.Core;

public sealed record SpeakerAudioWindow(double Start, double KeepStart, double KeepEnd, float[] Samples);
public static class SpeakerAudioWindows
{
    public const int SampleRate = 16000;
    public const int MaximumSeconds = 6 * 3600;
    public const int WindowSeconds = 300;
    public const int ContextSeconds = 2;
    public static void ValidateDuration(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds <= 0 || seconds > MaximumSeconds) throw new InvalidDataException("참여자 분석은 6시간 이하 녹음을 지원합니다.");
    }
    public static double Duration(string path)
    {
        using var reader = new AudioFileReader(path); double duration = reader.TotalTime.TotalSeconds; ValidateDuration(duration); return duration;
    }
    public static IEnumerable<SpeakerAudioWindow> Read(string path, CancellationToken token = default)
    {
        using var reader = new AudioFileReader(path); double duration = reader.TotalTime.TotalSeconds; ValidateDuration(duration);
        if (reader.WaveFormat.Channels is not (1 or 2)) throw new InvalidDataException("모노 또는 스테레오 파일이 필요합니다.");
        for (int index = 0; index * WindowSeconds < duration; index++)
        {
            token.ThrowIfCancellationRequested();
            double keepStart = index * WindowSeconds, keepEnd = Math.Min(duration, keepStart + WindowSeconds);
            double start = Math.Max(0, keepStart - ContextSeconds), end = Math.Min(duration, keepEnd + ContextSeconds);
            reader.CurrentTime = TimeSpan.FromSeconds(start);
            ISampleProvider source = reader.WaveFormat.Channels == 2 ? new StereoToMonoSampleProvider(reader) : reader;
            if (source.WaveFormat.SampleRate != SampleRate) source = new WdlResamplingSampleProvider(source, SampleRate);
            var samples = new float[(int)Math.Ceiling((end - start) * SampleRate)];
            int count = 0, read;
            while (count < samples.Length && (read = source.Read(samples, count, Math.Min(SampleRate, samples.Length - count))) > 0)
            {
                token.ThrowIfCancellationRequested(); count += read;
            }
            if (count < (keepEnd - start) * SampleRate - 160) throw new InvalidDataException("녹음 길이보다 오디오 데이터가 짧습니다.");
            if (count != samples.Length) Array.Resize(ref samples, count);
            foreach (float value in samples) if (!float.IsFinite(value)) throw new InvalidDataException("오디오 데이터가 올바르지 않습니다.");
            yield return new(start, keepStart, keepEnd, samples);
        }
    }
}
