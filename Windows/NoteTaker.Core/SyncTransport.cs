using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace NoteTaker.Core;

public sealed record SyncConfiguration
{
    public Uri Endpoint { get; }
    public string Token { get; }
    public SyncConfiguration(string endpoint, string token)
    {
        if (!Uri.TryCreate(endpoint.Trim(), UriKind.Absolute, out var uri) || uri.Scheme != "https" || string.IsNullOrEmpty(uri.Host) || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0 || uri.AbsolutePath != "/")
            throw new InvalidOperationException("동기화 서버는 경로가 없는 https:// 호스트 주소를 입력해 주세요.");
        if (string.IsNullOrWhiteSpace(token) || token.Any(char.IsControl)) throw new InvalidOperationException("동기화 토큰을 입력해 주세요.");
        Endpoint = new Uri(uri.GetLeftPart(UriPartial.Authority) + "/"); Token = token.Trim();
    }
}
public sealed class SyncHttpException(HttpStatusCode status) : IOException($"동기화 서버 응답: {(int)status}. " + (status == HttpStatusCode.Unauthorized ? "서버 주소와 토큰을 확인해 주세요." : status == HttpStatusCode.Conflict ? "서버의 최신 자료를 다시 확인해 주세요." : "잠시 후 다시 시도해 주세요."))
{
    public HttpStatusCode Status { get; } = status;
}
public sealed class SyncTransport : IDisposable
{
    private readonly HttpClient http;
    public SyncTransport(SyncConfiguration configuration, HttpMessageHandler? handler = null)
    {
        http = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { BaseAddress = configuration.Endpoint, Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", configuration.Token);
    }
    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        if (!response.IsSuccessStatusCode) { var status = response.StatusCode; response.Dispose(); throw new SyncHttpException(status); }
        return response;
    }
    private static async Task<byte[]> ReadAsync(HttpResponseMessage response, int limit, string mediaType, CancellationToken token)
    {
        if (response.Content.Headers.ContentType?.MediaType != mediaType || response.Content.Headers.ContentLength is { } size && (size < 0 || size > limit)) throw new InvalidDataException("동기화 응답의 형식 또는 크기가 올바르지 않습니다.");
        using var output = new MemoryStream(); await using var source = await response.Content.ReadAsStreamAsync(token); byte[] buffer = new byte[32768];
        while (true)
        {
            int count = await source.ReadAsync(buffer, token); if (count == 0) break;
            if (output.Length + count > limit) throw new InvalidDataException("동기화 응답이 크기 제한을 초과했습니다."); output.Write(buffer, 0, count);
        }
        if (response.Content.Headers.ContentLength is { } expected && output.Length != expected) throw new InvalidDataException("동기화 응답이 중간에 끊겼습니다.");
        return output.ToArray();
    }
    private async Task<T> JsonAsync<T>(string path, object? body, int uploadLimit, CancellationToken token, int downloadLimit = 8 * 1024 * 1024)
    {
        using var request = new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Put, path);
        if (body is not null) { request.Content = new ByteArrayContent(SyncJson.Encode(body, uploadLimit)); request.Content.Headers.ContentType = new("application/json"); }
        using var response = await SendAsync(request, token); return SyncJson.Decode<T>(await ReadAsync(response, downloadLimit, "application/json", token), downloadLimit);
    }
    private static string Page(string path, string? cursor) => "v1/" + path + (cursor is null ? "" : "?cursor=" + Uri.EscapeDataString(cursor));
    private static string RecordingPath(Guid id, int version, string kind) => $"v1/recordings/{SyncJson.Id(id)}/{kind}/{version}";
    public async Task<SyncHealth> HealthAsync(CancellationToken token)
    {
        var health = await JsonAsync<SyncHealth>("v1/health", null, 0, token, 1024); MeetingValidation.Require(health.Ok && health.SchemaVersion == 1); return health;
    }
    public Task<SyncRecordingsPage> RecordingsAsync(string? cursor, CancellationToken token) => JsonAsync<SyncRecordingsPage>(Page("recordings", cursor), null, 0, token);
    public Task<SyncFoldersPage> FoldersAsync(string? cursor, CancellationToken token) => JsonAsync<SyncFoldersPage>(Page("folders", cursor), null, 0, token);
    public Task<SyncNotesPage> NotesAsync(string? cursor, CancellationToken token) => JsonAsync<SyncNotesPage>(Page("notes", cursor), null, 0, token);
    public Task<SyncIntelligencePage> IntelligenceAsync(string? cursor, CancellationToken token) => JsonAsync<SyncIntelligencePage>(Page("intelligence", cursor), null, 0, token);
    public async Task<SyncRecording> PutRecordingAsync(SyncRecording recording, CancellationToken token)
    {
        recording.Validate(); var result = await JsonAsync<RecordingResponse>($"v1/recordings/{SyncJson.Id(recording.Id)}", recording, SyncJson.MetadataLimit, token, SyncJson.MetadataLimit + 256);
        result.Recording.Validate(); MeetingValidation.Require(result.Recording.Id == recording.Id); return result.Recording;
    }
    public async Task<RecordingCollectionFolder> PutFolderAsync(RecordingCollectionFolder folder, CancellationToken token)
    {
        RecordingFolderStore.Validate(folder);
        var result = await JsonAsync<FolderResponse>($"v1/folders/{SyncJson.Id(folder.Id)}", folder, SyncJson.MetadataLimit, token, SyncJson.MetadataLimit + 256);
        RecordingFolderStore.Validate(result.Folder); MeetingValidation.Require(result.Folder.Id == folder.Id); return result.Folder;
    }
    public async Task<SyncProfileResponse> ProfileAsync(MeetingProfile? upload, CancellationToken token)
    {
        upload?.Validate(); var result = await JsonAsync<SyncProfileResponse>("v1/profile", upload is null ? null : new SyncProfileResponse(upload), SyncJson.MetadataLimit, token, SyncJson.MetadataLimit);
        result.Profile?.Validate(); return result;
    }
    public async Task<SyncSettingsResponse> SettingsAsync(Guid device, SyncSettingsUpload? upload, CancellationToken token)
    {
        upload?.Preferences?.Validate(); var result = await JsonAsync<SyncSettingsResponse>("v1/ai-settings" + (upload is null ? "?deviceID=" + SyncJson.Id(device) : ""), upload, 16 * 1024, token, 16 * 1024);
        result.Preferences?.Validate(); return result;
    }
    public Task<SyncEditsPage> EditsAsync(long after, CancellationToken token) => JsonAsync<SyncEditsPage>($"v1/meeting-edits?after={after}", null, 0, token);
    public async Task<SyncEditEntry> PutEditAsync(MeetingEdit edit, CancellationToken token)
    {
        edit.Validate(); var result = await JsonAsync<EditResponse>($"v1/meeting-edits/{SyncJson.Id(edit.Id)}", edit, 16 * 1024, token, 20 * 1024);
        result.Entry.Edit.Validate(); MeetingValidation.Require(result.Entry.Sequence > 0 && result.Entry.Edit == edit); return result.Entry;
    }
    public async Task UploadAudioAsync(SyncRecording recording, string source, CancellationToken token)
    {
        recording.Validate(); await using var stream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
        if (stream.Length is <= 0 or > SyncJson.AudioLimit) throw new InvalidDataException("동기화 오디오는 95 MiB까지 전송할 수 있습니다.");
        using var request = new HttpRequestMessage(HttpMethod.Put, RecordingPath(recording.Id, recording.AudioVersion, "audio")) { Content = new StreamContent(stream) };
        request.Content.Headers.ContentType = new("audio/mp4"); request.Content.Headers.ContentLength = stream.Length;
        using var response = await SendAsync(request, token);
        var result = SyncJson.Decode<AudioResponse>(await ReadAsync(response, 2048, "application/json", token), 2048);
        MeetingValidation.Require(result.Immutable && result.Key == $"recordings/{SyncJson.Id(recording.Id)}/audio/{recording.AudioVersion}.m4a");
    }
    public async Task DownloadAudioAsync(SyncRecording recording, string destination, CancellationToken token)
    {
        recording.Validate(); using var request = new HttpRequestMessage(HttpMethod.Get, RecordingPath(recording.Id, recording.AudioVersion, "audio"));
        using var response = await SendAsync(request, token);
        if (response.Content.Headers.ContentType?.MediaType != "audio/mp4" || response.Content.Headers.ContentLength is not { } length || length is <= 0 or > SyncJson.AudioLimit) throw new InvalidDataException("서버 오디오의 형식 또는 크기가 올바르지 않습니다.");
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".part"; Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        try
        {
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                await using var input = await response.Content.ReadAsStreamAsync(token); byte[] buffer = new byte[65536]; long received = 0;
                while (true) { int count = await input.ReadAsync(buffer, token); if (count == 0) break; received += count; if (received > length) throw new InvalidDataException("오디오 응답의 길이가 올바르지 않습니다."); await output.WriteAsync(buffer.AsMemory(0, count), token); }
                if (received != length) throw new InvalidDataException("오디오 전송이 중간에 끊겼습니다."); output.Flush(true);
            }
            token.ThrowIfCancellationRequested(); File.Move(temporary, destination, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public async Task<SyncDescriptor> UploadDocumentAsync(Guid recordingId, int version, byte[] bytes, bool intelligence, CancellationToken token)
    {
        int limit = intelligence ? SyncJson.IntelligenceLimit : SyncJson.NotesLimit;
        if (bytes.Length > limit) throw new InvalidDataException("동기화 문서가 서버 크기 제한을 초과했습니다.");
        string kind = intelligence ? "intelligence" : "notes";
        using var request = new HttpRequestMessage(HttpMethod.Put, RecordingPath(recordingId, version, kind)) { Content = new ByteArrayContent(bytes) }; request.Content.Headers.ContentType = new("application/json");
        using var response = await SendAsync(request, token); byte[] responseBytes = await ReadAsync(response, 4096, "application/json", token);
        var descriptor = intelligence ? SyncJson.Decode<IntelligenceResponse>(responseBytes, 4096).Intelligence : SyncJson.Decode<NoteResponse>(responseBytes, 4096).Note;
        descriptor.Validate(limit); MeetingValidation.Require(descriptor.RecordingId == recordingId && descriptor.AudioVersion == version); return descriptor;
    }
    public async Task<byte[]> DownloadDocumentAsync(SyncDescriptor descriptor, bool intelligence, CancellationToken token)
    {
        int limit = intelligence ? SyncJson.IntelligenceLimit : SyncJson.NotesLimit; descriptor.Validate(limit);
        using var request = new HttpRequestMessage(HttpMethod.Get, RecordingPath(descriptor.RecordingId, descriptor.AudioVersion, intelligence ? "intelligence" : "notes") + "/" + descriptor.Revision);
        using var response = await SendAsync(request, token); byte[] bytes = await ReadAsync(response, limit, "application/json", token);
        if (bytes.Length != descriptor.ByteCount || SyncJson.Hash(bytes) != descriptor.Revision) throw new InvalidDataException("받은 문서의 해시가 서버 목록과 일치하지 않습니다."); return bytes;
    }
    public void Dispose() => http.Dispose();
    private sealed record RecordingResponse(SyncRecording Recording);
    private sealed record FolderResponse(RecordingCollectionFolder Folder);
    private sealed record NoteResponse(SyncDescriptor Note);
    private sealed record IntelligenceResponse(SyncDescriptor Intelligence);
    private sealed record EditResponse(SyncEditEntry Entry);
    private sealed record AudioResponse(string Key, bool Immutable);
}
