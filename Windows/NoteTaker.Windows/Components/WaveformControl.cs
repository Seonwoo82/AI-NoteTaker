using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using NoteTaker.Core;

namespace NoteTaker.Windows.Components;

public sealed class WaveformControl : Control
{
    public static readonly DependencyProperty PeaksProperty = DependencyProperty.Register(nameof(Peaks), typeof(float[]), typeof(WaveformControl), new FrameworkPropertyMetadata(Array.Empty<float>(), FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty PositionProperty = DependencyProperty.Register(nameof(Position), typeof(double), typeof(WaveformControl), new FrameworkPropertyMetadata(0d, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty DurationProperty = DependencyProperty.Register(nameof(Duration), typeof(double), typeof(WaveformControl), new FrameworkPropertyMetadata(0d, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty IsOverviewProperty = DependencyProperty.Register(nameof(IsOverview), typeof(bool), typeof(WaveformControl), new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));
    public float[] Peaks { get => (float[])GetValue(PeaksProperty); set => SetValue(PeaksProperty, value); }
    public double Position { get => (double)GetValue(PositionProperty); set => SetValue(PositionProperty, value); }
    public double Duration { get => (double)GetValue(DurationProperty); set => SetValue(DurationProperty, value); }
    public bool IsOverview { get => (bool)GetValue(IsOverviewProperty); set => SetValue(IsOverviewProperty, value); }
    public event Action<double>? SeekRequested;
    public WaveformControl()
    {
        Focusable = true; Cursor = Cursors.Hand;
        SetResourceReference(ForegroundProperty, "WaveformInk");
        SetResourceReference(FocusVisualStyleProperty, "FocusRing");
    }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        var accent = (Brush)FindResource("Accent"); var muted = (Brush)FindResource("Muted");
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        double inset = IsOverview ? 5 : 0, reserve = IsOverview ? 0 : 24;
        double height = Math.Max(2, ActualHeight - reserve - inset * 2), mid = inset + height / 2;
        if (IsOverview) dc.DrawRoundedRectangle((Brush)FindResource("SegmentSurface"), null, new Rect(RenderSize), 9, 9);
        if (Peaks.Length == 0) return;
        double stride = ActualWidth / Peaks.Length, width = Math.Min(IsOverview ? 2 : 2.4, stride * .6);
        for (int i = 0; i < Peaks.Length; i++)
        {
            double barHeight = Math.Max(2, height * Math.Clamp(Peaks[i], 0, 1));
            dc.DrawRoundedRectangle(Foreground, null, new Rect((i + .5) * stride - width / 2, mid - barHeight / 2, width, barHeight), 1, 1);
        }
        if (Duration <= 0 || !double.IsFinite(Duration)) return;
        double x = Math.Clamp(Position / Duration, 0, 1) * Math.Max(0, ActualWidth - 2) + 1;
        dc.DrawLine(new Pen(accent, IsOverview ? 1.5 : 2), new Point(x, inset), new Point(x, ActualHeight - reserve - inset));
        if (!IsOverview)
        {
            dc.DrawEllipse(accent, null, new Point(x, 4), 3, 3);
            double step = Math.Max(15, Math.Ceiling(Duration / 15 / 6) * 15);
            for (double time = 0; time <= Duration; time += step)
            {
                var label = new FormattedText(Recording.FormatTime(time), System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Consolas"), 10, muted, VisualTreeHelper.GetDpi(this).PixelsPerDip);
                double left = Math.Clamp(time / Duration * ActualWidth - label.Width / 2, 0, Math.Max(0, ActualWidth - label.Width));
                dc.DrawText(label, new Point(left, ActualHeight - 16));
            }
        }
    }
    private void SeekAt(MouseEventArgs e) => RequestSeek(Duration * Math.Clamp(e.GetPosition(this).X / Math.Max(1, ActualWidth), 0, 1));
    internal void RequestSeek(double position)
    {
        if (!IsEnabled || Duration <= 0 || !double.IsFinite(position)) return;
        SetCurrentValue(PositionProperty, Math.Clamp(position, 0, Duration)); SeekRequested?.Invoke(Position);
    }
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e) { base.OnMouseLeftButtonDown(e); Focus(); CaptureMouse(); SeekAt(e); e.Handled = true; }
    protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); if (IsMouseCaptured && e.LeftButton == MouseButtonState.Pressed) SeekAt(e); }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) { base.OnMouseLeftButtonUp(e); if (IsMouseCaptured) { SeekAt(e); ReleaseMouseCapture(); } }
    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.Left) RequestSeek(Position - 15);
        else if (e.Key == Key.Right) RequestSeek(Position + 15);
        else if (e.Key == Key.Home) RequestSeek(0);
        else if (e.Key == Key.End) RequestSeek(Duration);
        else return;
        e.Handled = true;
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new WaveformPeer(this);
    protected override void OnPropertyChanged(DependencyPropertyChangedEventArgs e) { base.OnPropertyChanged(e); if (e.Property == ForegroundProperty) InvalidateVisual(); }
    private sealed class WaveformPeer(WaveformControl owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
    {
        protected override string GetClassNameCore() => "Waveform";
        protected override string GetNameCore() => "녹음 파형과 재생 위치";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;
        public override object? GetPattern(PatternInterface pattern) => pattern == PatternInterface.RangeValue ? this : base.GetPattern(pattern);
        public bool IsReadOnly => !owner.IsEnabled;
        public double LargeChange => 15; public double SmallChange => 1; public double Maximum => owner.Duration; public double Minimum => 0; public double Value => owner.Position;
        public void SetValue(double value) => owner.Dispatcher.Invoke(() => owner.RequestSeek(value));
    }
}
