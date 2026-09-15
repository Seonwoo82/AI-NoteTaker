import Foundation

#if canImport(FoundationModels)
@preconcurrency import FoundationModels
#endif

#if canImport(Speech)
@preconcurrency import Speech
#endif

@MainActor
enum LocalAIAvailability {
    static func status(localeIdentifier: String) -> LocalAIStatus {
        guard LocalAIModel.supportedSpeechLocales.contains(localeIdentifier) else {
            return LocalAIStatus(isAvailable: false, message: "지원하지 않는 온디바이스 전사 언어입니다.")
        }

        let modelStatus = foundationModelStatus(localeIdentifier: localeIdentifier)
        guard modelStatus.isAvailable else { return modelStatus }

        guard speechAuthorizationAllowsStatus else {
            return LocalAIStatus(isAvailable: false, message: "음성 인식 권한이 필요합니다.")
        }

        guard speechSupportsOnDevice(localeIdentifier: localeIdentifier) else {
            return LocalAIStatus(isAvailable: false, message: "이 기기에서 \(localeIdentifier) 온디바이스 음성 인식을 사용할 수 없습니다.")
        }

        return modelStatus
    }

    static func prepare(localeIdentifier: String) async -> LocalAIStatus {
        guard LocalAIModel.supportedSpeechLocales.contains(localeIdentifier) else {
            return LocalAIStatus(isAvailable: false, message: "지원하지 않는 온디바이스 전사 언어입니다.")
        }

        let modelStatus = foundationModelStatus(localeIdentifier: localeIdentifier)
        guard modelStatus.isAvailable else { return modelStatus }

        let authorization = await requestSpeechAuthorization()
        guard authorization == .authorized else {
            return LocalAIStatus(isAvailable: false, message: "음성 인식 권한이 거부되었습니다. 시스템 설정에서 권한을 허용해 주세요.")
        }

        return status(localeIdentifier: localeIdentifier)
    }

    private static var speechAuthorizationAllowsStatus: Bool {
        #if canImport(Speech)
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
        #else
        return false
        #endif
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        #if canImport(Speech)
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        #else
        return .denied
        #endif
    }

    private static func speechSupportsOnDevice(localeIdentifier: String) -> Bool {
        #if canImport(Speech)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            return false
        }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
        #else
        return false
        #endif
    }

    private static func foundationModelStatus(localeIdentifier: String) -> LocalAIStatus {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return LocalAIStatus(isAvailable: false, message: "온디바이스 요약은 macOS 26 또는 iOS 26 이상에서 사용할 수 있습니다.")
        }

        let model = SystemLanguageModel.default
        guard model.supportsLocale(Locale(identifier: localeIdentifier)) else {
            return LocalAIStatus(isAvailable: false, message: "Apple Intelligence 모델이 \(localeIdentifier) 요약을 지원하지 않습니다.")
        }

        switch model.availability {
        case .available:
            return LocalAIStatus(isAvailable: true, message: "온디바이스 AI를 사용할 수 있습니다.")
        case .unavailable(.deviceNotEligible):
            return LocalAIStatus(isAvailable: false, message: "이 기기는 Apple Intelligence 온디바이스 모델을 지원하지 않습니다.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return LocalAIStatus(isAvailable: false, message: "Apple Intelligence가 꺼져 있습니다. 시스템 설정에서 켜 주세요.")
        case .unavailable(.modelNotReady):
            return LocalAIStatus(isAvailable: false, message: "Apple Intelligence 모델이 아직 준비되지 않았습니다. 시스템 설정에서 모델 준비 상태를 확인해 주세요.")
        @unknown default:
            return LocalAIStatus(isAvailable: false, message: "온디바이스 AI 상태를 확인할 수 없습니다.")
        }
        #else
        return LocalAIStatus(isAvailable: false, message: "이 빌드에서 Apple 온디바이스 요약 프레임워크를 사용할 수 없습니다.")
        #endif
    }
}
