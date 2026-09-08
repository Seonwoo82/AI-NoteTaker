#!/usr/bin/env python3
"""Prepare a small public two-speaker fixture for FluidAudio validation.

The script intentionally uses only Python stdlib plus macOS `afconvert` so the
fixture can be regenerated without adding project dependencies. It downloads
four fixed LibriSpeech clean/test rows from the Hugging Face datasets server,
checks their stable utterance IDs, decodes them to 16 kHz mono PCM, and writes a
single WAV plus manifest under build/fluidaudio-validation.
"""

from __future__ import annotations

import argparse
import json
import shutil
import struct
import subprocess
import sys
import urllib.parse
import urllib.request
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DATASET = "openslr/librispeech_asr"
CONFIG = "clean"
SPLIT = "test"
SAMPLE_RATE = 16_000
CHANNELS = 1
SAMPLE_WIDTH_BYTES = 2
SILENCE_SECONDS = 0.5
DEFAULT_OUTPUT = Path("build/fluidaudio-validation")
COMBINED_AUDIO = "librispeech_two_speaker_validation.wav"


@dataclass(frozen=True)
class ExpectedRow:
    row_index: int
    source_id: str
    speaker_id: str
    use: str
    transcript: str


EXPECTED_ROWS = [
    ExpectedRow(
        row_index=0,
        source_id="6930-75918-0000",
        speaker_id="speaker_6930",
        use="held_out_validation",
        transcript="CONCORD RETURNED TO ITS PLACE AMIDST THE TENTS",
    ),
    ExpectedRow(
        row_index=1,
        source_id="6930-75918-0001",
        speaker_id="speaker_6930",
        use="enrollment",
        transcript=(
            "THE ENGLISH FORWARDED TO THE FRENCH BASKETS OF FLOWERS OF WHICH THEY HAD MADE "
            "A PLENTIFUL PROVISION TO GREET THE ARRIVAL OF THE YOUNG PRINCESS THE FRENCH "
            "IN RETURN INVITED THE ENGLISH TO A SUPPER WHICH WAS TO BE GIVEN THE NEXT DAY"
        ),
    ),
    ExpectedRow(
        row_index=100,
        source_id="1320-122617-0022",
        speaker_id="speaker_1320",
        use="negative_short",
        transcript="THE DELAWARES ARE CHILDREN OF THE TORTOISE AND THEY OUTSTRIP THE DEER",
    ),
    ExpectedRow(
        row_index=101,
        source_id="1320-122617-0023",
        speaker_id="speaker_1320",
        use="negative_long",
        transcript=(
            "UNCAS WHO HAD ALREADY APPROACHED THE DOOR IN READINESS TO LEAD THE WAY NOW "
            "RECOILED AND PLACED HIMSELF ONCE MORE IN THE BOTTOM OF THE LODGE"
        ),
    ),
]


def rows_url(row_index: int) -> str:
    query = urllib.parse.urlencode(
        {
            "dataset": DATASET,
            "config": CONFIG,
            "split": SPLIT,
            "offset": row_index,
            "length": 1,
        }
    )
    return f"https://datasets-server.huggingface.co/rows?{query}"


def load_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": "AI-NoteTaker speaker fixture"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "AI-NoteTaker speaker fixture"})
    with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as out:
        shutil.copyfileobj(response, out)


