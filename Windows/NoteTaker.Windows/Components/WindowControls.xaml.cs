using System.Windows;
using System.Windows.Controls;

namespace NoteTaker.Windows.Components;

public partial class WindowControls : UserControl
{
    public WindowControls()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            var window = Window.GetWindow(this);
            MinimizeButton.IsEnabled = window.ResizeMode != ResizeMode.NoResize;
            MaximizeButton.IsEnabled = window.ResizeMode is ResizeMode.CanResize or ResizeMode.CanResizeWithGrip;
        };
    }
    private void Close_Click(object sender, RoutedEventArgs e) => SystemCommands.CloseWindow(Window.GetWindow(this));
    private void Minimize_Click(object sender, RoutedEventArgs e) => SystemCommands.MinimizeWindow(Window.GetWindow(this));
    private void Maximize_Click(object sender, RoutedEventArgs e)
    {
        var window = Window.GetWindow(this);
        if (window.WindowState == WindowState.Maximized) SystemCommands.RestoreWindow(window); else SystemCommands.MaximizeWindow(window);
    }
}
