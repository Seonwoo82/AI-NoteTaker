namespace NoteTaker.Core;

/// <summary>UI-owned polling clock. Busy app work defers a due run without creating another loop.</summary>
public sealed class AutomaticSyncSchedule(TimeProvider? clock = null)
{
    private readonly TimeProvider clock = clock ?? TimeProvider.System;
    private DateTimeOffset next = DateTimeOffset.MinValue;
    private int retrySeconds = 30;
    public bool IsDue(bool enabled, bool busy) => enabled && !busy && clock.GetUtcNow() >= next;
    public void Reset() { retrySeconds = 30; next = DateTimeOffset.MinValue; }
    public void Finished(bool success, bool cancelled = false)
    {
        int delay = success || cancelled ? 30 : retrySeconds;
        retrySeconds = success || cancelled ? 30 : Math.Min(300, retrySeconds * 2);
        next = clock.GetUtcNow().AddSeconds(delay);
    }
}