def fetch_expected_row(expected: ExpectedRow, source_dir: Path) -> Path:
    payload = load_json(rows_url(expected.row_index))
    rows = payload.get("rows", [])
    if len(rows) != 1:
        raise RuntimeError(f"Expected one dataset row at index {expected.row_index}, got {len(rows)}")

    actual_index = rows[0].get("row_idx")
    row = rows[0].get("row", {})
    actual_id = row.get("id")
    actual_speaker = f"speaker_{row.get('speaker_id')}"
    actual_text = row.get("text")

    if actual_index != expected.row_index:
        raise RuntimeError(f"Dataset row index changed: expected {expected.row_index}, got {actual_index}")
    if actual_id != expected.source_id:
        raise RuntimeError(f"Dataset row ID changed at {expected.row_index}: expected {expected.source_id}, got {actual_id}")
    if actual_speaker != expected.speaker_id:
        raise RuntimeError(
            f"Dataset speaker changed for {expected.source_id}: expected {expected.speaker_id}, got {actual_speaker}"
        )
    if actual_text != expected.transcript:
        raise RuntimeError(f"Dataset transcript changed for {expected.source_id}")

    audio_entries = row.get("audio") or []
    audio_url = next((entry.get("src") for entry in audio_entries if entry.get("src")), None)
    if not audio_url:
        raise RuntimeError(f"No audio URL in dataset row {expected.source_id}")

    destination = source_dir / f"{expected.source_id}.flac"
    download(audio_url, destination)
    return destination


def run_afconvert(source: Path, destination: Path) -> None:
    command = [
        "/usr/bin/afconvert",
        str(source),
        str(destination),
        "-f",
        "WAVE",
        "-d",
        f"LEI16@{SAMPLE_RATE}",
        "-c",
        str(CHANNELS),
    ]
    subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def read_wave_pcm(path: Path) -> tuple[bytes, float]:
    data = path.read_bytes()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise RuntimeError(f"Not a WAVE file: {path}")

    offset = 12
    fmt: dict[str, int] | None = None
    payload: bytes | None = None

    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", data, offset + 4)[0]
        chunk_start = offset + 8
        chunk_end = chunk_start + chunk_size
        chunk = data[chunk_start:chunk_end]

        if chunk_id == b"fmt ":
            if len(chunk) < 16:
                raise RuntimeError(f"Invalid fmt chunk in {path}")
            audio_format, channels, sample_rate, _, _, bits = struct.unpack_from("<HHIIHH", chunk, 0)
            if audio_format not in (1, 0xFFFE):
                raise RuntimeError(f"Unsupported WAVE format {audio_format} in {path}")
            fmt = {"channels": channels, "sample_rate": sample_rate, "bits": bits}
        elif chunk_id == b"data":
            payload = chunk

        offset = chunk_end + (chunk_size % 2)

    if fmt is None or payload is None:
        raise RuntimeError(f"Missing fmt/data chunk in {path}")
    if fmt["channels"] != CHANNELS or fmt["sample_rate"] != SAMPLE_RATE or fmt["bits"] != SAMPLE_WIDTH_BYTES * 8:
        raise RuntimeError(f"Unexpected decoded format in {path}: {fmt}")

    frames = len(payload) // (CHANNELS * SAMPLE_WIDTH_BYTES)
    return payload, frames / SAMPLE_RATE


def write_combined_wave(path: Path, payloads: list[bytes]) -> list[tuple[float, float]]:
    silence = b"\x00" * int(SILENCE_SECONDS * SAMPLE_RATE) * CHANNELS * SAMPLE_WIDTH_BYTES
    ranges: list[tuple[float, float]] = []
    cursor = 0.0

    with wave.open(str(path), "wb") as out:
        out.setnchannels(CHANNELS)
        out.setsampwidth(SAMPLE_WIDTH_BYTES)
        out.setframerate(SAMPLE_RATE)
        for index, payload in enumerate(payloads):
            duration = len(payload) / (SAMPLE_RATE * CHANNELS * SAMPLE_WIDTH_BYTES)
            start = cursor
            end = start + duration
            out.writeframes(payload)
            ranges.append((round(start, 3), round(end, 3)))
            cursor = end
            if index != len(payloads) - 1:
                out.writeframes(silence)
                cursor += SILENCE_SECONDS

    return ranges


