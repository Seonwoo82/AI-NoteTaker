"""Score a Whisper evaluation result only inside externally labelled intervals.

No reference text is passed to the recognizer. Labels: start<TAB>end<TAB>speaker<TAB>text.
The report is an observation, not a pass/fail gate or whole-recording accuracy claim.
"""
import argparse
import hashlib
import json
import re
import unicodedata
from pathlib import Path


def normalized(text):
    text = re.sub(r"\[[^\]]+\]", "", text)
    return "".join(c for c in unicodedata.normalize("NFC", text).lower() if c.isalnum())


def distance(first, second):
    previous = list(range(len(second) + 1))
    for i, left in enumerate(first, 1):
        current = [i]
        for j, right in enumerate(second, 1):
            current.append(min(previous[j] + 1, current[-1] + 1, previous[j - 1] + (left != right)))
        previous = current
    return previous[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=Path)
    parser.add_argument("labels", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = json.loads(args.result.read_text(encoding="utf-8-sig"))
    words = [word for segment in result["transcript"]["segments"] for word in segment["words"]]
    rows = []
    for line in args.labels.read_text(encoding="utf-8-sig").splitlines():
        if not line.strip():
            continue
        start, end, speaker, reference = line.split("\t", 3)
        start, end = float(start), float(end)
        hypothesis = "".join(word["text"] for word in words
                             if start <= (word["startSeconds"] + word["endSeconds"]) / 2 < end)
        expected, actual = normalized(reference), normalized(hypothesis)
        if not expected:
            continue
        rows.append(dict(start=start, end=end, speaker=speaker, reference=reference,
                         hypothesis=hypothesis, characters=len(expected), edits=distance(expected, actual)))
    total = sum(row["characters"] for row in rows)
    if not total:
        raise ValueError("No scored reference characters")
    report = dict(
        scope="Only labelled intervals, using predicted token midpoints. Unlabelled speakers/audio are not scored. "
              "Whitespace/punctuation and bracketed annotation tags removed; number words are not rewritten. "
              "Timing errors affect this metric. This is not whole-recording CER, speaker DER, or a meeting benchmark.",
        result_sha256=hashlib.sha256(args.result.read_bytes()).hexdigest(),
        labels_sha256=hashlib.sha256(args.labels.read_bytes()).hexdigest(),
        audio_seconds=result["audioSeconds"], transcription_seconds=result["transcriptionSeconds"],
        reference_speakers=sorted({row["speaker"] for row in rows}), labelled_intervals=len(rows),
        labelled_seconds=sum(row["end"] - row["start"] for row in rows),
        reference_characters=total, edits=sum(row["edits"] for row in rows),
        interval_cer=sum(row["edits"] for row in rows) / total, rows=rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "rows"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
