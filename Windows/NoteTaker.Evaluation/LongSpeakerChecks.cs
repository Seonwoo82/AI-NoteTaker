using System.Diagnostics;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using NoteTaker.Core;

internal static class LongSpeakerChecks
{
    public static async Task<int> RunAsync(string sample, string output, string modelRoot, int knownCount = 0)
    {
        Directory.CreateDirectory(output); await SpeakerModels.VerifyAsync(modelRoot, default);
        string fixture = Path.Combine(output, "six-hours.wav");
        var speech = ReadSample(sample); int[] placements = [0, 290, 14400, 21520];
        if (speech.Length > 80 * 16000) throw new InvalidDataException("Use the public four-speaker sample, shorter than 80 seconds.");
        using (var writer = new WaveFileWriter(fixture, new WaveFormat(16000, 16, 1)))
        {
            var silence = new byte[16000 * 2]; int placement = 0;
            for (int second = 0; second < SpeakerAudioWindows.MaximumSeconds;)
            {
                if (placement < placements.Length && second == placements[placement])
                {
                    byte[] bytes = speech.SelectMany(value => BitConverter.GetBytes((short)(Math.Clamp(value, -1, 1) * short.MaxValue))).ToArray();
                    writer.Write(bytes); int paddedSeconds = (int)Math.Ceiling(speech.Length / 16000d);
                    writer.Write(new byte[paddedSeconds * 32000 - bytes.Length]); second += paddedSeconds; placement++;
                }
                else { writer.Write(silence); second++; }
            }
        }
        string originalHash = await MeetingNotesService.AudioHashAsync(fixture, default);
        var client = new SpeakerWorkerClient(modelRoot, knownSpeakerCount: knownCount);
        var baseline = await client.DiarizeAsync(sample, new Progress<string>(_ => { }), default);
        var timer = Stopwatch.StartNew(); long peakWorkingSet = 0;
        using var monitorStop = new CancellationTokenSource();
        string workerPath = Path.Combine(AppContext.BaseDirectory, "SpeechWorker", "AI-NoteTaker.SpeechWorker.exe");
        var monitor = Task.Run(async () =>
        {
            while (!monitorStop.IsCancellationRequested)
            {
                foreach (var child in Process.GetProcessesByName("AI-NoteTaker.SpeechWorker"))
                {
                    using (child) { try { if (string.Equals(child.MainModule?.FileName, workerPath, StringComparison.OrdinalIgnoreCase)) peakWorkingSet = Math.Max(peakWorkingSet, child.WorkingSet64); } catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { } }
                }
                try { await Task.Delay(50, monitorStop.Token); } catch (OperationCanceledException) { break; }
            }
        });
        AcousticDiarization result;
        try { result = await client.DiarizeAsync(fixture, new Progress<string>(message => { if (message.StartsWith("긴 회의 화자 분석")) Console.WriteLine(message); }), default); }
        finally { monitorStop.Cancel(); await monitor; }
        var checks = new List<object>(); bool stable = true;
        foreach (var speaker in baseline.Speakers)
        {
            var reference = baseline.Segments.Where(s => s.SpeakerId == speaker.Id).MaxBy(s => s.End - s.Start)!;
            double center = (reference.Start + reference.End) / 2;
            var identities = placements.Select(start => result.Segments.Where(s => s.Start <= start + center && s.End > start + center).Select(s => s.SpeakerId).Distinct().SingleOrDefault()).ToArray();
            bool same = identities.All(id => id is not null && id == identities[0]); stable &= same;
            checks.Add(new { ReferenceSpeaker = speaker.Id, ReferenceTime = center, Identities = identities, Stable = same });
        }
        bool unchanged = originalHash == await MeetingNotesService.AudioHashAsync(fixture, default);
        bool cancelled = false; using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(1));
        try { await client.DiarizeAsync(fixture, new Progress<string>(_ => { }), cancel.Token); } catch (OperationCanceledException) { cancelled = true; }
        bool passed = result.Duration == 21600 && result.Speakers.Count == 4 && stable && unchanged && cancelled && peakWorkingSet is > 0 and < 1536L * 1024 * 1024;
        JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = passed, KnownCount = knownCount, Duration = result.Duration, Speakers = result.Speakers.Count,
            PeakWorkingSetMiB = peakWorkingSet / 1048576d, ElapsedSeconds = timer.Elapsed.TotalSeconds, Checks = checks, OriginalUnchanged = unchanged, Cancellation = cancelled,
            Scope = "Actual Sherpa worker over a six-hour PCM file. Four copies of the public Chinese four-speaker sample at 0, 290, 14400 and 21520 seconds; remaining audio is digital silence. This is duration, window-boundary, identity, memory and cancellation evidence, not a six-hour natural meeting accuracy benchmark." });
        JsonDisk.Write(Path.Combine(output, "diarization.json"), result);
        Console.WriteLine($"Long audio passed={passed}; speakers={result.Speakers.Count}; stable={stable}; peak={peakWorkingSet / 1048576d:F1} MiB.");
        return passed ? 0 : 1;
    }
    private static float[] ReadSample(string source)
    {
        using var reader = new AudioFileReader(source); ISampleProvider samples = reader;
        if (samples.WaveFormat.Channels == 2) samples = new StereoToMonoSampleProvider(samples);
        if (samples.WaveFormat.SampleRate != 16000) samples = new WdlResamplingSampleProvider(samples, 16000);
        var result = new List<float>(); var buffer = new float[16000]; int count;
        while ((count = samples.Read(buffer, 0, buffer.Length)) > 0) result.AddRange(buffer.AsSpan(0, count));
        return result.ToArray();
    }
}