def write_readme(output_dir: Path) -> None:
    (output_dir / "README.md").write_text(
        "# FluidAudio validation fixture\n\n"
        "This directory contains a small real-speech fixture for local speaker validation. "
        "It uses four utterances from the LibriSpeech clean test split, concatenated into "
        f"`{COMBINED_AUDIO}` with 0.5 seconds of silence between utterances.\n\n"
        "License: CC BY 4.0, following LibriSpeech/OpenSLR metadata. See `manifest.json` "
        "for source row IDs, transcripts, speaker IDs, and labeled time ranges.\n\n"
        "Recommended use:\n\n"
        "- Enroll on the 14.225 second `speaker_6930` range `6930-75918-0001`, then validate "
        "held-out owner speech on `6930-75918-0000`.\n"
        "- Use both `speaker_1320` ranges as negative examples when enrolled on `speaker_6930`.\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Fixture output directory")
    args = parser.parse_args()

    output_dir = args.output
    source_dir = output_dir / "source"
    decoded_dir = output_dir / "decoded"
    output_dir.mkdir(parents=True, exist_ok=True)
    source_dir.mkdir(parents=True, exist_ok=True)
    decoded_dir.mkdir(parents=True, exist_ok=True)

    source_paths: list[Path] = []
    decoded_paths: list[Path] = []
    payloads: list[bytes] = []

    for expected in EXPECTED_ROWS:
        source_path = fetch_expected_row(expected, source_dir)
        decoded_path = decoded_dir / f"{expected.source_id}.wav"
        run_afconvert(source_path, decoded_path)
        payload, _ = read_wave_pcm(decoded_path)
        source_paths.append(source_path)
        decoded_paths.append(decoded_path)
        payloads.append(payload)

    combined_path = output_dir / COMBINED_AUDIO
    ranges = write_combined_wave(combined_path, payloads)

    segments = []
    for expected, source_path, decoded_path, (start, end) in zip(EXPECTED_ROWS, source_paths, decoded_paths, ranges):
        segments.append(
            {
                "source_row_index": expected.row_index,
                "source_id": expected.source_id,
                "speaker_id": expected.speaker_id,
                "use": expected.use,
                "start": start,
                "end": end,
                "duration": round(end - start, 3),
                "transcript": expected.transcript,
                "source_file": str(source_path.relative_to(output_dir)),
                "decoded_file": str(decoded_path.relative_to(output_dir)),
            }
        )

    with wave.open(str(combined_path), "rb") as wav:
        duration = wav.getnframes() / wav.getframerate()

    manifest = {
        "name": "LibriSpeech two-speaker FluidAudio validation fixture",
        "combined_audio": COMBINED_AUDIO,
        "format": {
            "container": "wav",
            "channels": CHANNELS,
            "sample_width_bytes": SAMPLE_WIDTH_BYTES,
            "sample_rate": SAMPLE_RATE,
        },
        "duration": round(duration, 3),
        "license": "Creative Commons Attribution 4.0 International (CC BY 4.0), per LibriSpeech/OpenSLR metadata",
        "source_dataset": "openslr/librispeech_asr clean test split via Hugging Face datasets server",
        "source_upstream": "LibriSpeech ASR corpus / OpenSLR SLR12",
        "recommended_validation": {
            "speaker_6930_enroll": "Use source_id 6930-75918-0001 as owner enrollment because it is 14.225 seconds and satisfies the production 10 second minimum.",
            "speaker_6930_held_out": "Use source_id 6930-75918-0000 as held-out owner validation speech.",
            "other_speaker_negative": "When enrolled on speaker_6930, both speaker_1320 ranges should classify as other/uncertain, not owner.",
        },
        "segments": segments,
        "attribution": [
            "LibriSpeech: Vassil Panayotov et al., LibriSpeech: an ASR corpus based on public domain audio books, ICASSP 2015.",
            "Audio derived from LibriVox public-domain audiobooks and distributed by OpenSLR/Hugging Face dataset mirror.",
        ],
    }
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    write_readme(output_dir)

    print(f"Wrote {combined_path}")
    print(f"Wrote {output_dir / 'manifest.json'}")
    print(f"Duration: {duration:.3f}s")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(error.stderr or str(error), file=sys.stderr)
        raise SystemExit(error.returncode)
