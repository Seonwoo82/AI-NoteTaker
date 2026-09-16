using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class AudioShareRequestTests
{
    [Fact] public async Task ShowWithoutDataRequestCannotSucceedAndTimedOutCallbackCannotSupplyAudio()
    {
        using var request = new AudioShareRequest(TimeSpan.FromMilliseconds(80));
        Assert.False(request.Completion.IsCompleted);
        await Assert.ThrowsAsync<TimeoutException>(() => request.Completion.WaitAsync(TimeSpan.FromSeconds(5)));
        bool supplied = false;
        Assert.False(request.TrySupply(() => supplied = true)); Assert.False(supplied);
    }

    [Fact] public async Task CancellationRetiresOldRecordingWhileRetryHasItsOwnPayload()
    {
        using var cancel = new CancellationTokenSource();
        using var oldRequest = new AudioShareRequest(TimeSpan.FromSeconds(5), cancel.Token);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => oldRequest.Completion);
        using var retry = new AudioShareRequest(TimeSpan.FromSeconds(5));
        string? supplied = null;
        Assert.False(oldRequest.TrySupply(() => supplied = "old recording"));
        Assert.True(retry.TrySupply(() => supplied = "new recording"));
        await retry.Completion; Assert.Equal("new recording", supplied);
    }

    [Fact] public async Task CallbackFailureReachesAwaiterWithoutEscapingNativeCallback()
    {
        using var request = new AudioShareRequest(TimeSpan.FromSeconds(5));
        var failure = new System.Runtime.InteropServices.COMException("fixture payload failure");
        Assert.True(request.TrySupply(() => throw failure));
        Assert.Same(failure, await Assert.ThrowsAsync<System.Runtime.InteropServices.COMException>(() => request.Completion));
        Assert.False(request.TrySupply(() => throw new InvalidOperationException("Duplicate callback executed")));
    }

    [Fact] public async Task DisposalCancelsPendingRequestAndRejectsQueuedCallback()
    {
        using var request = new AudioShareRequest(TimeSpan.FromSeconds(5));
        request.Dispose(); request.Dispose();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => request.Completion);
        Assert.False(request.TrySupply(() => throw new InvalidOperationException("Disposed callback executed")));
    }

    [Fact] public async Task DuplicateCallbacksSupplyAudioOnceAndDisposalPreservesConfirmedResult()
    {
        using var request = new AudioShareRequest(TimeSpan.FromSeconds(5));
        int supplies = 0;
        var accepted = await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => Task.Run(() => request.TrySupply(() => Interlocked.Increment(ref supplies)))));
        await request.Completion;
        request.Dispose();
        Assert.Single(accepted, x => x); Assert.Equal(1, supplies); Assert.True(request.Completion.IsCompletedSuccessfully);
    }

    [Fact] public async Task AlreadyCancelledRequestNeverSuppliesAudio()
    {
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        using var request = new AudioShareRequest(TimeSpan.FromSeconds(5), cancel.Token);
        Assert.False(request.TrySupply(() => throw new InvalidOperationException("Cancelled callback executed")));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => request.Completion);
    }
}
