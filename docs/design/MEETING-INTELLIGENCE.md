# Meeting intelligence design

Status: implemented and verified (2026-09-09); Mac and the sync server are deployed. Mac/iOS 1.3.1 build 8 fixes the VoiceEnrollmentCapture tap SIGTRAP and is installed on Mac and the physical iPhone. Mac code signing and launch are verified. The iPhone launched at 2026-09-09 09:43:15 KST, and the same PID 13689 was still present at 09:44:21 KST.

## Approved scope

Speaker-attributed timed transcripts; local owner voice enrollment in a Profile settings tab; live owner indicator with uncertain state; speaker naming, group owner correction and per-turn reassignment; filter and continuous playback of owner utterances; personal commitments and received requests; question/answer and unanswered-question links; evidence-backed decision trails; project-based next-meeting briefing; personal/work terminology glossary. Combining simultaneous Mac/iPhone recordings is excluded.

## Data and privacy

- Preserve original audio, existing Markdown minutes and existing v1 sync compatibility.
- New shared Foundation/Codable types live in `Shared/MeetingIntelligence` and compile into both app targets.
- A timed transcript contains stable turn IDs, absolute audio-relative start/end times, text, and speaker IDs. Speaker identity corrections are explicit user changes. Uncertain identity stays unknown; microphone source alone is not proof of owner identity.
- Every action, answer and decision cites actual turn IDs. Validate citations, bounds, types and limits before publishing. No fabricated speaker labels or timestamp guesses when a provider returns only plain text.
- Voice enrollment samples/embeddings stay device-local, with enrollment/re-enrollment/delete controls. Text profile (display name, aliases, role, glossary) and meeting annotations/insights sync via Cloudflare. Keys stay local.
- Owner voice labels support navigation, not authentication. Manual labels override model suggestions.
- A project label groups meetings for a briefing built from prior decisions, open actions and unresolved questions with links to the source meeting.

## Processing

- Detailed OpenRouter transcription requests retain genuine provider timestamps. A dedicated on-device speaker model performs acoustic diarization/embedding comparison, using the approved FluidAudio 0.15.6 dependency.
- Recording audio observers must be bounded and nonblocking; ML inference never runs on the recording I/O callback. Existing recording integrity takes precedence over optional live inference.
- Keep existing Markdown generation available. Add an explicit conversation-analysis action for existing recordings; optional automatic analysis can be enabled separately so upgrading does not silently increase AI usage.
- Structured analysis uses OpenRouter with evidence IDs and terminology context. Missing/unsupported detail produces an actionable state while preserving prior artifacts.
- Reuse saved transcripts/analysis when valid. Keep user speaker corrections and task state separate from generated evidence. Cancel stale work when audio changes or notes are deleted.

## Verification

Sequential Xcode builds/tests (`-jobs 2`), fake-provider contract tests without paid calls, real on-device model checks using non-private labeled samples with the approved dependency, synthetic audio recording checks, static screen rendering without global mouse/keyboard automation, sync conflict/cancellation/integrity tests, and in-place signed app upgrades only after checks pass. Do not claim perfect biometric or AI accuracy.


## Release state

Mac/iOS 1.3.1 build 8 is installed on Mac and the physical iPhone. Mac code signing and launch are verified. The physical iPhone install succeeded, launch succeeded at 2026-09-09 09:43:15 KST, and the same PID 13689 was still present at 09:44:21 KST. Public model-file preservation was verified after the 1.3.1 update: 13 files totaling 13,987,593 bytes in the app data container. Personal voice enrollment, user voice samples, and real microphone tests were not transferred, recorded, or verified during these checks.
