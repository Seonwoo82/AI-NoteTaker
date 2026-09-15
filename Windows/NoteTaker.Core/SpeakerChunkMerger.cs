namespace NoteTaker.Core;

/// <summary>Joins bounded acoustic windows without reusing their local speaker indices.</summary>
public sealed class SpeakerChunkMerger(double duration)
{
    private sealed class Cluster(string id, float[] embedding, double weight)
    {
        public readonly string Id = id;
        public float[] Embedding = embedding;
        public double Weight = weight;
        public int Revision;
        public bool Active = true;
    }
    private readonly List<Cluster> clusters = [];
    private readonly List<AcousticSegment> segments = [];
    private readonly Dictionary<string, string> aliases = [];
    private readonly HashSet<(string, string)> conflicts = [];
    private double nextStart;
    private bool finished;
    public void Add(SpeakerAudioWindow window, AcousticDiarization local)
    {
        SpeakerAudioWindows.ValidateDuration(duration);
        if (finished || window.KeepStart != nextStart || window.KeepEnd <= window.KeepStart || window.KeepEnd > duration || window.Start < 0 || window.Start > window.KeepStart ||
            local.ModelId != SpeakerModels.EmbeddingModelId || local.Speakers is not { Count: <= 64 } || local.Segments is null ||
            !double.IsFinite(local.Duration) || local.Duration <= 0 || local.Segments.Any(s => !double.IsFinite(s.Start) || !double.IsFinite(s.End) || s.Start < 0 || s.End <= s.Start || s.End > local.Duration) ||
            local.Speakers.Select(s => s.Id).Distinct().Count() != local.Speakers.Count || local.Speakers.Any(s => !SpeakerWorkerClient.ValidEmbedding(s.Embedding)))
            throw new InvalidDataException("화자 분석 구간이 올바르지 않습니다.");
        var clipped = local.Segments.Select(s => s with { Start = Math.Max(window.KeepStart, window.Start + s.Start), End = Math.Min(window.KeepEnd, window.Start + s.End) })
            .Where(s => s.End > s.Start).OrderBy(s => s.Start).ToList();
        if (clipped.Any(s => !double.IsFinite(s.Start) || !double.IsFinite(s.End))) throw new InvalidDataException("화자 구간 시간이 올바르지 않습니다.");
        var visible = local.Speakers.Where(s => clipped.Any(segment => segment.SpeakerId == s.Id)).ToArray();
        var previous = clusters.Select(c => (Cluster: c, Embedding: c.Embedding)).ToArray(); var mapped = new Dictionary<string, string>();
        foreach (var speaker in visible)
        {
            var matches = previous.Select(c => (c.Cluster, c.Embedding, Score: SpeakerWorkerClient.Cosine(speaker.Embedding, c.Embedding))).OrderByDescending(c => c.Score).ToArray();
            Cluster? match = null;
            if (matches.Length > 0 && matches[0].Score >= .75 && (matches.Length == 1 || matches[0].Score - matches[1].Score >= .12))
            {
                var reverse = visible.Select(s => (Speaker: s, Score: SpeakerWorkerClient.Cosine(s.Embedding, matches[0].Embedding))).OrderByDescending(s => s.Score).ToArray();
                if (reverse[0].Speaker.Id == speaker.Id && (reverse.Length == 1 || reverse[0].Score - reverse[1].Score >= .12)) match = matches[0].Cluster;
            }
            double weight = Math.Clamp(clipped.Where(s => s.SpeakerId == speaker.Id).Sum(s => s.End - s.Start), .5, 30);
            if (match is null)
            {
                if (clusters.Count >= 512) throw new InvalidDataException("화자 후보가 너무 많아 긴 회의를 안정적으로 연결하지 못했습니다. 기존 자료는 유지됩니다.");
                match = new("window-speaker-" + clusters.Count, Normalize(speaker.Embedding), weight); clusters.Add(match);
            }
            else Update(match, speaker.Embedding, weight);
            mapped[speaker.Id] = match.Id;
        }
        var current = clipped.Select(s => s with { SpeakerId = mapped.GetValueOrDefault(s.SpeakerId, $"unattributed-{window.KeepStart}-{s.SpeakerId}") }).ToList();
        for (int i = 0; i < current.Count; i++)
            for (int j = i + 1; j < current.Count && current[j].Start < current[i].End - .05; j++)
                if (current[i].SpeakerId != current[j].SpeakerId) conflicts.Add((current[i].SpeakerId, current[j].SpeakerId));
        segments.AddRange(current);
        if (segments.Count > 20000) throw new InvalidDataException("회의의 화자 구간 수가 지원 범위를 초과했습니다.");
        nextStart = window.KeepEnd;
    }
    public AcousticDiarization Finish(int knownCount = 0)
    {
        SpeakerAudioWindows.ValidateDuration(duration);
        if (finished || nextStart != duration || knownCount is < 0 or > 64) throw new InvalidDataException("화자 분석의 전체 구간이 완료되지 않았습니다.");
        finished = true;
        if (knownCount > 0 && clusters.Count > knownCount)
        {
            var queue = new PriorityQueue<(Cluster A, Cluster B, int ARevision, int BRevision), double>();
            void Pair(Cluster a, Cluster b) { if (!Conflicts(a.Id, b.Id)) queue.Enqueue((a, b, a.Revision, b.Revision), -SpeakerWorkerClient.Cosine(a.Embedding, b.Embedding)); }
            for (int i = 0; i < clusters.Count; i++) for (int j = i + 1; j < clusters.Count; j++) Pair(clusters[i], clusters[j]);
            int remaining = clusters.Count;
            while (remaining > knownCount && queue.TryDequeue(out var pair, out _))
            {
                if (!pair.A.Active || !pair.B.Active || pair.A.Revision != pair.ARevision || pair.B.Revision != pair.BRevision || Conflicts(pair.A.Id, pair.B.Id)) continue;
                Update(pair.A, pair.B.Embedding, pair.B.Weight); pair.A.Revision++; pair.B.Active = false; aliases[pair.B.Id] = pair.A.Id; remaining--;
                foreach (var other in clusters.Where(c => c.Active && c != pair.A)) Pair(pair.A, other);
            }
            if (remaining > knownCount) throw new InvalidDataException("동시에 말한 화자를 지정한 인원으로 합칠 수 없습니다. 참여자 수를 늘리거나 자동으로 분석해 주세요.");
        }
        var active = clusters.Where(c => c.Active).ToArray();
        if (active.Length > 64) throw new InvalidDataException("화자 후보가 64명을 넘습니다. 참여자 수를 지정해 다시 분석해 주세요.");
        var joined = segments.Select(s => s with { SpeakerId = Resolve(s.SpeakerId) }).OrderBy(s => s.Start).ThenBy(s => s.End).ToList();
        // Merge only adjacent fragments from the same voice; overlapping speakers keep separate evidence.
        var result = new List<AcousticSegment>();
        foreach (var segment in joined)
        {
            if (result.Count > 0 && result[^1].SpeakerId == segment.SpeakerId && Math.Abs(result[^1].End - segment.Start) < .001)
                result[^1] = result[^1] with { End = segment.End };
            else result.Add(segment);
        }
        return new(SpeakerModels.EmbeddingModelId, duration, result, active.Select(c => new AcousticSpeaker(c.Id, c.Embedding)).ToList());
    }
    private string Resolve(string id) { while (aliases.TryGetValue(id, out var parent)) id = parent; return id; }
    private bool Conflicts(string first, string second) => conflicts.Any(pair => Resolve(pair.Item1) == first && Resolve(pair.Item2) == second || Resolve(pair.Item1) == second && Resolve(pair.Item2) == first);
    private static void Update(Cluster cluster, float[] value, double weight)
    {
        var unit = Normalize(value);
        var combined = cluster.Embedding.Select((v, i) => (float)(v * cluster.Weight + unit[i] * weight)).ToArray();
        cluster.Embedding = SpeakerWorkerClient.ValidEmbedding(combined) ? Normalize(combined) : weight > cluster.Weight ? unit : cluster.Embedding;
        cluster.Weight += weight;
    }
    private static float[] Normalize(float[] value)
    {
        if (!SpeakerWorkerClient.ValidEmbedding(value)) throw new InvalidDataException("화자 특징이 올바르지 않습니다.");
        double norm = Math.Sqrt(value.Sum(v => (double)v * v)); return value.Select(v => (float)(v / norm)).ToArray();
    }
}
