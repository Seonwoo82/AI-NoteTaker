using NAudio.Wave;

namespace NoteTaker.Core;

public sealed record RecentAudioWindow(byte[] Pcm, double EndSeconds, long Generation);
public interface IRecentAudioSource { RecentAudioWindow? RecentAudio(); }

public sealed class RecentAudioBuffer
{
    private readonly byte[] buffer = new byte[3 * AudioFiles.SampleRate * 4];
    private int cursor, count;
    private long generation;
    private double endSeconds;
    public void Append(ReadOnlySpan<byte> pcm, double end)
    {
        if (pcm.Length % 4 != 0) throw new ArgumentException("Expected stereo PCM16 frames.");
        if (pcm.Length >= buffer.Length) { pcm[^buffer.Length..].CopyTo(buffer); cursor = 0; count = buffer.Length; }
        else
        {
            int first = Math.Min(pcm.Length, buffer.Length - cursor); pcm[..first].CopyTo(buffer.AsSpan(cursor)); pcm[first..].CopyTo(buffer);
            cursor = (cursor + pcm.Length) % buffer.Length; count = Math.Min(buffer.Length, count + pcm.Length);
        }
        endSeconds = end;
    }
    public RecentAudioWindow? Snapshot()
    {
        if (count < buffer.Length) return null;
        byte[] result = new byte[count]; buffer.AsSpan(cursor).CopyTo(result); buffer.AsSpan(0, cursor).CopyTo(result.AsSpan(buffer.Length - cursor));
        return new(result, endSeconds, generation);
    }
    public void Clear() { Array.Clear(buffer); cursor = count = 0; generation++; }
    public static byte[] Wave(RecentAudioWindow window)
    {
        using var stream = new MemoryStream();
        using (var writer = new WaveFileWriter(new NAudio.Utils.IgnoreDisposeStream(stream), AudioFiles.RecordingFormat)) writer.Write(window.Pcm, 0, window.Pcm.Length);
        return stream.ToArray();
    }
}
