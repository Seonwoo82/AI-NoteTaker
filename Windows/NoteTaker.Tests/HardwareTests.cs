using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class AudioHardwareFactAttribute : FactAttribute
{
    public AudioHardwareFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("NOTETAKER_AUDIO_SMOKE") != "1")
            Skip = "Opt in with Windows/build.ps1 audio-smoke; this opens real audio devices.";
    }
}

public sealed class HardwareTests
{
    [AudioHardwareFact, Trait("Category", "Hardware")]
    public async Task PlayerOpensPausesAndResumesGeneratedAudio()
    {
        using var folder = new TestFolder(); var path = Path.Combine(folder.Root, "playback.wav");
        TestFolder.Wave(path, 3, .005f);
        using var player = new AudioPlayer();
        player.Load(path); player.Seek(.5); player.Toggle();
        await Task.Delay(150); Assert.True(player.IsPlaying);
        player.Toggle(); Assert.False(player.IsPlaying);
        player.Seek(1); player.Toggle(); Assert.True(player.IsPlaying);
    }
    [AudioHardwareFact, Trait("Category", "Hardware")]
    public async Task SystemAudioCapturePreservesWallClockAcrossPause() => await CaptureAsync(RecordingMode.SystemAudio, playTone: false);

    [AudioHardwareFact, Trait("Category", "Hardware")]
    public async Task SelectedSpeechRangesFinishOnRealOutputWithoutPlayingInterveningTimeline()
    {
        using var folder = new TestFolder(); string path = Path.Combine(folder.Root, "selected-silence.wav");
        TestFolder.Wave(path, 5, 0); // Device output only: no microphone or environmental audio.
        using var player = new AudioPlayer(); player.Load(path);
        player.PlayRanges([new(.25, .5), new(3, 3.25)]);
        Assert.True(player.HasRangePlayback); Assert.True(player.IsPlaying);
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (player.IsPlaying && DateTime.UtcNow < deadline) await Task.Delay(20);
        Assert.False(player.IsPlaying); Assert.InRange(player.Position, 3.249, 3.251);
        player.StopRanges(); Assert.False(player.HasRangePlayback);
        player.Seek(1); player.Toggle(); Assert.True(player.IsPlaying);
        player.Toggle(); Assert.False(player.IsPlaying);
    }

    [AudioHardwareFact, Trait("Category", "Hardware")]
    public async Task MicrophoneCaptureStartsPausesAndFinalizesWave() => await CaptureAsync(RecordingMode.Microphone, playTone: false);

    [AudioHardwareFact, Trait("Category", "Hardware")]
    public async Task MixedCaptureContainsSystemTestTone() => await CaptureAsync(RecordingMode.Mixed, playTone: true);

    [AudioHardwareFact, Trait("Category", "Hardware")]
    public async Task LoopbackContainsSystemTestTone() => await CaptureAsync(RecordingMode.SystemAudio, playTone: true);

    private static async Task CaptureAsync(RecordingMode mode, bool playTone)
    {
        using var folder = new TestFolder();
        var path = Path.Combine(folder.Root, "capture.wav");
        using var enumerator = new MMDeviceEnumerator();
        using var outputDevice = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        using var inputDevice = mode != RecordingMode.SystemAudio ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console) : null;
        await using var recorder = new AudioRecorder();
        await recorder.StartAsync(path, mode, inputDevice?.ID, outputDevice.ID);
        // Opening a Bluetooth microphone can switch its audio profile. Initialize
        // the test renderer afterward so the generated tone uses the active format.
        using var output = playTone ? new WasapiOut(outputDevice, AudioClientShareMode.Shared, false, 100) : null;
        output?.Init(new SignalGenerator(48000, 2) { Frequency = 440, Gain = .025, Type = SignalGeneratorType.Sin });
        output?.Play();
        await Task.Delay(700);
        float firstSystemLevel = recorder.SystemLevel;
        recorder.TogglePause();
        double paused = recorder.DurationSeconds;
        await Task.Delay(350);
        Assert.InRange(recorder.DurationSeconds - paused, -.001, .001);
        recorder.TogglePause();
        await Task.Delay(700);
        float secondSystemLevel = recorder.SystemLevel;
        double duration = await recorder.StopAsync();
        output?.Stop();
        Assert.Null(recorder.Failure);
        Assert.InRange(duration, 1.35, 2.0);
        using var reader = new AudioFileReader(path);
        Assert.InRange(Math.Abs(reader.TotalTime.TotalSeconds - duration), 0, .001);
        var samples = new float[48000]; float peak = 0; int count;
        while ((count = reader.Read(samples, 0, samples.Length)) > 0)
            for (int i = 0; i < count; i++) peak = Math.Max(peak, Math.Abs(samples[i]));
        if (playTone) Assert.True(peak > .002, $"No system test tone detected: file peak={peak}, source peaks={firstSystemLevel}/{secondSystemLevel}, output={outputDevice.FriendlyName}, muted={outputDevice.AudioEndpointVolume.Mute}, volume={outputDevice.AudioEndpointVolume.MasterVolumeLevelScalar}.");
    }
}
