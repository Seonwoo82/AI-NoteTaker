using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace NoteTaker.Windows.Components;

// Original vector paths, with the compact outline weight used by the SwiftUI app.
// No dependency on installed symbol fonts or downloaded SF Symbols assets.
public sealed class AppleIcon : Control
{
    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(nameof(Kind), typeof(string), typeof(AppleIcon), new FrameworkPropertyMetadata("waveform", FrameworkPropertyMetadataOptions.AffectsRender));
    public string Kind { get => (string)GetValue(KindProperty); set => SetValue(KindProperty, value); }
    private static readonly Dictionary<string, Geometry> Paths = new()
    {
        ["waveform"] = Geometry.Parse("M3,9 V15 M7,5 V19 M11,2 V22 M15,7 V17 M19,4 V20 M23,10 V14"),
        ["search"] = Geometry.Parse("M16,10 A6,6 0 1 1 4,10 A6,6 0 1 1 16,10 M14.5,14.5 L21,21"),
        ["folder"] = Geometry.Parse("M3,5 L9,5 L11,8 L21,8 L21,20 L3,20 Z"),
        ["trash"] = Geometry.Parse("M4,6 H20 M9,6 V3 H15 V6 M6,6 L7,21 H17 L18,6 M10,10 V17 M14,10 V17"),
        ["star"] = Geometry.Parse("M12,2 L15,8.5 L22,9.2 L17,14 L18.5,21 L12,17.5 L5.5,21 L7,14 L2,9.2 L9,8.5 Z"),
        ["sparkles"] = Geometry.Parse("M9,4 L11,10 L17,12 L11,14 L9,20 L7,14 L1,12 L7,10 Z M19,1 L20,5 L24,6 L20,7 L19,11 L18,7 L14,6 L18,5 Z"),
        ["mic"] = Geometry.Parse("M8,5 A4,4 0 0 1 16,5 V12 A4,4 0 0 1 8,12 Z M5,11 V12 A7,7 0 0 0 19,12 V11 M12,19 V23 M8,23 H16"),
        ["speaker"] = Geometry.Parse("M3,9 H7 L12,5 V19 L7,15 H3 Z M16,8 Q21,12 16,16 M19,4 Q28,12 19,20"),
        ["play"] = Geometry.Parse("M6,3 L21,12 L6,21 Z"),
        ["pause"] = Geometry.Parse("M6,3 H10 V21 H6 Z M14,3 H18 V21 H14 Z"),
        ["back"] = Geometry.Parse("M6,6 A9,9 0 1 1 3,14 M6,2 V7 H1"),
        ["forward"] = Geometry.Parse("M18,6 A9,9 0 1 0 21,14 M18,2 V7 H23"),
        ["import"] = Geometry.Parse("M4,14 V21 H20 V14 M12,2 V15 M7,10 L12,15 L17,10"),
        ["export"] = Geometry.Parse("M4,10 V21 H20 V10 M12,15 V2 M7,7 L12,2 L17,7"),
        ["chevrons"] = Geometry.Parse("M7,9 L12,4 L17,9 M7,15 L12,20 L17,15"),
        ["chevron"] = Geometry.Parse("M7,10 L12,15 L17,10"),
        ["sidebar"] = Geometry.Parse("M3,4 H21 V20 H3 Z M9,4 V20 M5,8 H7 M5,12 H7"),
        ["settings"] = Geometry.Parse("M10,2 H14 L15,5 L18,6 L21,5 L23,9 L20,11 V14 L22,17 L19,21 L16,19 L14,20 L13,23 H9 L8,20 L5,18 L2,19 L0,15 L3,13 V10 L1,7 L4,3 L7,5 L9,4 Z M16,12 A4,4 0 1 1 8,12 A4,4 0 1 1 16,12"),
        ["document"] = Geometry.Parse("M5,2 H15 L20,7 V22 H5 Z M15,2 V7 H20 M8,11 H17 M8,15 H17 M8,19 H14"),
        ["link"] = Geometry.Parse("M10,7 L11,6 A5,5 0 0 1 18,13 L16,15 A5,5 0 0 1 9,15 M14,17 L13,18 A5,5 0 0 1 6,11 L8,9 A5,5 0 0 1 15,9"),
        ["key"] = Geometry.Parse("M11,8 A5,5 0 1 1 1,8 A5,5 0 1 1 11,8 M11,8 H23 M18,8 V13 M22,8 V12"),
        ["refresh"] = Geometry.Parse("M20,8 A9,9 0 1 0 20,17 M20,3 V9 H14"),
        ["info"] = Geometry.Parse("M22,12 A10,10 0 1 1 2,12 A10,10 0 1 1 22,12 M12,10 V18 M12,6 V7"),
        ["close"] = Geometry.Parse("M6,6 L18,18 M18,6 L6,18")
    };
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        if (!Paths.TryGetValue(Kind, out var path)) return;
        double side = Math.Min(ActualWidth, ActualHeight);
        dc.PushTransform(new TranslateTransform((ActualWidth - side) / 2, (ActualHeight - side) / 2));
        dc.PushTransform(new ScaleTransform(side / 26, side / 26));
        dc.PushTransform(new TranslateTransform(1, 1));
        var pen = new Pen(Foreground, 1.65) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        dc.DrawGeometry(Kind is "play" or "pause" ? Foreground : null, pen, path);
        if (Kind is "back" or "forward")
        {
            var label = new FormattedText("15", System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 8, Foreground, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            dc.DrawText(label, new Point(12 - label.Width / 2, 8));
        }
        dc.Pop(); dc.Pop(); dc.Pop();
    }
    protected override void OnPropertyChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.Property == ForegroundProperty) InvalidateVisual();
    }
}
