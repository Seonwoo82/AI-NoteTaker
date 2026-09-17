namespace NoteTaker.Core;

public static class TranscriptTiming
{
    public static TranscriptSegment Offset(TranscriptSegment segment, double offset) => segment with
    { StartSeconds = segment.StartSeconds + offset, EndSeconds = segment.EndSeconds + offset,
        Words = segment.Words.Select(w => w with { StartSeconds = w.StartSeconds + offset, EndSeconds = w.EndSeconds + offset }).ToList() };
    public static List<TranscriptWord> AttachText(string text, IReadOnlyList<TranscriptWord> words)
    {
        var result = new List<TranscriptWord>(); int offset = 0;
        foreach (var word in words)
        {
            string value = word.Text.Trim(); if (value.Length == 0) continue;
            int index = text.IndexOf(value, offset, StringComparison.Ordinal);
            if (index < 0 || !text[offset..index].All(c => char.IsWhiteSpace(c) || char.IsPunctuation(c))) return [];
            int end = index + value.Length;
            result.Add(word with { Text = text[offset..end] }); offset = end;
        }
        if (result.Count == 0 || !text[offset..].All(c => char.IsWhiteSpace(c) || char.IsPunctuation(c))) return [];
        result[^1] = result[^1] with { Text = result[^1].Text + text[offset..] }; return result;
    }
    public static void Validate(TranscribedAudio audio, double duration)
    {
        MeetingValidation.Require(audio.Text is not null && audio.Text.Length <= 1_000_000 && audio.Segments is { Count: <= 20000 });
        double previous = 0;
        foreach (var segment in audio.Segments)
        {
            MeetingValidation.Require(segment is not null && segment.Text is not null && segment.Words is { Count: <= 100000 });
            Range(segment!.StartSeconds, segment.EndSeconds, previous, duration, false); previous = segment.StartSeconds;
            ValidateWords(segment.Words, duration);
            if (segment.Words.Count > 0) MeetingValidation.Require(string.Concat(segment.Words.Select(w => w.Text)) == segment.Text);
        }
    }
    public static void ValidateWords(IReadOnlyList<TranscriptWord> words, double duration)
    {
        double previous = 0; MeetingValidation.Require(words.Count <= 100000);
        foreach (var word in words)
        {
            MeetingValidation.Require(word is not null && word.Text is not null);
            Range(word!.StartSeconds, word.EndSeconds, previous, duration, true); previous = word.StartSeconds;
        }
    }
    private static void Range(double start, double end, double previous, double duration, bool point) => MeetingValidation.Require(
        double.IsFinite(start) && double.IsFinite(end) && start >= previous && start >= 0 && (point ? end >= start : end > start) && start <= duration && end <= duration + 1);
}
