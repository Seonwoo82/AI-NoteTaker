# Meeting intelligence implementation plan

Goal: Deliver the approved speaker/profile and personal meeting workflow on Mac and iOS, excluding multi-device recording fusion.

Architecture: Shared typed transcript/analysis/profile artifacts with bounded validation; platform recording/playback adapters; local voice inference; existing OpenRouter and Cloudflare services.

Tech: Swift 6, SwiftUI, AVFoundation, Core ML, OpenRouter, Cloudflare Worker/D1/R2. FluidAudio 0.15.6 and its models were approved on 2026-09-09 and are linked in both targets.

Spec: `docs/design/MEETING-INTELLIGENCE.md`

- [x] Define and test timed transcript, speaker, evidence, action, Q/A and decision contracts and parser.
- [x] Implement detailed transcription and grounded analysis service while preserving existing minutes.
- [x] Implement text profile/glossary and local voice-profile lifecycle.
- [x] Implement bounded live PCM observers and continuous AVFoundation resampling.
- [x] Link FluidAudio and validate actual model inference, cached restore and corrupt-cache repair with public speech.
- [x] Implement speaker correction, owner filter/continuous playback and personal insight UI.
- [x] Implement project grouping and linked next-meeting briefing.
- [x] Extend artifact/profile synchronization with migration and validation, excluding biometric data.
- [x] Run model, unit, integration and visual checks; update docs/backlog; deploy the Worker and install Mac 1.3.
- [ ] Complete physical iPhone installation when its CoreDevice connection is available.

Verified: Mac 359, iOS simulator 234, AudioPipeline 237, Worker 45 tests; real FluidAudio inference and local workerd integration. Mac 1.3 and production Worker are deployed; the signed iOS 1.3 build is prepared. Physical iPhone install is pending device connectivity. See [verification record](MEETING-INTELLIGENCE-VERIFICATION.md).
