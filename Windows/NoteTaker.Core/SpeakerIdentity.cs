namespace NoteTaker.Core;

public static class SpeakerIdentity
{
    // Group indices can change when the requested participant count changes. Only a mutual,
    // unambiguous acoustic match may inherit an existing participant's editable identity.
    public static AcousticDiarization Reconcile(AcousticDiarization current, AcousticDiarization? previous)
    {
        var mapped = new Dictionary<string, string>(StringComparer.Ordinal);
        bool compatible = previous?.ModelId == current.ModelId && previous.Speakers is { Count: <= 64 } &&
            previous.Speakers.All(s => s is not null && SpeakerWorkerClient.ValidEmbedding(s.Embedding)) && previous.Speakers.Select(s => s.Id).Distinct().Count() == previous.Speakers.Count;
        foreach (var speaker in current.Speakers)
        {
            string? inherited = null;
            if (compatible && previous!.Speakers.Count > 0)
            {
                var matches = previous.Speakers.Select(old => (Speaker: old, Score: SpeakerWorkerClient.Cosine(speaker.Embedding, old.Embedding))).OrderByDescending(m => m.Score).ToList();
                var best = matches[0];
                var reverse = current.Speakers.Select(other => (Speaker: other, Score: SpeakerWorkerClient.Cosine(other.Embedding, best.Speaker.Embedding))).OrderByDescending(m => m.Score).ToList();
                if (best.Score >= .75 && (matches.Count == 1 || best.Score - matches[1].Score >= .12) &&
                    reverse[0].Speaker.Id == speaker.Id && (reverse.Count == 1 || reverse[0].Score - reverse[1].Score >= .12)) inherited = best.Speaker.Id;
            }
            mapped[speaker.Id] = inherited ?? "speaker-" + Guid.NewGuid().ToString("N");
        }
        return current with
        {
            Speakers = current.Speakers.Select(s => s with { Id = mapped[s.Id] }).ToList(),
            Segments = current.Segments.Select(s => s with { SpeakerId = mapped.GetValueOrDefault(s.SpeakerId, "unattributed-" + s.SpeakerId) }).ToList()
        };
    }
    public static MeetingTranscript PreserveCorrectedTurns(MeetingTranscript current, MeetingTranscript? previous, IReadOnlyList<MeetingEdit> edits)
    {
        if (previous is null || previous.AudioVersion != current.AudioVersion || previous.RecordingId != current.RecordingId) return current;
        var corrected = edits.Where(e => e.AudioVersion == current.AudioVersion && e.Kind == "turnSpeaker").Select(e => e.TargetId).ToHashSet(StringComparer.Ordinal);
        var turns = current.Turns.ToList();
        foreach (var old in previous.Turns.Where(t => corrected.Contains(t.Id)))
        {
            if (turns.Any(t => t.Id == old.Id)) continue;
            var inside = turns.Where(t => t.Start >= old.Start && t.End <= old.End).ToList();
            if (inside.Count == 0 || turns.Any(t => t.Start < old.End && t.End > old.Start && !inside.Contains(t)) ||
                Compact(string.Concat(inside.Select(t => t.Text))) != Compact(old.Text)) continue;
            turns.RemoveAll(t => inside.Contains(t));
            turns.Add(old with { SpeakerId = current.Speakers.Any(s => s.Id == old.SpeakerId) ? old.SpeakerId : null });
        }
        return current with { Turns = turns.OrderBy(t => t.Start).ThenBy(t => t.End).ToList() };
    }
    private static string Compact(string value) => string.Concat(value.Where(c => !char.IsWhiteSpace(c)));
}
