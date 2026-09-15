# Windows preview 0.1 implementation and verification

Date: 2026-09-14. Reference checkout: `38f843b` on `main`.

## Scope and architecture

Added an independent `Windows/` application. SwiftUI, CoreAudio and Core ML are Apple dependencies and are not made Windows-compatible by changing build targets. The Windows implementation maps the existing recording/library/meeting-notes workflow to WPF, WASAPI, per-recording JSON/WAV storage, and DPAPI-protected credentials. Original Swift projects and Cloudflare services are unchanged.

The Windows library is intentionally versioned independently. It does not claim compatibility with Apple JSON date serialization, `audio.m4a`, meeting contracts or Cloudflare sync. The complete Windows feature matrix and remaining port work are in `Windows/README.md`.

## Verification performed

- Release build: zero warnings/errors with .NET SDK 10.0.401.
- Automated tests: 29 passed. The normal test run skips 4 opt-in hardware cases, which were run separately and passed.
- Hardware tests: 4 passed on this Windows x64 PC. Microphone recording and WAV finalization, system recording with pause/resume, and audible test signal presence in both loopback and mixed recordings were checked. No external upload occurred; temporary test audio was removed after tests.
- Packaged executable: self-contained `win-x64/AI-NoteTaker.exe` launched directly and returned exit code 0 in smoke mode, without using `dotnet run`. The package includes runtime notices and a ZIP.
- UI smoke: the packaged WPF app started and rendered with fixture content for empty library, saved meeting, minimum-size window and AI settings. Favorite, delete, restore, title search, transcript-tab event wiring and graceful close passed. Screenshots inspected. Fixed reentrant Close handling discovered by this test. Content can scroll at the minimum window size.
- Tests cover corrupt metadata retention, identity validation, interrupted WAV header repair, missing audio recovery, import and cancellation, DPAPI key round trip, PCM mixing, UTF-8 chunk boundaries, mono 16 kHz transcription chunks, fixed OpenRouter request contract, sanitized HTTP errors, HTTP-200 error envelopes, incomplete/empty model responses, cancellation, transcript cache reuse and invalidation, and existing notes retention on failed regeneration.

## Boundaries

- API requests were validated against the official OpenRouter contract and mocked HTTP responses. Public model availability was checked. **No actual user API key, paid transcription or real AI meeting report was tested.**
- Hardware smoke tests are short. No claim is made about hours-long audio drift, acoustic echo, Bluetooth reconnection, capture during sleep/lock, abrupt device removal, true disk exhaustion or intelligibility of the user's microphone.
- The application UI rendered during smoke tests. This is not a full user-driven accessibility or end-to-end UI regression suite.
- Windows x64 is the verified runtime target. ARM64 and Windows 10 were not run.
- macOS/iOS tests cannot run on this Windows machine. No Swift sources changed.
- Preview artifacts are unsigned local builds; no Git push, GitHub release, cloud deployment, collaborator invite or automatic external publication occurred.

## Reproduce

Run `Windows/build.ps1 build`, `Windows/build.ps1 test`, `Windows/build.ps1 smoke-ui`, and optionally `Windows/build.ps1 audio-smoke` from the repository root. `Windows/build.ps1 publish` creates a self-contained executable and ZIP. Generated artifacts and local SDK are ignored by Git.
