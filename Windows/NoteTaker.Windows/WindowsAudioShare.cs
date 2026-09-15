using System.Windows;
using System.Windows.Interop;
using System.Runtime.InteropServices;
using global::Windows.ApplicationModel.DataTransfer;
using global::Windows.Storage;
using NoteTaker.Core;

namespace NoteTaker.Windows;

internal sealed class WindowsAudioShare(Window owner) : IDisposable
{
    private DataTransferManager? manager;
    private IDataTransferManagerInterop? interop;
    private DataPackage? prepared;
    internal event Action? DataRequested;

    internal static async Task<DataPackage> PrepareAsync(LibraryStore library, Recording recording, CancellationToken token)
    {
        string copy = await library.CreateAudioShareCopyAsync(recording, token);
        token.ThrowIfCancellationRequested();
        var file = await StorageFile.GetFileFromPathAsync(copy).AsTask(token);
        var data = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
        data.Properties.Title = string.IsNullOrWhiteSpace(recording.Title) ? "녹음" : recording.Title;
        data.Properties.ApplicationName = "AI-NoteTaker";
        data.Properties.FileTypes.Add(".wav");
        data.SetStorageItems(new[] { file });
        return data;
    }

    internal void Show(DataPackage data)
    {
        if (!DataTransferManager.IsSupported()) throw new InvalidOperationException("이 Windows 환경에서는 시스템 공유를 사용할 수 없습니다.");
        nint handle = new WindowInteropHelper(owner).EnsureHandle();
        try
        {
            if (manager is null)
            {
                interop = DataTransferManager.As<IDataTransferManagerInterop>();
                Guid id = new("A5CAEE9B-8708-49D1-8D36-67D25A8DA00C");
                nint pointer = interop.GetForWindow(handle, ref id);
                try { manager = WinRT.MarshalInterface<DataTransferManager>.FromAbi(pointer); }
                finally { Marshal.Release(pointer); }
                manager.DataRequested += SupplyData;
            }
            prepared = data;
            interop!.ShowShareUIForWindow(handle);
        }
        catch (System.Runtime.InteropServices.COMException ex)
        { throw new InvalidOperationException("Windows 오디오 공유 창을 열지 못했습니다.", ex); }
    }
    private void SupplyData(DataTransferManager sender, DataRequestedEventArgs args)
    {
        if (prepared is null) { args.Request.FailWithDisplayText("공유할 녹음을 다시 선택해 주세요."); return; }
        args.Request.Data = prepared;
        DataRequested?.Invoke();
    }
    public void Dispose()
    {
        if (manager is not null) manager.DataRequested -= SupplyData;
        manager = null; prepared = null; interop = null;
    }

    [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDataTransferManagerInterop
    {
        nint GetForWindow(nint window, [In] ref Guid interfaceId);
        void ShowShareUIForWindow(nint window);
    }
}
