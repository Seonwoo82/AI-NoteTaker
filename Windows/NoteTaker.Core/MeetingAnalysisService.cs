namespace NoteTaker.Core;

public sealed class MeetingAnalysisService(LibraryStore library, Func<AppSettings, string, ISummarizer>? factory = null)
{
    public async Task<MeetingIntelligenceDocument> AnalyzeAsync(Recording recording, AppSettings settings, string key, IProgress<string> progress, CancellationToken token)
    {
        if (recording.DeletedAt is not null || recording.IsRecording) throw new InvalidOperationException("저장된 녹음을 선택해 주세요.");
        var store = new MeetingWorkspaceStore(library); var snapshot = store.Snapshot(recording);
        var source = snapshot.Document ?? throw new InvalidOperationException("참여자 분석을 먼저 실행해 주세요.");
        var resolved = ResolvedMeeting.Resolve(source, snapshot.Edits, recording.DurationSeconds);
        string audioHash = await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token);
        string transcriptPath = library.TranscriptPath(recording.Id);
        string? TranscriptRevision() => File.Exists(transcriptPath) ? Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(transcriptPath))) : null;
        string? transcriptRevision = TranscriptRevision();
        if (transcriptRevision is not null && JsonDisk.Read<TranscriptCache>(transcriptPath)?.AudioHash != audioHash)
            throw new InvalidOperationException("전사문과 현재 녹음이 다릅니다. 참여자 분석을 다시 실행해 주세요.");
        var profiles = new MeetingProfileStore(library.Root); string profile = profiles.Load().PromptContext;
        using var model = (factory ?? AiProviders.Summarizer)(settings, key);
        var chunks = MeetingAnalysisPrompt.Partition(resolved.Transcript, profile, model.MaximumInputBytes);
        string[] categories = settings.SummaryProvider == "ollama" && model is IStructuredSummarizer ? ["actions", "questions", "decisions"] : ["all"];
        if (chunks.Count * categories.Length > 80) throw new InvalidOperationException("회의 분석이 80회 호출 범위를 넘습니다. 입력 범위가 더 큰 모델을 선택해 주세요.");
        MeetingInsights insights = new([], [], []);
        for (int index = 0; index < chunks.Count; index++)
        {
            foreach (string category in categories)
            {
                token.ThrowIfCancellationRequested(); progress.Report($"회의 분석 중 · {index * categories.Length + Array.IndexOf(categories, category) + 1}/{chunks.Count * categories.Length} · {model.Model}");
                string prompt = MeetingAnalysisPrompt.User(chunks[index], profile);
                string system = MeetingAnalysisPrompt.ForCategory(category);
                var response = model is IStructuredSummarizer structured
                    ? await structured.CompleteStructuredAsync(system, prompt, MeetingAnalysisPrompt.JsonSchema(chunks[index], category), token)
                    : await model.CompleteAsync(system, prompt, token);
                var partial = MeetingAnalysisPrompt.Decode(response.Text, chunks[index]);
                insights = MeetingAnalysisPrompt.Merge(insights, MeetingAnalysisPrompt.Canonicalize(partial));
                insights.Validate(resolved.Transcript);
            }
        }
        token.ThrowIfCancellationRequested();
        if (audioHash != await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token)) throw new InvalidOperationException("분석 중 녹음이 변경되었습니다. 다시 실행해 주세요.");
        var current = JsonDisk.Read<Recording>(Path.Combine(library.DirectoryFor(recording.Id), "meta.json"));
        if (current is null || current.AudioVersion != recording.AudioVersion || current.DeletedAt is not null || current.IsRecording || current.DurationSeconds != recording.DurationSeconds)
            throw new InvalidOperationException("분석 중 녹음 정보가 변경되었습니다. 다시 실행해 주세요.");
        if (profiles.Load().PromptContext != profile) throw new InvalidOperationException("분석 중 프로필이 변경되었습니다. 다시 실행해 주세요.");
        if (TranscriptRevision() != transcriptRevision) throw new InvalidOperationException("분석 중 전사문이 변경되었습니다. 다시 실행해 주세요.");
        // Keep the original transcript and its edit history. The virtual owner is the only new manual target.
        var transcript = source.Transcript with { Speakers = source.Transcript.Speakers.Concat(resolved.Transcript.Speakers.Where(s => !source.Transcript.Speakers.Any(original => original.Id == s.Id))).ToList() };
        var actionIds = insights.Actions.Select(a => a.Id).ToHashSet(StringComparer.Ordinal);
        var document = source with { Transcript = transcript, Insights = insights, AnalysisModelId = model.Model,
            ActionStates = source.ActionStates.Where(pair => actionIds.Contains(pair.Key)).ToDictionary() };
        token.ThrowIfCancellationRequested();
        store.Save(recording, document, snapshot.Revision, snapshot.EditsRevision);
        return store.Load(recording)!;
    }
}
