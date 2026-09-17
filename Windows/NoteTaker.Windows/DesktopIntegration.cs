using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;

namespace NoteTaker.Windows;

/// <summary>Owns notification-area and global-key registrations for exactly one window.</summary>
internal sealed class DesktopIntegration : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private const int ShowKey = 0x6110, RecordKey = 0x6111, PauseKey = 0x6112;
    private readonly HwndSource source;
    private readonly Action show, record, pause, exit;
    private readonly uint taskbarCreated;
    private readonly nint icon;
    private readonly HashSet<int> registeredKeys = [];
    private NotifyIconData data;
    private ContextMenu? menu;
    private bool disposed, capturing, paused, busy;
    public bool IsAvailable { get; private set; }
    public string? ShortcutWarning { get; private set; }
    internal int RegisteredShortcutCount => registeredKeys.Count;
    internal nint Handle => source.Handle;

    public DesktopIntegration(Window window, Action show, Action record, Action pause, Action exit)
    {
        source = HwndSource.FromHwnd(new WindowInteropHelper(window).Handle) ?? throw new InvalidOperationException("Windows 창이 준비되지 않았습니다.");
        this.show = show; this.record = record; this.pause = pause; this.exit = exit;
        taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        icon = CreateWaveformIcon();
        data = new NotifyIconData { Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = source.Handle, Id = 1,
            Flags = 1 | 2 | 4 | 0x80, Callback = CallbackMessage, Icon = icon, Tip = "AI-NoteTaker", Info = "", InfoTitle = "", Version = 4 };
        source.AddHook(WindowMessage); AddIcon();
    }
    private void AddIcon()
    {
        IsAvailable = ShellNotifyIcon(0, ref data);
        if (IsAvailable) { data.Version = 4; ShellNotifyIcon(4, ref data); }
    }
    public void ConfigureShortcuts(bool enabled)
    {
        foreach (int id in registeredKeys) UnregisterHotKey(source.Handle, id);
        registeredKeys.Clear(); ShortcutWarning = null;
        if (!enabled) return;
        foreach (var (id, key, label) in new[] { (ShowKey, 0x4eU, "N"), (RecordKey, 0x52U, "R"), (PauseKey, 0x50U, "P") })
        {
            if (RegisterHotKey(source.Handle, id, 0x4007, key)) registeredKeys.Add(id); // Ctrl+Alt+Shift, no repeat
            else ShortcutWarning = $"Ctrl+Alt+Shift+{label} 전역 단축키를 등록하지 못했습니다. 다른 앱에서 사용 중일 수 있습니다.";
        }
    }
    public void Update(bool recording, bool isPaused, bool isBusy, string elapsed)
    {
        capturing = recording; paused = isPaused; busy = isBusy;
        string tip = recording ? $"AI-NoteTaker · {(paused ? "일시정지" : "녹음 중")} · {elapsed}" : busy ? "AI-NoteTaker · 처리 중" : "AI-NoteTaker";
        if (data.Tip == tip) return;
        data.Tip = tip;
        if (IsAvailable) IsAvailable = ShellNotifyIcon(1, ref data);
    }
    private nint WindowMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (disposed) return 0;
        if ((uint)message == taskbarCreated) AddIcon();
        else if (message == 0x312 && registeredKeys.Contains((int)wParam))
        {
            handled = true;
            if ((int)wParam == ShowKey) show();
            else if (!busy && (int)wParam == RecordKey) record();
            else if (!busy && capturing && (int)wParam == PauseKey) pause();
        }
        else if ((uint)message == CallbackMessage)
        {
            int notification = (int)((long)lParam & 0xffff);
            if (notification is 0x400 or 0x401 or 0x203) { handled = true; show(); }
            else if (notification == 0x7b) { handled = true; OpenMenu(); }
        }
        return 0;
    }
    private void OpenMenu()
    {
        if (menu is { IsOpen: true }) return;
        menu = new ContextMenu { Placement = PlacementMode.MousePoint };
        void Add(string label, Action action, bool enabled = true)
        {
            var item = new MenuItem { Header = label, IsEnabled = enabled }; item.Click += (_, _) => action(); menu.Items.Add(item);
        }
        Add("AI-NoteTaker 열기", show); menu.Items.Add(new Separator());
        Add(capturing ? "녹음 완료" : "새 녹음", record, !busy);
        Add(paused ? "녹음 재개" : "녹음 일시정지", pause, capturing && !busy);
        menu.Items.Add(new Separator()); Add("종료 · 녹음 저장 후 종료", exit);
        SetForegroundWindow(source.Handle);
        menu.Closed += (_, _) => { if (!disposed) ShellNotifyIcon(3, ref data); };
        menu.IsOpen = true; menu.Focus();
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        if (menu is not null) menu.IsOpen = false;
        foreach (int id in registeredKeys) UnregisterHotKey(source.Handle, id);
        registeredKeys.Clear(); ShellNotifyIcon(2, ref data); IsAvailable = false;
        source.RemoveHook(WindowMessage); if (icon != 0) DestroyIcon(icon);
    }
    private static nint CreateWaveformIcon()
    {
        const int side = 32; var colors = new byte[side * side * 4]; var mask = Enumerable.Repeat((byte)255, side * 4).ToArray();
        int[] heights = [8, 16, 23, 12, 19];
        for (int y = 0; y < side; y++) for (int x = 0; x < side; x++)
        {
            if ((x - 15.5) * (x - 15.5) + (y - 15.5) * (y - 15.5) > 225) continue;
            int offset = (y * side + x) * 4;
            bool white = x is >= 8 and <= 24 && (x - 8) % 4 < 2 && Math.Abs(y - 15.5) < heights[Math.Min(4, (x - 8) / 4)] / 2d;
            colors[offset] = white ? (byte)255 : (byte)55; colors[offset + 1] = white ? (byte)255 : (byte)59; colors[offset + 2] = 255; colors[offset + 3] = 255;
            mask[y * 4 + x / 8] &= (byte)~(0x80 >> (x % 8));
        }
        return CreateIcon(0, side, side, 1, 32, mask, colors);
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size; public nint Window; public uint Id, Flags, Callback; public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Guid; public nint BalloonIcon;
    }
    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string message);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll")] private static extern nint CreateIcon(nint instance, int width, int height, byte planes, byte bitsPerPixel, byte[] andMask, byte[] xorMask);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint window);
}
