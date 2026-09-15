using NAudio.Wave;
using NoteTaker.Core;

static class BoundaryChecks
{
    public static async Task<int> RunAsync(string sample, string output)
    {
        Directory.CreateDirectory(output);
        string silent = Path.Combine(output, "90-minutes-plus-one-second.wav");
        using (var writer = new WaveFileWriter(silent, new WaveFormat(16000, 16, 1)))
        {
            var buffer = new byte[32000];
            for (int i = 0; i < 5401; i++) writer.Write(buffer, 0, buffer.Length);
        }
        string originalHash = await MeetingNotesService.AudioHashAsync(silent, default);
        var parts = await ClovaAudioExport.ExportAsync(silent, output, new Progress<string>(Console.WriteLine), default);
        var durations = parts.Select(path => { using var wav = new WaveFileReader(path); return wav.TotalTime.TotalSeconds; }).ToArray();
        if (parts.Count != 2 || Math.Abs(durations[0] - 5400) > .01 || Math.Abs(durations[1] - 1) > .01 || parts.Any(p => new FileInfo(p).Length >= 300_000_000)) throw new Exception("Clova boundary check failed.");
        if (originalHash != await MeetingNotesService.AudioHashAsync(silent, default)) throw new Exception("Original changed.");
        string longSpeech = Path.Combine(output, "three-meetings.wav");
        using (var reader = new WaveFileReader(sample))
        using (var writer = new WaveFileWriter(longSpeech, reader.WaveFormat))
        {
            var buffer = new byte[64000];
            for (int i = 0; i < 3; i++) { reader.Position = 0; int read; while ((read = reader.Read(buffer, 0, buffer.Length)) > 0) writer.Write(buffer, 0, read); }
        }
        JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, Parts = parts, Durations = durations, OriginalHash = originalHash, LongSpeech = longSpeech });
        return 0;
    }
}
