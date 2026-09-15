using NAudio.Wave;

namespace NoteTaker.Core;

public readonly record struct AudioRange(double Start, double End);

/// <summary>Copies only selected PCM frames; the output never includes speech between ranges.</summary>
public sealed class AudioRangeSampleProvider : ISampleProvider
{
    private readonly AudioFileReader source;
    private readonly Queue<(long Start, long End)> ranges;
    private long remainingFrames;
    public WaveFormat WaveFormat => source.WaveFormat;
    public bool Finished { get; private set; }

    public AudioRangeSampleProvider(AudioFileReader source, IEnumerable<AudioRange> selected)
    {
        this.source = source;
        var merged = new List<(long Start, long End)>();
        long totalFrames = source.Length / source.WaveFormat.BlockAlign;
        foreach (var range in selected.OrderBy(r => r.Start))
        {
            if (!double.IsFinite(range.Start) || !double.IsFinite(range.End) || range.Start < 0 || range.End <= range.Start || range.End > source.TotalTime.TotalSeconds + .001)
                throw new InvalidDataException("재생 구간이 오디오 범위를 벗어났습니다.");
            long start = Math.Min(totalFrames, (long)Math.Round(range.Start * WaveFormat.SampleRate));
            long end = Math.Min(totalFrames, (long)Math.Round(range.End * WaveFormat.SampleRate));
            if (end <= start) continue;
            if (merged.Count > 0 && start <= merged[^1].End) merged[^1] = (merged[^1].Start, Math.Max(end, merged[^1].End));
            else merged.Add((start, end));
        }
        if (merged.Count == 0) throw new InvalidDataException("재생할 발화가 없습니다.");
        ranges = new(merged); Next();
    }
    public int Read(float[] buffer, int offset, int count)
    {
        if (offset < 0 || count < 0 || offset > buffer.Length - count) throw new ArgumentOutOfRangeException(nameof(count));
        int written = 0, channels = WaveFormat.Channels;
        count -= count % channels;
        while (written < count && !Finished)
        {
            if (remainingFrames == 0) { Next(); continue; }
            int requested = (int)Math.Min(count - written, remainingFrames * channels);
            int read = source.Read(buffer, offset + written, requested);
            if (read == 0) { Finished = true; break; }
            remainingFrames -= read / channels; written += read;
        }
        return written;
    }
    private void Next()
    {
        if (!ranges.TryDequeue(out var range)) { Finished = true; return; }
        source.Position = range.Start * WaveFormat.BlockAlign;
        remainingFrames = range.End - range.Start;
    }
}
