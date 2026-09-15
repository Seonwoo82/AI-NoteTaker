using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;
using NoteTaker.Core;

internal static class ModelPreparationChecks
{
    public static async Task<int> RunAsync(string output, string root, string model)
    {
        if (model is not ("qwen3.5:4b" or "qwen3.5:9b")) throw new ArgumentException("Choose qwen3.5:4b or qwen3.5:9b.");
        Directory.CreateDirectory(output);
        var settings = new AppSettings { LocalSummaryModel = model, OllamaAddress = "http://127.0.0.1:11436" };
        var timer = Stopwatch.StartNew();
        string? last = null;
        var progress = new Progress<string>(message => { if (message != last) { last = message; Console.WriteLine(message); } });
        try
        {
            if (await LocalRuntime.IsOllamaRunningAsync(settings, default)) throw new InvalidOperationException("Evaluation port 11436 is already in use; leave that server intact.");
            await LocalRuntime.PrepareOllamaAsync(root, settings, progress, default);
            using var http = new HttpClient { BaseAddress = new(settings.OllamaAddress), Timeout = TimeSpan.FromMinutes(1) };
            using var response = await http.PostAsJsonAsync("/api/show", new { model }); response.EnsureSuccessStatusCode();
            using var details = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            string manifest = Path.Combine(root, "Models", "Ollama", "manifests", "registry.ollama.ai", "library", "qwen3.5", model.Split(':')[1]);
            if (!File.Exists(manifest)) throw new IOException("The selected model was not installed into the requested model root.");
            JsonDisk.Write(Path.Combine(output, "result.json"), new { Prepared = true, Model = model, Seconds = timer.Elapsed.TotalSeconds,
                ManifestHash = SyncFileTransaction.Revision(manifest), ModelDetails = details.RootElement.GetProperty("details").Clone(),
                Scope = "Production model preparation on an isolated loopback Ollama port. Publisher model downloaded; no audio, microphone, user settings, or cloud inference." });
            return 0;
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(output, "error.txt"), ex.ToString()); Console.Error.WriteLine(ex.Message); return 1; }
        finally { LocalRuntime.StopOwned(); }
    }
}
