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
- [x] Run model, unit, integration and visual checks; update docs/backlog; deploy the Worker and install Mac.
- [x] Diagnose and fix the iOS SIGTRAP from the MainActor-inherited VoiceEnrollmentCapture tap callback; apply the same nonisolated callback pattern to observed recording taps as prevention.
- [x] Install 1.3.1 build 8 on Mac and physical iPhone.
- [x] Launch 1.3.1 build 8 on the physical iPhone and confirm the same PID remains after more than one minute.

Verified: Mac 360, iOS simulator 236, AudioPipeline 237, Worker 45 tests; real FluidAudio inference and local workerd integration. Mac 1.3.1 build 8 Release passed, code signing passed, and `/Applications/AI-NoteTaker.app` launched. iOS 1.3.1 build 8 Release passed, `build/releases/AI-NoteTaker-iOS-1.3.1-build8.ipa` was created and version-verified, and the app installed on the physical iPhone. The iPhone launched at 2026-09-09 09:43:15 KST, and the same PID 13689 was still present at 09:44:21 KST. Public model-file preservation was verified after the 1.3.1 update. Personal voice enrollment, user voice samples, and real microphone tests were not transferred, recorded, or verified. See [verification record](MEETING-INTELLIGENCE-VERIFICATION.md).
