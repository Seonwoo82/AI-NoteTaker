using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace NoteTaker.Core;

public sealed record ModelAsset(string FileName, string Url, long Bytes, string Sha256);

public static class ModelDownload
{
    public static readonly ModelAsset WhisperTurbo = new("ggml-large-v3-turbo.bin",
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin",
        1624555275, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69");
    public static string PathFor(string root, ModelAsset asset) => Path.Combine(root, "Models", asset.FileName);

    public static async Task VerifyAsync(string path, ModelAsset asset, CancellationToken token)
    {
        if (!File.Exists(path) || new FileInfo(path).Length != asset.Bytes)
            throw new InvalidDataException("모델 파일이 없거나 완성되지 않았습니다. AI 설정에서 모델을 준비해 주세요.");
        await using var file = File.OpenRead(path);
        var hash = Convert.ToHexString(await SHA256.HashDataAsync(file, token));
        if (!hash.Equals(asset.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("모델 파일 검증에 실패했습니다. AI 설정에서 다시 다운로드해 주세요.");
    }

    public static async Task<string> EnsureAsync(string root, ModelAsset asset, IProgress<string> progress, CancellationToken token, HttpMessageHandler? handler = null)
    {
        string path = PathFor(root, asset), partial = path + ".partial";
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (File.Exists(path))
        {
            try { await VerifyAsync(path, asset, token); return path; }
            catch (InvalidDataException) { File.Move(path, path + ".invalid-" + Guid.NewGuid().ToString("N")); }
        }
        using var client = new HttpClient(handler ?? new HttpClientHandler { UseCookies = false }) { Timeout = Timeout.InfiniteTimeSpan };
        long existing = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (existing > asset.Bytes) { File.Move(partial, partial + ".invalid-" + Guid.NewGuid().ToString("N")); existing = 0; }
        if (existing < asset.Bytes)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, asset.Url);
            if (existing > 0) request.Headers.Range = new RangeHeaderValue(existing, null);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            response.EnsureSuccessStatusCode();
            bool append = existing > 0 && response.StatusCode == HttpStatusCode.PartialContent;
            if (append && response.Content.Headers.ContentRange?.From != existing) throw new InvalidDataException("모델 다운로드 재개 위치가 올바르지 않습니다.");
            if (!append) existing = 0;
            await using var source = await response.Content.ReadAsStreamAsync(token);
            await using var destination = new FileStream(partial, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 131072, true);
            var buffer = new byte[131072]; int read; long lastReported = -1;
            while ((read = await source.ReadAsync(buffer, token)) > 0)
            {
                if (existing + read > asset.Bytes) throw new InvalidDataException("모델 다운로드 크기가 예상보다 큽니다.");
                await destination.WriteAsync(buffer.AsMemory(0, read), token); existing += read;
                long percent = existing * 100 / asset.Bytes;
                if (percent != lastReported) { progress.Report($"{asset.FileName} · {percent}% · {existing / 1_000_000} / {asset.Bytes / 1_000_000} MB"); lastReported = percent; }
            }
        }
        progress.Report("모델 무결성 확인 중…");
        try { await VerifyAsync(partial, asset, token); }
        catch (InvalidDataException) when (File.Exists(partial) && new FileInfo(partial).Length == asset.Bytes)
        { File.Move(partial, partial + ".invalid-" + Guid.NewGuid().ToString("N")); throw; }
        token.ThrowIfCancellationRequested(); File.Move(partial, path, overwrite: true); return path;
    }
}
