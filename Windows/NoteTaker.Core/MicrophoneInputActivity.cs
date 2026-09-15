using System.Buffers.Binary;

namespace NoteTaker.Core;

// Measures input energy, not whether a person is speaking. Feed actual PCM callbacks once.
public sealed class MicrophoneInputActivity(int sampleRate, int channels)
{
    private readonly int frameSamples = checked(Math.Max(1, sampleRate / 50) * channels);
    private int bufferedSamples;
    private double energy, activeSamples;
    public double DetectedSeconds => activeSamples / (sampleRate * (double)channels);
    public float Rms { get; private set; }
    public static float Meter(float rms) => rms > 0 && float.IsFinite(rms) ? (float)Math.Clamp((20 * Math.Log10(rms) + 80) / 60, 0, 1) : 0;
    public void Append(ReadOnlySpan<byte> pcm16)
    {
        if (sampleRate <= 0 || channels <= 0 || pcm16.Length % (2 * channels) != 0) throw new ArgumentException("마이크 PCM 형식이 올바르지 않습니다.");
        for (int i = 0; i < pcm16.Length; i += 2)
        {
            double sample = BinaryPrimitives.ReadInt16LittleEndian(pcm16.Slice(i, 2)) / 32768d;
            energy += sample * sample;
            if (++bufferedSamples < frameSamples) continue;
            Rms = (float)Math.Sqrt(energy / bufferedSamples);
            if (Rms >= .0003f) activeSamples += bufferedSamples;
            energy = 0; bufferedSamples = 0;
        }
    }
}
