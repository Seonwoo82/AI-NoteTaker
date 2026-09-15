using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace NoteTaker.Windows.Components;

internal static class Appearance
{
    private static readonly string[] Keys = ["Ink", "Muted", "WindowSurface", "SidebarSurface", "ToolbarSurface", "CardSurface", "ControlSurface", "HoverSurface", "PressedSurface", "SegmentSurface", "Separator", "Accent", "AccentSoft", "RecordRed", "OnAccent", "WaveformInk"];
    private static readonly string[] Light = ["#242426", "#737377", "#FAFAFA", "#EDEDEE", "#F3F3F4", "#FFFFFF", "#FFFFFF", "#E4E4E6", "#D5D5D8", "#E7E7E9", "#D8D8DB", "#007AFF", "#E6F0FD", "#FF3B30", "#FFFFFF", "#37373A"];
    private static readonly string[] Dark = ["#F1F1F3", "#ABABAF", "#242426", "#2C2C2E", "#303032", "#303032", "#49494C", "#424245", "#555559", "#343436", "#4B4B4F", "#0A84FF", "#253B52", "#FF453A", "#FFFFFF", "#D8D8DC"];
    public static bool IsDark { get; private set; }
    public static void ApplySystem()
    {
        bool dark = false;
        try { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"); dark = key?.GetValue("AppsUseLightTheme") is int value && value == 0; }
        catch (System.Security.SecurityException) { }
        Apply(dark);
    }
    public static void Apply(bool dark)
    {
        IsDark = dark;
        var colors = dark ? Dark : Light;
        for (int i = 0; i < Keys.Length; i++) Application.Current.Resources[Keys[i]] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(colors[i]));
        if (SystemParameters.HighContrast)
        {
            foreach (string key in new[] { "WindowSurface", "SidebarSurface", "ToolbarSurface", "CardSurface", "ControlSurface", "SegmentSurface", "AccentSoft" }) Application.Current.Resources[key] = SystemColors.WindowBrush;
            foreach (string key in new[] { "Ink", "Muted", "Separator", "WaveformInk" }) Application.Current.Resources[key] = SystemColors.WindowTextBrush;
            Application.Current.Resources["Accent"] = SystemColors.HighlightBrush;
            Application.Current.Resources["OnAccent"] = SystemColors.HighlightTextBrush;
        }
    }
}
