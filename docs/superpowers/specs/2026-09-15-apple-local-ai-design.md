# Free on-device AI for Mac and iPhone

## Authorized scope
User requests the Windows-style free local transcription and meeting-notes capability on Mac/iPhone, with existing OpenRouter support retained. Implement using Apple Speech and FoundationModels system frameworks; no new dependencies, services, keys, or inference servers. Retain iOS17 compatibility for existing functionality; local summarization requires iOS26/macOS26, a supported Apple Intelligence device, enabled Apple Intelligence and available system model. System readiness and on-device speech locale support are checked explicitly. Never silently fall back to cloud.

## User experience
AI settings offers two modes: OpenRouter and Free on this device. Keep the existing default/preferences so an update does not change a user's provider. Local mode is per-device and not synced. Local speech language is selectable Korean (ko-KR) or English (en-US), also per-device. The local card describes prerequisites, readiness and local processing, and has a Prepare/check action that requests speech permission and checks model readiness. System model setup is through Apple Intelligence settings, not a fake app download. Existing cloud keys/model choices are preserved when changing modes.

Generate and automatically generate completed minutes using local transcription + local summary with cost0. Retain cancellation, transcript caching, existing successful documents and web sharing. Local summary uses bounded fresh sessions and hierarchical condensation for long transcripts. Do not invoke cloud cleanup, cloud speaker transcription, or cloud advanced analysis in local mode. Advanced features requiring cloud remain disabled with an explanation. Download/setup may require internet; inference is on-device. The user can explicitly select OpenRouter for those advanced features or unsupported devices.

## Interfaces and ownership
Shared/LocalAI/LocalAIModels.swift:
- LocalAIProcessingMode: String, CaseIterable, Codable, Sendable: openRouter, onDevice.
- LocalAIStatus: Equatable, Sendable, init(isAvailable: Bool, message: String).
- LocalAIModel.summaryID = "apple/on-device-summary".
- LocalAIModel.transcriptionID(localeIdentifier:) produces "apple/on-device-speech/<locale>"; supported locales ko-KR, en-US; helpers isLocal(modelID), speechLocale(modelID).
- LocalAIModel.summaryDescriptor: OpenRouterModel with4096 context and1024 completion cap.
Shared/LocalAI/AppleOnDeviceAIClient.swift and supporting files:
- AppleOnDeviceAIClient: OpenRouterServing; strict model validation; speech requiresOnDeviceRecognition=true; clips <=50seconds (can use existing MeetingAudioChunker inside incoming120second chunks); temporary audio removed; authorization, availability, cancellation and bounded timeout handled. FoundationModels new session per call, guard availability/output and convert errors to actionable AIError. Cost0.
- RoutingAIClient: OpenRouterServing, init(cloud: any OpenRouterServing, local: any OpenRouterServing = AppleOnDeviceAIClient()). Route transcribe/complete solely by captured model ID; cloud models/validateKey remain delegated; unknown apple/on-device prefixes must not reach cloud. Local failure never calls cloud.
- @MainActor LocalAIAvailability.status(localeIdentifier:) -> LocalAIStatus, prepare(localeIdentifier:) async -> LocalAIStatus. Pure status never prompts; prepare may request permission. Use installed SDK26.6 APIs, availability guards.

AIConfiguration (both platform files): processingMode, usesLocalAI, localSpeechLocaleIdentifier, localStatus, effectiveModelID, effectiveTranscriptionModelID, effectiveSummaryModel, generationAPIKey() (empty only forlocal), refreshLocalAIStatus(), prepareLocalAI()async, isPreparingLocalAI. Mode change cancels in-flight AI via onCredentialsChanged; keep mode/locale out of AISharedPreferences. Inject local readiness/preparation providers if needed for deterministic tests. Existing apiKey() retains cloud-key semantics. isConfigured recognizes local readiness without a key; enhancement/cleanup/cloud-analysis readiness false in local mode. needsKeyForSyncedSettings false in local mode.

AIEnvironment.live wraps OpenRouterClient in RoutingAIClient; testing remains fake. MeetingNotesService uses effective captured model IDs and generationAPIKey, local context budget; skips cloud callbacks/cleanup, empty-key redaction must not corrupt errors. Existing cloud generation paths unchanged. Do not send private audio to the cloud after selecting local mode, including background/advanced callbacks.

UI lane owns AISettingsView, MeetingNotesView copy/disabled-action affordances, localization catalogs, project.yml and iOS/project.yml permission usage strings, entitlement additions only if system requires them. Integration lane owns duplicated AIConfiguration, AIEnvironment and MeetingNotesService. Backend lane owns Shared/LocalAI and its dedicated tests. Root owns Shared/MeetingIntelligence privacy gates, overall docs and final verification.

## Acceptance
- Tests demonstrate local calls use local models and no key; cloud adapter not called even when local fails/cancels; switching keeps cloud keys/preferences and cancels current jobs.
- Completed local document includes accurate local model IDs, full transcript and cost0 and can be web-shared unchanged.
- Readiness identifies unsupported OS/device/language, missing model, denied speech permission. Inference never permits remote Speech fallback.
- Mac and iOS builds with unchanged minimum iOS version; native client/pipeline/settings tests. Verify actual system-model inference when available; accurately record unavailable system assets or unsupported simulator speech. Do not modify the user's Apple Intelligence settings automatically.
