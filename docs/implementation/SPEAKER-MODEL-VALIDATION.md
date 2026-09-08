# Speaker model validation

This project keeps real-speaker FluidAudio checks opt-in because they require local Core ML diarizer models. The fixture data is public LibriSpeech speech, contains no user voice, and is regenerated under ignored `build/fluidaudio-validation` output.

## Prepare the fixture

Run:

```sh
python3 scripts/prepare-speaker-validation.py
```

The script uses only Python stdlib and macOS `/usr/bin/afconvert`. It downloads four fixed rows from the `openslr/librispeech_asr` `clean/test` split through the Hugging Face datasets server, verifies that each row still has the expected ID/transcript/speaker, decodes to 16 kHz mono PCM, and writes:

- `build/fluidaudio-validation/librispeech_two_speaker_validation.wav`
- `build/fluidaudio-validation/manifest.json`
- `build/fluidaudio-validation/source/*.flac`
- `build/fluidaudio-validation/decoded/*.wav`

Source and license:

- LibriSpeech/OpenSLR SLR12: <https://www.openslr.org/12>
- Hugging Face dataset mirror: <https://huggingface.co/datasets/openslr/librispeech_asr>
- Fixture license: Creative Commons Attribution 4.0 International (CC BY 4.0), following LibriSpeech/OpenSLR metadata.

## Labeled ranges

The combined fixture is `30.900` seconds, mono, 16 kHz, 16-bit PCM WAV, with `0.5` seconds of silence between utterances.

| Speaker | Use | Source ID | Start | End |
| --- | --- | --- | ---: | ---: |
| `speaker_6930` | held-out owner validation | `6930-75918-0000` | `0.000` | `3.505` |
| `speaker_6930` | owner enrollment | `6930-75918-0001` | `4.005` | `18.230` |
| `speaker_1320` | negative example | `1320-122617-0022` | `18.730` | `22.585` |
| `speaker_1320` | negative example | `1320-122617-0023` | `23.085` | `30.900` |

Use the `14.225` second `speaker_6930` enrollment range because the production policy requires at least 10 seconds of enrollment audio. Use `6930-75918-0000` as held-out positive speech. When enrolled on `speaker_6930`, both `speaker_1320` ranges should resolve to other/uncertain rather than owner.

## FluidAudio model cache

FluidAudio v0.15.6 stores the diarizer models under:

```text
~/Library/Application Support/FluidAudio/Models/speaker-diarization/
```

The expected compiled model bundles are:

```text
pyannote_segmentation.mlmodelc
wespeaker_v2.mlmodelc
```

For startup cached-only checks, verify those local bundles directly and load them with `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:configuration:)`. In v0.15.6, `DiarizerModels.load(from:)` and `downloadIfNeeded(to:)` route through the downloader path, so they are not suitable for a no-network launch check.

## Opt-in XCTest sentinel

Keep real-model tests skipped by default. Enable them only when the fixture exists and the local FluidAudio model cache has been prepared:

```sh
touch build/fluidaudio-validation/enable-model-validation \
  xcodebuild test ...
```

The validation test should also write its report JSON under ignored `build/fluidaudio-validation` output so model scores and thresholds are reviewable without committing generated artifacts.

The app owns its model cache at `~/Library/Application Support/AI-NoteTaker/VoiceModels/speaker-diarization/` (separate from the SDK default). The XCTest gate is the `build/fluidaudio-validation/enable-model-validation` file; remove it after explicit model validation.
