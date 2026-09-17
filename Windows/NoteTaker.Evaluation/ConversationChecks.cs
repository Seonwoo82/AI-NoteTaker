using System.Diagnostics;
using System.Text.Json;
using NoteTaker.Core;

internal static class ConversationChecks
{
    // Reuse measured ASR/acoustic outputs. External reference labels never enter a model prompt.
    public static async Task<int> RunAsync(string asrResult, string acousticResult, string output, string modelRoot, string model)
    {
        Directory.CreateDirectory(output);
        using var asr = JsonDocument.Parse(File.ReadAllText(asrResult));
        using var acoustic = JsonDocument.Parse(File.ReadAllText(acousticResult));
        var id = asr.RootElement.GetProperty("recordingId").GetGuid();
        var originalLibrary = new LibraryStore(Path.Combine(Path.GetDirectoryName(asrResult)!, "library"));
        var recording = originalLibrary.Load().Single(r => r.Id == id);
        var library = new LibraryStore(Path.Combine(output, "library-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(library.DirectoryFor(id)); library.Save(recording);
        File.Copy(originalLibrary.AudioPath(id), library.AudioPath(id));
        File.Copy(originalLibrary.TranscriptPath(id), library.TranscriptPath(id));
        var transcript = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(id))!;
        var diarization = acoustic.RootElement.GetProperty("result").Deserialize<AcousticDiarization>(JsonDisk.Options)!;
        string audioHash = await MeetingNotesService.AudioHashAsync(library.AudioPath(id), default);
        if (transcript.AudioHash != audioHash || !transcript.Complete || Math.Abs(diarization.Duration - recording.DurationSeconds) > .01)
            throw new InvalidDataException("Measured sources do not match.");
        var assembled = MeetingTranscriptAssembler.Assemble(id, recording.AudioVersion, transcript.Model, recording.DurationSeconds, transcript.Segments, diarization);
        var workspace = new MeetingWorkspaceStore(library);
        workspace.Save(recording, new(id, recording.AudioVersion, 0, Guid.NewGuid(), "", assembled, null, [], "sherpa-onnx"), null);
        string originalText = File.ReadAllText(library.TranscriptPath(id));
        var settings = new AppSettings { LocalSummaryModel = model };
        var progress = new Progress<string>(Console.WriteLine);
        await LocalRuntime.StartOllamaAsync(modelRoot, settings, default);
        try
        {
            var timer = Stopwatch.StartNew();
            var notes = await new MeetingNotesService(library).SummarizeAsync(recording, settings, "", progress, default);
            double summarySeconds = timer.Elapsed.TotalSeconds; timer.Restart();
            var document = await new MeetingAnalysisService(library).AnalyzeAsync(recording, settings, "", progress, default);
            if (audioHash != await MeetingNotesService.AudioHashAsync(library.AudioPath(id), default) || originalText != File.ReadAllText(library.TranscriptPath(id)))
                throw new InvalidDataException("Analysis changed its original source.");
            JsonDisk.Write(Path.Combine(output, "analysis.json"), document);
            JsonDisk.Write(Path.Combine(output, "notes.json"), notes);
            JsonDisk.Write(Path.Combine(output, "result.json"), new
            {
                PipelineCompleted = true, Model = model, recording.DurationSeconds, summarySeconds,
                AnalysisSeconds = timer.Elapsed.TotalSeconds, Turns = assembled.Turns.Count,
                Speakers = assembled.Speakers.Count, UnknownTurns = assembled.Turns.Count(t => t.SpeakerId is null),
                Actions = document.Insights!.Actions.Count, Questions = document.Insights.Questions.Count,
                Decisions = document.Insights.Decisions.Count, notes.CleanupNotice, SourceUnchanged = true,
                Scope = "Natural Korean public dialogue, previously measured Whisper and Sherpa results. No gold speaker/semantic accuracy assertion; inspect saved outputs. Reference labels were not supplied to models. No microphone capture or cloud AI."
            });
            return 0;
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(output, "error.txt"), ex.ToString()); Console.Error.WriteLine(ex.Message); return 1; }
        finally { LocalRuntime.StopOwned(); }
    }
}
