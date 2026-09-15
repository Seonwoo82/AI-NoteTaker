namespace NoteTaker.Core;

/// <summary>Absolute audio interval shown by the focused timeline.</summary>
public readonly record struct WaveformViewport
{
    public double TotalDuration { get; }
    public double Start { get; }
    public double End { get; }
    public double Duration => End - Start;

    public WaveformViewport(double duration, double currentTime, double span = 300)
    {
        TotalDuration = double.IsFinite(duration) ? Math.Max(0, duration) : 0;
        double width = Math.Min(TotalDuration, double.IsFinite(span) && span > 0 ? span : 300);
        double playhead = double.IsFinite(currentTime) ? Math.Clamp(currentTime, 0, TotalDuration) : 0;
        Start = Math.Min(Math.Max(0, playhead - width / 2), Math.Max(0, TotalDuration - width));
        End = Math.Min(TotalDuration, Start + width);
    }

    public double TimeAt(double fraction) => Start + Duration * (double.IsFinite(fraction) ? Math.Clamp(fraction, 0, 1) : 0);
    public double PositionOf(double time) => Duration > 0 && double.IsFinite(time) ? Math.Clamp((time - Start) / Duration, 0, 1) : 0;

    public float[] Peaks(ReadOnlySpan<float> values, int barCount = 96)
    {
        if (TotalDuration <= 0 || Duration <= 0 || values.IsEmpty || barCount <= 0) return [];
        int count = Math.Min(barCount, values.Length);
        var result = new float[count];
        for (int index = 0; index < count; index++)
        {
            int lower = Math.Clamp((int)Math.Floor(TimeAt((double)index / count) / TotalDuration * values.Length), 0, values.Length - 1);
            int upper = Math.Clamp((int)Math.Ceiling(TimeAt((double)(index + 1) / count) / TotalDuration * values.Length), lower + 1, values.Length);
            foreach (float value in values[lower..upper])
                if (float.IsFinite(value)) result[index] = Math.Max(result[index], Math.Clamp(value, 0, 1));
        }
        return result;
    }

    public static float[] OverviewPeaks(ReadOnlySpan<float> values, int barCount = 96) => new WaveformViewport(1, 0, 1).Peaks(values, barCount);
}
