using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class WaveformViewportTests
{
    [Theory]
    [InlineData(7200, 0, 0, 300)]
    [InlineData(7200, 3600, 3450, 3750)]
    [InlineData(7200, 7190, 6900, 7200)]
    [InlineData(120, 80, 0, 120)]
    [InlineData(0, 0, 0, 0)]
    public void FocusedIntervalTracksPlayheadAndClampsAtEnds(double duration, double time, double start, double end)
    {
        var view = new WaveformViewport(duration, time);
        Assert.Equal(start, view.Start); Assert.Equal(end, view.End);
        Assert.Equal(start, view.TimeAt(0)); Assert.Equal(end, view.TimeAt(1));
    }

    [Fact] public void PointerUsesAbsoluteFocusedTimeInsteadOfWholeRecordingFraction()
    {
        var view = new WaveformViewport(7200, 3600);
        Assert.Equal(3525, view.TimeAt(.25));
        Assert.Equal(.25, view.PositionOf(3525));
        Assert.Equal(3450, view.TimeAt(-1)); Assert.Equal(3750, view.TimeAt(2));
    }

    [Fact] public void PeakEnvelopeRetainsAnImpulseOnlyInsideTheVisibleInterval()
    {
        var peaks = new float[7200]; peaks[20] = .9f; peaks[3510] = .7f; peaks[6000] = 1f;
        var visible = new WaveformViewport(7200, 3600).Peaks(peaks, 100);
        Assert.Equal(100, visible.Length); Assert.Equal(.7f, visible.Max());
        Assert.Equal(.7f, visible[20]); Assert.Equal(0, visible[0]);
        Assert.Equal(1f, WaveformViewport.OverviewPeaks(peaks).Max());
    }

    [Fact] public void InvalidValuesCannotProduceNonfiniteCoordinatesOrPeaks()
    {
        var empty = new WaveformViewport(double.PositiveInfinity, double.NaN);
        Assert.Equal(0, empty.Duration); Assert.Empty(empty.Peaks([.5f]));
        var view = new WaveformViewport(600, double.NaN, -1);
        Assert.Equal(300, view.End); Assert.Equal(0, view.TimeAt(double.NaN));
        Assert.Equal(0, view.PositionOf(double.PositiveInfinity));
        Assert.Equal(new float[] { 0, 0, 0, 1 }, new WaveformViewport(4, 0).Peaks([float.NaN, float.PositiveInfinity, -1, 3], 4));
    }

    [Theory]
    [InlineData(1, 96)]
    [InlineData(7200, 7200)]
    [InlineData(1e12, 86400)]
    public void LongRecordingKeepsSecondResolutionWithinAMemoryBound(double duration, int expected) => Assert.Equal(expected, WaveformSampler.DefaultBucketCount(duration));

    [Fact] public void FifteenMinuteWaveFileRetainsAudibleSectionsAtTheirAbsoluteTimes()
    {
        using var root = new TestFolder(); var path = Path.Combine(root.Root, "long.wav");
        using (var writer = new NAudio.Wave.WaveFileWriter(path, new NAudio.Wave.WaveFormat(8000, 16, 1)))
        {
            var buffer = new byte[16000];
            for (int second = 0; second < 900; second++)
            {
                Array.Clear(buffer);
                if (second is 50 or 350 or 899)
                {
                    float amplitude = second == 350 ? .8f : .25f;
                    for (int sample = 0; sample < 8000; sample++) System.Buffers.Binary.BinaryPrimitives.WriteInt16LittleEndian(buffer.AsSpan(sample * 2, 2), (short)(amplitude * short.MaxValue * Math.Sin(sample * Math.PI / 8)));
                }
                writer.Write(buffer, 0, buffer.Length);
            }
        }
        var peaks = WaveformSampler.Read(path);
        Assert.Equal(900, peaks.Length); Assert.InRange(peaks[350], .79f, .81f); Assert.Equal(0, peaks[349]);
        var focused = new WaveformViewport(900, 400).Peaks(peaks, 300);
        Assert.InRange(focused[100], .79f, .81f); Assert.Equal(0, focused[0]);
        Assert.InRange(new WaveformViewport(900, 900).Peaks(peaks, 300)[299], .24f, .26f);
    }
}
