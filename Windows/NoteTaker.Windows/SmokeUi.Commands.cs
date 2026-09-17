using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using NoteTaker.Core;

namespace NoteTaker.Windows;

internal static partial class SmokeUi
{
    private static async Task VerifyLibraryCommandsAsync(string output)
    {
        var library = new LibraryStore(Path.Combine(output, "commands-" + Guid.NewGuid().ToString("N")));
        string source = Path.Combine(output, "import-" + Guid.NewGuid().ToString("N") + ".wav"); CreateFixtureAudio(source);
        var window = new MainWindow(library, discoverDevices: false, enableDesktopIntegration: false)
        { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        window.Show();
        const ModifierKeys controlShift = ModifierKeys.Control | ModifierKeys.Shift;
        try
        {
            if (window.Icon is null) throw new InvalidOperationException("WPF app icon is missing.");
            VerifyExecutableIcon(output);
            window.CreateNamedFolder("가져올 회의");
            var folder = (TreeViewItem)((TreeView)window.FindName("FolderTree")).Items[0]; folder.IsSelected = true;
            var folderId = ((RecordingCollectionFolder)folder.Tag).Id;
            window.AudioImportSource = () => source;
            Require(window.HandleShortcut(Key.O, ModifierKeys.Control, null), "Import shortcut was not handled."); await window.CurrentWork;
            var recording = library.Load().Single(); Require(recording.FolderId == folderId, "File picker import lost selected folder.");
            string hash = SyncFileTransaction.Revision(library.AudioPath(recording.Id))!;
            var search = (TextBox)window.FindName("SearchBox");
            Require(!window.HandleShortcut(Key.Delete, ModifierKeys.None, search) && !window.HandleShortcut(Key.L, controlShift, search) &&
                !window.HandleShortcut(Key.N, ModifierKeys.Control, search) && !window.HandleShortcut(Key.Left, ModifierKeys.Control, search), "Text input consumed a library command.");
            await window.WaveformLoadTask;
            var waveform = (Components.WaveformControl)window.FindName("PlaybackSlider");
            waveform.RequestSeek(20);
            Require(window.HandleShortcut(Key.Left, ModifierKeys.Control, null) && Math.Abs(waveform.Position - 5) < .01, "Back shortcut did not seek 15 seconds.");
            Require(window.HandleShortcut(Key.Right, ModifierKeys.Control, null) && Math.Abs(waveform.Position - 20) < .01, "Forward shortcut did not seek 15 seconds.");
            Require(window.HandleShortcut(Key.L, controlShift, null) && library.Load().Single().IsFavorite, "Favorite shortcut did not persist.");
            Task? fill = null;
            var dispatch = window.Dispatcher.InvokeAsync(() => fill = FillRename());
            async Task FillRename()
            {
                var dialog = window.OwnedWindows.OfType<RenameWindow>().Single();
                try
                {
                    Descendants<TextBox>(dialog).Single().Text = "키보드 테스트 회의";
                    await CaptureAsync(dialog, Path.Combine(output, "rename-shortcut.png"));
                    Descendants<Button>(dialog).Single(b => b.Content as string == "저장").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                }
                finally { if (dialog.IsVisible) dialog.Close(); }
            }
            Require(window.HandleShortcut(Key.F2, ModifierKeys.None, null), "Rename shortcut was not handled."); await dispatch; if (fill is not null) await fill;
            Require(library.Load().Single().Title == "키보드 테스트 회의", "Rename shortcut did not save.");
            string? revealed = null; window.RevealAudioLocation = path => revealed = path;
            Require(window.HandleShortcut(Key.R, controlShift, null) && revealed == library.AudioPath(recording.Id), "Reveal shortcut targeted another recording.");
            string exported = Path.Combine(output, "command-export-" + recording.Id.ToString("N") + ".wav");
            window.AudioExportDestination = _ => exported;
            Require(window.HandleShortcut(Key.E, controlShift, null), "Export shortcut was not handled."); await window.LastLibraryAction;
            Require(SyncFileTransaction.Revision(exported) == hash, "Export shortcut changed audio.");
            window.AudioImportSource = () => null; window.HandleShortcut(Key.O, ModifierKeys.Control, null); await window.CurrentWork;
            Require(library.Load().Count == 1, "Cancelled import added a recording.");
            window.Width = 840; window.Height = 600; await CaptureAsync(window, Path.Combine(output, "compact-library-commands.png"));
            Require(!window.HandleShortcut(Key.Enter, ModifierKeys.None, new Button()), "Enter over a button opened Rename.");
            Require(window.HandleShortcut(Key.Delete, ModifierKeys.None, null) && library.Load().Single().DeletedAt is not null, "Delete shortcut failed.");
            ((ListBox)window.FindName("FilterBox")).SelectedIndex = 2;
            Require(!window.HandleShortcut(Key.Delete, ModifierKeys.None, null) && !window.HandleShortcut(Key.F2, ModifierKeys.None, null), "Trash shortcut restored or renamed an item.");
            Require(SyncFileTransaction.Revision(library.AudioPath(recording.Id)) == hash, "Library commands changed original audio.");
            JsonDisk.Write(Path.Combine(output, "library-commands.json"), new { Passed = true, SelectedFolderImport = true, TextEditingProtection = true,
                RenameFavoriteExportRevealDelete = true, PlaybackSeek = true, NativeExecutableIcon = true, Scope = "Production shortcut dispatcher and WPF rename dialog. Synthetic WAV; file pickers/reveal callbacks supplied by fixture. Physical keypress and Explorer launch not asserted." });
        }
        finally
        {
            var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            window.Closed += (_, _) => closed.TrySetResult(); window.RequestExit(); await closed.Task;
        }
        static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
        {
            if (root is T item) yield return item;
            foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
                foreach (var descendant in Descendants<T>(child)) yield return descendant;
        }
    }
    private static void VerifyExecutableIcon(string output)
    {
        uint count = ExtractIconEx(Path.Combine(AppContext.BaseDirectory, "AI-NoteTaker.exe"), 0, out nint large, out nint small, 1);
        try
        {
            if (count == 0 || large == 0) throw new InvalidOperationException("Windows executable icon is missing.");
            var bitmap = Imaging.CreateBitmapSourceFromHIcon(large, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var file = File.Create(Path.Combine(output, "executable-icon.png")); encoder.Save(file);
        }
        finally { if (large != 0) DestroyIcon(large); if (small != 0) DestroyIcon(small); }
    }
    [DllImport("shell32.dll", EntryPoint = "ExtractIconExW", CharSet = CharSet.Unicode)] private static extern uint ExtractIconEx(string file, int index, out nint large, out nint small, uint count);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(nint icon);
}
