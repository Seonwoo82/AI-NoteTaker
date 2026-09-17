using System.Buffers.Binary;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class CapturePreferencesTests
{
    [Fact] public void LocalCaptureSettingsRoundTripWithoutChangingAiSettings()
    {
        string root = Path.Combine(Path.GetTempPath(), "notetaker-capture-" + Guid.NewGuid().ToString("N"));
        try
        {
            var ai = new SettingsStore(root); ai.Save(new() { SummaryModel = "fixture/custom" });
            byte[] original = File.ReadAllBytes(Path.Combine(root, "settings.json"));
            var capture = new CapturePreferencesStore(root);
            Assert.Equal(new CapturePreferences(), capture.Load());
            capture.Save(new() { Mode = RecordingMode.SystemAudio, MicrophoneId = "mic-local", OutputId = "speaker-local", MicrophoneGain = .5f, SystemGain = 1.5f });
            var loaded = new CapturePreferencesStore(root).Load();
            Assert.Equal(RecordingMode.SystemAudio, loaded.Mode); Assert.Equal("mic-local", loaded.MicrophoneId);
            Assert.Equal(.5f, loaded.MicrophoneGain); Assert.Equal(1.5f, loaded.SystemGain);
            Assert.Equal(original, File.ReadAllBytes(Path.Combine(root, "settings.json")));
            capture.Save(loaded with { Mode = RecordingMode.Imported, MicrophoneGain = float.NaN, SystemGain = 8 });
            Assert.Equal(RecordingMode.Mixed, capture.Load().Mode); Assert.Equal(1, capture.Load().MicrophoneGain); Assert.Equal(2, capture.Load().SystemGain);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Fact] public void PerSourceGainPreservesStereoAndClampsWithoutWrapping()
    {
        byte[] mic = Pcm(3200, -6400), system = Pcm(1600, 2400), output = new byte[4];
        PcmMixer.Mix([mic, system], output, 4, [.5f, 1.5f]);
        Assert.Equal(Pcm(2000, 200), output);
        PcmMixer.Mix([mic, system], output, 4, [0, 2]); Assert.Equal(system, output);
        PcmMixer.Mix([Pcm(30000, -30000)], output, 4, [2]); Assert.Equal(Pcm(short.MaxValue, short.MinValue), output);
        Assert.Throws<ArgumentException>(() => PcmMixer.Mix([mic], output, 4, [float.NaN]));
        Assert.Throws<ArgumentException>(() => PcmMixer.Mix([mic, system], output, 4, [1]));
        Assert.Equal(Pcm(3200, -6400), mic);
    }

    [Fact] public void InputDurationUsesSampleFramesAndDoesNotDoubleCountPollingOrSilence()
    {
        var whole = new MicrophoneInputActivity(48000, 2); var split = new MicrophoneInputActivity(48000, 2);
        byte[] voiced = Enumerable.Repeat(Pcm(30, -30), 48000).SelectMany(x => x).ToArray();
        byte[] silence = new byte[48000 * 4];
        whole.Append(voiced); whole.Append(silence);
        for (int i = 0; i < voiced.Length; i += 148) split.Append(voiced.AsSpan(i, Math.Min(148, voiced.Length - i)));
        split.Append(silence);
        Assert.Equal(1, whole.DetectedSeconds, 6); Assert.Equal(whole.DetectedSeconds, split.DetectedSeconds, 6);
        for (int i = 0; i < 20; i++) Assert.Equal(1, split.DetectedSeconds, 6);
        Assert.Equal(0, split.Rms); Assert.Equal(0, MicrophoneInputActivity.Meter(0));
        Assert.InRange(MicrophoneInputActivity.Meter(.0009f), .3f, .4f);
        Assert.Throws<ArgumentException>(() => split.Append(new byte[3]));
    }
    private static byte[] Pcm(short left, short right)
    {
        byte[] bytes = new byte[4]; BinaryPrimitives.WriteInt16LittleEndian(bytes, left); BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(2), right); return bytes;
    }
}
