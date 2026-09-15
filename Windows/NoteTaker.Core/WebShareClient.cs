using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace NoteTaker.Core;

public sealed record WebSharePublication(string Url, DateTimeOffset ExpiresAt);
public sealed record WebShareStatus(bool Active, DateTimeOffset? ExpiresAt);

public sealed class WebShareClient : IDisposable
{
    private const int MaxMarkdownBytes = 1024 * 1024;
    private const int MaxRequestBytes = MaxMarkdownBytes + 8192;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    private static readonly Regex ShareTokenPath = new("^/s/[A-Za-z0-9_-]{43}$", RegexOptions.CultureInvariant);
    private readonly HttpClient http;
    private readonly Uri origin;

    public WebShareClient(Uri serverUrl, string syncToken, HttpMessageHandler? handler = null)
    {
        if (serverUrl.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("웹 공유 서버 주소는 https:// 로 시작해야 합니다.");
        if (serverUrl.AbsolutePath != "/" || !string.IsNullOrEmpty(serverUrl.UserInfo) || !string.IsNullOrEmpty(serverUrl.Query) || !string.IsNullOrEmpty(serverUrl.Fragment))
            throw new InvalidOperationException("웹 공유 서버 주소에는 호스트만 입력해 주세요. 경로, 사용자 정보, 쿼리 또는 프래그먼트는 사용할 수 없습니다.");
        if (string.IsNullOrWhiteSpace(syncToken))
            throw new InvalidOperationException("웹 공유 동기화 토큰을 설정해 주세요.");
        var baseUrl = serverUrl.AbsoluteUri.EndsWith('/') ? serverUrl : new Uri(serverUrl.AbsoluteUri + "/");
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
        {
            BaseAddress = baseUrl,
            Timeout = TimeSpan.FromSeconds(30)
        };
        origin = new Uri(baseUrl.GetLeftPart(UriPartial.Authority));
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", syncToken.Trim());
    }

    public async Task<WebSharePublication> PublishAsync(Guid sourceId, string title, string markdown, CancellationToken token)
    {
        var payload = ValidatePayload(title, markdown);
        var json = JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions);
        if (json.Length > MaxRequestBytes)
            throw new InvalidOperationException("공유할 회의록 요청이 서버 제한보다 큽니다.");
        using var content = new ByteArrayContent(json);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        using var request = new HttpRequestMessage(HttpMethod.Put, PathFor(sourceId)) { Content = content };
        using var response = await SendAsync(request, token);
        await using var stream = await response.Content.ReadAsStreamAsync(token);
        var body = await JsonSerializer.DeserializeAsync<PublishResponse>(stream, JsonOptions, token)
            ?? throw new InvalidDataException("웹 공유 응답이 비어 있습니다.");
        if (string.IsNullOrWhiteSpace(body.Url) || body.ExpiresAt <= 0 || !IsExpectedShareUrl(body.Url))
            throw new InvalidDataException("웹 공유 응답 형식이 올바르지 않습니다.");
        return new WebSharePublication(body.Url, DateTimeOffset.FromUnixTimeMilliseconds(body.ExpiresAt));
    }

