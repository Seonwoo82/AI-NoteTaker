using System.Windows;
using System.Windows.Interop;
using global::Windows.ApplicationModel.DataTransfer;
using global::Windows.Foundation;
using global::Windows.Storage;
using NoteTaker.Core;

namespace NoteTaker.Windows;

internal sealed class WindowsAudioShare(Window owner) : IDisposable
{
    private AudioShareRequest? activeRequest;
    private bool disposed;

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

    internal async Task ShowAsync(DataPackage data, CancellationToken token = default)
    {
        owner.Dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        token.ThrowIfCancellationRequested();
        if (activeRequest is not null) throw new InvalidOperationException("Windows 공유 요청을 처리하고 있습니다.");
        if (!DataTransferManager.IsSupported()) throw new InvalidOperationException("이 Windows 환경에서는 시스템 공유를 사용할 수 없습니다.");
        nint handle = new WindowInteropHelper(owner).EnsureHandle();
        var manager = DataTransferManagerInterop.GetForWindow(handle);
        using var request = new AudioShareRequest(TimeSpan.FromSeconds(15), token);
        TypedEventHandler<DataTransferManager, DataRequestedEventArgs> supply = (_, args) =>
        {
            if (request.TrySupply(() => args.Request.Data = data)) return;
            // WinRT callbacks must not leak exceptions after cancellation or owner shutdown.
            try { args.Request.FailWithDisplayText("공유 요청이 끝났습니다. 녹음을 다시 선택해 주세요."); }
            catch (System.Runtime.InteropServices.COMException) { }
        };
        activeRequest = request;
        try
        {
            manager.DataRequested += supply;
            token.ThrowIfCancellationRequested();
            DataTransferManagerInterop.ShowShareUIForWindow(handle);
            await request.Completion;
        }
        catch (System.Runtime.InteropServices.COMException ex)
        { throw new InvalidOperationException("Windows 오디오 공유 창을 열지 못했습니다.", ex); }
        catch (TimeoutException ex)
        { throw new InvalidOperationException("Windows 공유 창이 응답하지 않습니다. 다시 시도하거나 ‘오디오 내보내기’를 이용해 주세요.", ex); }
        finally
        {
            // Retire this attempt before unregistering; a queued callback retains only its own request/data.
            request.Dispose();
            activeRequest = null;
            manager.DataRequested -= supply;
        }
    }
    public void Dispose()
    {
        owner.Dispatcher.VerifyAccess();
        disposed = true; activeRequest?.Dispose();
    }
}
