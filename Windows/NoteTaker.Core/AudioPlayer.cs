using NAudio.Wave;

namespace NoteTaker.Core;

public sealed class AudioPlayer : IDisposable
{
    private WaveOutEvent? output;
    private AudioFileReader? reader;
    private AudioRangeSampleProvider? ranges;
    public double Position => reader?.CurrentTime.TotalSeconds ?? 0;
    public double Duration => reader?.TotalTime.TotalSeconds ?? 0;
    public bool IsPlaying => output?.PlaybackState == PlaybackState.Playing;
    public bool HasRangePlayback => ranges is not null;
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
        if (ranges?.Finished == true && !IsPlaying) StopRanges();
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
    public void PlayRanges(IEnumerable<AudioRange> selected)
    {
        if (reader is null) throw new InvalidOperationException("오디오를 먼저 불러와 주세요.");
        output?.Dispose(); output = null; ranges = null;
        var provider = new AudioRangeSampleProvider(reader, selected);
        var device = new WaveOutEvent();
        try { device.Init(provider); output = device; ranges = provider; device.Play(); }
        catch { device.Dispose(); output = null; ranges = null; throw; }
    }
    public void StopRanges()
    {
        if (ranges is null) return;
        output?.Dispose(); output = null; ranges = null;
    }
    public void Dispose()
    {
        output?.Dispose(); output = null;
        ranges = null;
        reader?.Dispose(); reader = null;
    }
}
