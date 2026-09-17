using System.Text.Json;

namespace NoteTaker.Core;

public sealed partial class LibrarySyncEngine
{
    private Guid deviceId;
    private void ObserveAccount()
    {
        deviceId = SyncAccountData.DeviceId(library.Root);
        try
        {
            var settings = SyncAccountData.ReadSettings(library.Root);
            if (settings.SharedSyncPreferences is { } shared) state.Observe("settings", deviceId, Revision(shared));
        }
        catch (Exception ex) when (Recoverable(ex, default)) { }
        try
        {
            var profiles = new MeetingProfileStore(library.Root);
            if (File.Exists(profiles.ProfilePath)) state.Observe("profile", deviceId, Revision(profiles.Load()));
        }
        catch (Exception ex) when (Recoverable(ex, default)) { }
    }
    private async Task SyncProfileAsync(bool force, CancellationToken token)
    {
        const string path = "meeting-profile.json";
        var profiles = new MeetingProfileStore(library.Root); MeetingProfile? local;
        Dictionary<string, string?> expected;
        lock (JsonDisk.Gate)
        {
            expected = SyncFileTransaction.Snapshot(library.Root, [path]); local = expected[path] is null ? null : profiles.Load();
        }
        if (local is not null) state.Observe("profile", deviceId, Revision(local));
        if (!state.Ready("profile", deviceId, force)) return;
        var server = (await transport.ProfileAsync(null, token)).Profile;
        if (local is not null && (server is null || SyncJson.Wins(local.ModifiedAt, local.MutationId, server.ModifiedAt, server.MutationId)))
        {
            server = (await transport.ProfileAsync(local, token)).Profile ?? throw new InvalidDataException("서버 프로필 응답이 비어 있습니다."); uploaded++;
        }
        if (server is null) return;
        if (local is null || SyncJson.Wins(server.ModifiedAt, server.MutationId, local.ModifiedAt, local.MutationId))
        {
            SyncDocumentStore.ApplyFiles(library.Root, expected, new() { [path] = JsonSerializer.SerializeToUtf8Bytes(server, JsonDisk.Options) }, token); downloaded++;
        }
        else if (Revision(server) != Revision(local)) throw new InvalidDataException("같은 수정 ID의 프로필 내용이 서로 다릅니다.");
        state.Acknowledge("profile", deviceId, Revision(server)); state.Observe("profile", deviceId, Revision(profiles.Load()));
    }
    private async Task SyncSettingsAsync(bool force, CancellationToken token)
    {
        const string path = "settings.json";
        AppSettings local; Dictionary<string, string?> expected;
        lock (JsonDisk.Gate) { local = SyncAccountData.ReadSettings(library.Root); expected = SyncFileTransaction.Snapshot(library.Root, [path]); }
        var preferences = local.SharedSyncPreferences;
        if (preferences is not null) state.Observe("settings", deviceId, Revision(preferences));
        if (!state.Ready("settings", deviceId, force)) return;
        var remote = await transport.SettingsAsync(deviceId, null, token); state.SetKeyPresence(remote.OtherDevicesHaveApiKey);
        SyncPreferences? pending = preferences is not null && (remote.Preferences is null || SyncJson.Wins(preferences.ModifiedAt, preferences.MutationId, remote.Preferences.ModifiedAt, remote.Preferences.MutationId)) ? preferences : null;
        var response = await transport.SettingsAsync(deviceId, new(pending, new(deviceId, "Windows", SyncAccountData.KeyPresence(local))), token);
        state.SetKeyPresence(response.OtherDevicesHaveApiKey);
        if (pending is not null) uploaded++;
        if (response.Preferences is not { } winner) return;
        if (preferences is null || SyncJson.Wins(winner.ModifiedAt, winner.MutationId, preferences.ModifiedAt, preferences.MutationId))
        {
            var updated = SyncAccountData.ApplyPreferences(local, winner);
            SyncDocumentStore.ApplyFiles(library.Root, expected, new() { [path] = JsonSerializer.SerializeToUtf8Bytes(updated, JsonDisk.Options) }, token); downloaded++;
        }
        else if (Revision(winner) != Revision(preferences)) throw new InvalidDataException("같은 수정 ID의 AI 설정이 서로 다릅니다.");
        state.Acknowledge("settings", deviceId, Revision(winner));
        if (SyncAccountData.ReadSettings(library.Root).SharedSyncPreferences is { } latest) state.Observe("settings", deviceId, Revision(latest));
    }
}
