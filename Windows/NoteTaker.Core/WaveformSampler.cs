using NAudio.Wave;

namespace NoteTaker.Core;

public static class WaveformSampler
{
    // A bounded peak envelope is computed from real audio; no invented placeholder bars.
    public static float[] Read(string path, int buckets = 240, CancellationToken token = default)
    {
        if (buckets is < 1 or > 4096) throw new ArgumentOutOfRangeException(nameof(buckets));
        using var reader = new AudioFileReader(path);
        long totalSamples = reader.Length / sizeof(float);
        if (totalSamples == 0) return [];
        var peaks = new float[buckets];
        var buffer = new float[16384];
        long position = 0; int read;
        while ((read = reader.Read(buffer, 0, buffer.Length)) > 0)
        {
            token.ThrowIfCancellationRequested();
            for (int i = 0; i < read; i++, position++)
            {
                int bucket = (int)Math.Min(buckets - 1, position * buckets / totalSamples);
                float value = float.IsFinite(buffer[i]) ? Math.Clamp(Math.Abs(buffer[i]), 0, 1) : 0;
                peaks[bucket] = Math.Max(peaks[bucket], value);
            }
        }
        return peaks;
    }
}