    public async Task<WebShareStatus> GetStatusAsync(Guid sourceId, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, PathFor(sourceId));
        using var response = await SendAsync(request, token);
        await using var stream = await response.Content.ReadAsStreamAsync(token);
        using var body = await JsonDocument.ParseAsync(stream, cancellationToken: token);
        if (!body.RootElement.TryGetProperty("active", out var activeElement) || activeElement.ValueKind is not JsonValueKind.True and not JsonValueKind.False)
            throw new InvalidDataException("웹 공유 상태 응답 형식이 올바르지 않습니다.");
        var active = activeElement.GetBoolean();
        if (!active) return new WebShareStatus(false, null);
        if (!body.RootElement.TryGetProperty("expiresAt", out var expiresElement) || !expiresElement.TryGetInt64(out var expiresAt) || expiresAt <= 0)
            throw new InvalidDataException("웹 공유 상태 응답 형식이 올바르지 않습니다.");
        return new WebShareStatus(true, DateTimeOffset.FromUnixTimeMilliseconds(expiresAt));
    }

    public async Task RevokeAsync(Guid sourceId, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, PathFor(sourceId));
        using var response = await SendAsync(request, token);
        if (response.StatusCode != HttpStatusCode.NoContent)
            throw new InvalidOperationException("웹 공유 중지 응답 형식이 올바르지 않습니다.");
    }

    private static PutRequest ValidatePayload(string title, string markdown)
    {
        var trimmedTitle = title.Trim();
        if (string.IsNullOrWhiteSpace(trimmedTitle))
            throw new InvalidOperationException("공유할 회의록 제목이 비어 있습니다.");
        if (trimmedTitle.EnumerateRunes().Count() > 300)
            throw new InvalidOperationException("공유할 회의록 제목은 300자 이하여야 합니다.");
        if (string.IsNullOrWhiteSpace(markdown))
            throw new InvalidOperationException("공유할 회의록 내용이 비어 있습니다.");
        if (Encoding.UTF8.GetByteCount(markdown) > MaxMarkdownBytes)
            throw new InvalidOperationException("공유할 회의록은 1MiB 이하여야 합니다.");
        return new PutRequest(trimmedTitle, markdown);
    }

    private static string PathFor(Guid sourceId) => "v1/shares/" + sourceId.ToString("D").ToUpperInvariant();

    private bool IsExpectedShareUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var shareUrl)) return false;
        return shareUrl.Scheme == Uri.UriSchemeHttps &&
            string.Equals(shareUrl.GetLeftPart(UriPartial.Authority), origin.GetLeftPart(UriPartial.Authority), StringComparison.OrdinalIgnoreCase) &&
            string.IsNullOrEmpty(shareUrl.UserInfo) &&
            string.IsNullOrEmpty(shareUrl.Query) &&
            string.IsNullOrEmpty(shareUrl.Fragment) &&
            ShareTokenPath.IsMatch(shareUrl.AbsolutePath);
    }

    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        try
        {
            var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            if (response.IsSuccessStatusCode) return response;
            var exception = StatusError(response.StatusCode);
            response.Dispose();
            throw exception;
        }
        catch (TaskCanceledException) when (!token.IsCancellationRequested)
        { throw new TimeoutException("웹 공유 서버 응답 대기 시간이 초과됐습니다."); }
        catch (HttpRequestException)
        { throw new InvalidOperationException("웹 공유 서버에 연결할 수 없습니다. 서버 주소와 인터넷 연결을 확인해 주세요."); }
        catch (JsonException)
        { throw new InvalidDataException("웹 공유 서버 응답을 해석할 수 없습니다."); }
    }

    private static Exception StatusError(HttpStatusCode status) => new InvalidOperationException(status switch
    {
        HttpStatusCode.Unauthorized => "웹 공유 동기화 토큰이 유효하지 않습니다. 설정에서 다시 저장해 주세요.",
        HttpStatusCode.NotFound => "웹 공유 상태를 찾을 수 없습니다.",
        HttpStatusCode.RequestEntityTooLarge => "공유할 회의록이 서버 제한보다 큽니다.",
        HttpStatusCode.TooManyRequests => "웹 공유 요청 한도에 도달했습니다. 잠시 후 다시 시도해 주세요.",
        _ when (int)status is >= 300 and < 400 => "웹 공유 서버의 리디렉션 요청은 따르지 않았습니다.",
        _ => $"웹 공유 요청이 실패했습니다 (HTTP {(int)status}). 설정과 서버 상태를 확인해 주세요."
    });

    public void Dispose() => http.Dispose();

    private sealed record PutRequest(
        [property: JsonPropertyName("title")] string Title,
        [property: JsonPropertyName("markdown")] string Markdown);
    private sealed record PublishResponse(
        [property: JsonPropertyName("url")] string? Url,
        [property: JsonPropertyName("expiresAt")] long ExpiresAt);
}
