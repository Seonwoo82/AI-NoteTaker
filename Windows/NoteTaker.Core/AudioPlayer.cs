using NAudio.Wave;

namespace NoteTaker.Core;

public sealed class AudioPlayer : IDisposable
{
    private WaveOutEvent? output;
    private AudioFileReader? reader;
    public double Position => reader?.CurrentTime.TotalSeconds ?? 0;
    public double Duration => reader?.TotalTime.TotalSeconds ?? 0;
    public bool IsPlaying => output?.PlaybackState == PlaybackState.Playing;
    public void Load(string path)
    {
        Dispose();
        try
        {
            reader = new AudioFileReader(path);
        }
        catch { Dispose(); throw; }
    }
    public void Toggle()
    {
        if (reader is null) return;
        // Seeking and waveform inspection should work even without a playback device.
        if (output is null)
        {
            var device = new WaveOutEvent();
            try { device.Init(reader); output = device; }
            catch { device.Dispose(); throw; }
        }
        if (IsPlaying) output.Pause();
        else
        {
            if (reader.Position >= reader.Length) reader.Position = 0;
            output.Play();
        }
    }
    public void Seek(double seconds)
    {
        if (reader is not null) reader.CurrentTime = TimeSpan.FromSeconds(Math.Clamp(seconds, 0, Duration));
    }
    public void Dispose()
    {
        output?.Dispose(); output = null;
        reader?.Dispose(); reader = null;
    }
}
