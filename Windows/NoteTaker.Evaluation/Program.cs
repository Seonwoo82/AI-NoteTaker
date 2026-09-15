using System.Diagnostics;
using System.Text.Json;
using NoteTaker.Core;

if (args.Length == 3 && args[0] == "boundary") return await BoundaryChecks.RunAsync(args[1], args[2]);
if (args.Length < 3)
{
    Console.Error.WriteLine("Usage: NoteTaker.Evaluation <audio> <output-directory> <model-root> [whisper|qwen] [cpu] [no-summary]");
    return 2;
}
var output = Path.GetFullPath(args[1]); Directory.CreateDirectory(output);
var settings = new AppSettings { TranscriptionProvider = args.Length > 3 ? args[3] : "whisper", UseGpu = !args.Contains("cpu"), QwenAsrModel = args.Contains("small") ? "0.6b" : "1.7b" };
var library = new LibraryStore(Path.Combine(output, "library"));
var progress = new Progress<string>(Console.WriteLine);
var sample = await library.ImportAsync(Path.GetFullPath(args[0]));
var service = new MeetingNotesService(library, (s, key, p) => AiProviders.Transcriber(Path.GetFullPath(args[2]), s, key, p), AiProviders.Summarizer);
var timer = Stopwatch.StartNew();
using var monitorStop = new CancellationTokenSource();
long peakCombinedWorkingSet = 0; int? peakDeviceMemoryMiB = null;
string toolsPath = Path.GetFullPath(Path.Combine(args[2], "Tools"));
var monitor = Task.Run(async () =>
{
    while (!monitorStop.IsCancellationRequested)
    {
        long memory = Process.GetCurrentProcess().WorkingSet64;
        foreach (var child in Process.GetProcessesByName("llama-server"))
        {
            using (child) { try { if (child.MainModule?.FileName.StartsWith(toolsPath, StringComparison.OrdinalIgnoreCase) == true) memory += child.WorkingSet64; } catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { } }
        }
        peakCombinedWorkingSet = Math.Max(peakCombinedWorkingSet, memory);
        try
        {
            using var gpu = Process.Start(new ProcessStartInfo("nvidia-smi", "--query-gpu=memory.used --format=csv,noheader,nounits") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true });
            if (gpu is not null)
            {
                string value = await gpu.StandardOutput.ReadToEndAsync(monitorStop.Token);
                if (int.TryParse(value.Trim(), out int mb)) peakDeviceMemoryMiB = Math.Max(peakDeviceMemoryMiB ?? 0, mb);
            }
        }
        catch (System.ComponentModel.Win32Exception) { }
        catch (OperationCanceledException) { break; }
        try { await Task.Delay(250, monitorStop.Token); } catch (OperationCanceledException) { break; }
    }
});
using var whisperLogging = Whisper.net.Logger.LogProvider.AddConsoleLogging(Whisper.net.Logger.WhisperLogLevel.Info);
try
{
    bool resumedAfterCancellation = false;
    if (args.Contains("cancel-resume"))
    {
        using var stop = new CancellationTokenSource();
        var cancellationProgress = new CallbackProgress(message => { Console.WriteLine(message); if (message.Contains("· 2 /")) stop.Cancel(); });
        try { await service.TranscribeAsync(sample, settings, "", cancellationProgress, stop.Token); throw new Exception("Cancellation point was not reached."); }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        var partial = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(sample.Id));
        if (partial?.Chunks.Count != 1 || partial.Complete) throw new Exception("First completed chunk was not preserved.");
        JsonDisk.Write(Path.Combine(output, "cancelled-cache.json"), partial);
        resumedAfterCancellation = true;
    }
    var transcript = await service.TranscribeAsync(sample, settings, "", progress, default);
    double transcriptionSeconds = timer.Elapsed.TotalSeconds;
    monitorStop.Cancel(); await monitor;
    Console.WriteLine("TRANSCRIPT: " + string.Join("\n", transcript.Chunks));
    MeetingNotes? notes = null; double? summarySeconds = null;
    if (!args.Contains("no-summary"))
    {
        await LocalRuntime.StartOllamaAsync(Path.GetFullPath(args[2]), settings, default);
        timer.Restart();
        notes = await service.SummarizeAsync(sample, settings, "", progress, default);
        summarySeconds = timer.Elapsed.TotalSeconds;
        Console.WriteLine(notes.Markdown);
    }
    JsonDisk.Write(Path.Combine(output, "result.json"), new
    {
        timestamp = DateTimeOffset.Now, source = Path.GetFullPath(args[0]), audioSeconds = sample.DurationSeconds,
        transcriptionSeconds, realTimeFactor = transcriptionSeconds / sample.DurationSeconds, summarySeconds,
        peakProcessMemoryMb = Process.GetCurrentProcess().PeakWorkingSet64 / 1_000_000,
        asrPeakCombinedWorkingSetMb = peakCombinedWorkingSet / 1_000_000,
        asrPeakWholeDeviceMemoryMiB = peakDeviceMemoryMiB,
        memoryMeasurement = "250 ms samples: evaluation + llama-server under model root. GPU is whole-device usage including other apps; summary excluded.",
        resumedAfterCancellation,
        whisperRuntime = Whisper.net.LibraryLoader.RuntimeOptions.LoadedLibrary?.ToString(),
        settings, transcript, notes, recordingId = sample.Id
    });
    return 0;
}
catch (Exception ex) { File.WriteAllText(Path.Combine(output, "error.txt"), ex.ToString()); Console.Error.WriteLine(ex); return 1; }
finally { monitorStop.Cancel(); await monitor; LocalRuntime.StopOwned(); }

sealed class CallbackProgress(Action<string> callback) : IProgress<string> { public void Report(string value) => callback(value); }
