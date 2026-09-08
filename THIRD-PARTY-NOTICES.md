# Third-Party Notices

Last reviewed: 2026-09-09

This file records third-party software and model artifacts relevant to the local speaker-analysis path and the FluidAudio package now linked into the Mac and iOS targets. It is a developer-facing notice for this repository; review upstream license texts again before any public binary distribution. Full license texts copied from the resolved FluidAudio package checkout are also bundled under `Shared/Resources/Licenses/`. Full license texts copied from the resolved FluidAudio package checkout are also bundled under `Shared/Resources/Licenses/`.

## FluidAudio

- Component: Swift package `FluidAudio`
- Version used by this project: `0.15.6` (`v0.15.6` Git tag)
- Source: <https://github.com/FluidInference/FluidAudio>
- License: Apache License 2.0
- Project usage: local Core ML speaker diarization and speaker embedding extraction on macOS and iOS.

The repository license file for `v0.15.6` is Apache License 2.0. The project README also describes the SDK license as Apache 2.0. The copied text is bundled at `Shared/Resources/Licenses/FluidAudio-LICENSE.txt`. The copied text is bundled at `Shared/Resources/Licenses/FluidAudio-LICENSE.txt`.

The `FluidAudio` library product declares these targets in `Package.swift`: `FluidAudio`, `FastClusterWrapper`, `MachTaskSelfWrapper`, and the prebuilt `NemoTextProcessing` binary target. The app currently calls the diarization path, but notices should cover the linked package product rather than only the call sites.

## FluidInference speaker diarization Core ML models

- Component: `FluidInference/speaker-diarization-coreml`
- Source: <https://huggingface.co/FluidInference/speaker-diarization-coreml>
- Files used by this project through FluidAudio `DiarizerModels`: `pyannote_segmentation.mlmodelc`, `wespeaker_v2.mlmodelc`
- Model card license: Creative Commons Attribution 4.0 International (`cc-by-4.0`)
- Parent model noted by the model card: `pyannote/speaker-diarization-community-1`, also listed as `cc-by-4.0`
- Project usage: optional model download/preparation for local speaker diarization and owner-voice comparison.

The model card states that the SDK is Apache 2.0 while the parent Pyannote model is `cc-by-4.0`. Keep attribution available in product/release documentation when distributing builds that include or auto-download these model artifacts.

## WeSpeaker

- Component: WeSpeaker speaker embedding toolkit referenced by FluidAudio and the diarization model card
- Source: <https://github.com/wenet-e2e/wespeaker>
- License: Apache License 2.0
- Project usage: upstream/source technology for the `wespeaker_v2.mlmodelc` embedding model used by the FluidAudio diarization pipeline.

## fastcluster

- Component: `FastClusterWrapper` target inside FluidAudio
- Upstream project: fastcluster by Daniel Müllner, later changes by Google Inc.
- License: BSD-style permissive license included at `FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md`
- Project usage: linked through FluidAudio for clustering support.

The included license requires preserving the copyright notice, conditions, and disclaimer in source and binary redistributions. The copied text is bundled at `Shared/Resources/Licenses/fastcluster-LICENSE.txt`. The copied text is bundled at `Shared/Resources/Licenses/fastcluster-LICENSE.txt`.

## VBx

- Component: VBx clustering license included by FluidAudio
- License: Apache License 2.0, included at `FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md` and copied to `Shared/Resources/Licenses/vbx-LICENSE.txt` and copied to `Shared/Resources/Licenses/vbx-LICENSE.txt`
- Project usage: linked through FluidAudio's diarization/clustering implementation.

## NemoTextProcessing binary target

- Component: `NemoTextProcessing.xcframework`
- Source package: <https://github.com/FluidInference/text-processing-rs>
- Version noted by FluidAudio: `v0.3.0`
- License: Apache License 2.0 for `text-processing-rs`
- Bundled upstream works noted by FluidAudio: NVIDIA NeMo Text Processing (Apache-2.0), `rustfst` (MIT OR Apache-2.0), `flate2` (MIT OR Apache-2.0), and transitive Rust crates under MIT and/or Apache-2.0.
- Project usage: linked through the FluidAudio package product. AI-NoteTaker's current meeting-intelligence feature does not directly call text-to-speech or NeMo normalization UI, but the package product includes the binary target.

See `FluidAudio/ThirdPartyLicenses/NemoTextProcessing-LICENSE.md` for the complete upstream summary included by FluidAudio. The copied text is bundled at `Shared/Resources/Licenses/NemoTextProcessing-LICENSE.txt`. The copied text is bundled at `Shared/Resources/Licenses/NemoTextProcessing-LICENSE.txt`.

## MachTaskSelfWrapper

- Component: `MachTaskSelfWrapper` target inside FluidAudio
- License coverage: included as part of the Apache-2.0 FluidAudio package unless an upstream notice is later added by FluidAudio.
- Project usage: linked through FluidAudio.

## Runtime service providers

AI-NoteTaker can optionally send audio/transcript data to OpenRouter and can optionally synchronize user data through a user-owned Cloudflare Worker/D1/R2 deployment. Those services are not bundled code dependencies of this repository, but users must follow their own account terms, pricing, and data-processing policies.

- OpenRouter: <https://openrouter.ai/>
- Cloudflare Workers, D1, and R2: <https://developers.cloudflare.com/>
