namespace NoteTaker.Core;

/// <summary>One native share request. A returned Show call is not a data request or delivery receipt.</summary>
public sealed class AudioShareRequest : IDisposable
{
    private readonly object gate = new();
    private readonly TaskCompletionSource confirmation = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly CancellationTokenSource cancellation;
    private readonly CancellationTokenRegistration registration;
    private bool accepting = true;
    private bool disposed;
    private bool timedOut;
    public Task Completion { get; }

    public AudioShareRequest(TimeSpan timeout, CancellationToken token = default)
    {
        if (timeout <= TimeSpan.Zero || timeout > TimeSpan.FromMinutes(1)) throw new ArgumentOutOfRangeException(nameof(timeout));
        cancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
        registration = cancellation.Token.Register(() =>
        {
            lock (gate)
            {
                if (!accepting) return;
                accepting = false;
                timedOut = !token.IsCancellationRequested && !disposed;
                confirmation.TrySetCanceled(cancellation.Token);
            }
        });
        Completion = ObserveAsync();
        cancellation.CancelAfter(timeout);
    }

    public bool TrySupply(Action supply)
    {
        ArgumentNullException.ThrowIfNull(supply);
        lock (gate)
        {
            // Invalidation also prevents a delayed callback from supplying an old recording during a retry.
            if (!accepting || cancellation.IsCancellationRequested) return false;
            accepting = false;
            try { supply(); confirmation.TrySetResult(); }
            catch (Exception ex) { confirmation.TrySetException(ex); }
            return true;
        }
    }

    private async Task ObserveAsync()
    {
        try { await confirmation.Task.ConfigureAwait(false); }
        catch (OperationCanceledException) when (timedOut)
        { throw new TimeoutException("Windows 공유 요청에 대한 응답이 없습니다."); }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true; accepting = false;
            confirmation.TrySetCanceled();
        }
        registration.Dispose(); cancellation.Dispose();
    }
}
