using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class AutomaticSyncScheduleTests
{
    [Fact] public void BusyOrDisabledRunsRemainDueAndSuccessfulRunsWaitThirtySeconds()
    {
        var clock = new Clock(); var schedule = new AutomaticSyncSchedule(clock);
        Assert.False(schedule.IsDue(false, false)); Assert.False(schedule.IsDue(true, true));
        Assert.True(schedule.IsDue(true, false)); schedule.Finished(true);
        clock.Advance(29); Assert.False(schedule.IsDue(true, false)); clock.Advance(1); Assert.True(schedule.IsDue(true, false));
    }
    [Fact] public void FailuresBackOffToFiveMinutesAndExplicitResetOrCancelRestoresPolling()
    {
        var clock = new Clock(); var schedule = new AutomaticSyncSchedule(clock);
        foreach (int seconds in new[] { 30, 60, 120, 240, 300, 300 })
        {
            schedule.Finished(false); clock.Advance(seconds - 1); Assert.False(schedule.IsDue(true, false)); clock.Advance(1); Assert.True(schedule.IsDue(true, false));
        }
        schedule.Finished(false); schedule.Reset(); Assert.True(schedule.IsDue(true, false));
        schedule.Finished(false, cancelled: true); clock.Advance(30); Assert.True(schedule.IsDue(true, false));
        schedule.Finished(false); clock.Advance(30); Assert.True(schedule.IsDue(true, false));
    }
    private sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UnixEpoch;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(int seconds) => now = now.AddSeconds(seconds);
    }
}
