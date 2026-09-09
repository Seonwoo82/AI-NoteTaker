import SwiftUI

struct VoiceProfilePresentation: Equatable {
    var modelsReady: Bool
    var isPreparing: Bool
    var isEnrolling: Bool
    var isProcessing: Bool
    var elapsed: Double
    var status: String
    var error: String?

    init(
        modelsReady: Bool = false,
        isPreparing: Bool = false,
        isEnrolling: Bool = false,
        isProcessing: Bool = false,
        elapsed: Double = 0,
        status: String = "",
        error: String? = nil
    ) {
        self.modelsReady = modelsReady
        self.isPreparing = isPreparing
        self.isEnrolling = isEnrolling
        self.isProcessing = isProcessing
        self.elapsed = elapsed
        self.status = status
        self.error = error
    }
}


struct OwnerSpeechIndicatorView: View {
    let state: OwnerSpeechState
    var compact = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 6)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("owner-speech-indicator")
            .accessibilityLabel(accessibilityLabel)
    }

    private var title: String {
        switch state {
        case .owner: String(localized: "Likely me speaking")
        case .other: String(localized: "Another speaker")
        case .uncertain: String(localized: "Speaker uncertain")
        case .listening: String(localized: "Listening for my voice")
        case .silence: String(localized: "Waiting for speech")
        case .unavailable: String(localized: "Owner voice unavailable")
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .owner: String(localized: "Owner voice detection says this is likely my voice")
        case .other: String(localized: "Owner voice detection says another speaker is likely talking")
        case .uncertain: String(localized: "Owner voice detection is uncertain")
        case .listening: String(localized: "Owner voice detection is listening")
        case .silence: String(localized: "Owner voice detection is waiting for speech")
        case .unavailable: String(localized: "Owner voice detection is unavailable")
        }
    }

    private var systemImage: String {
        switch state {
        case .owner: "person.wave.2.fill"
        case .other: "person.2.fill"
        case .uncertain: "person.crop.circle.badge.questionmark"
        case .listening: "ear.badge.waveform"
        case .silence: "waveform.slash"
        case .unavailable: "person.crop.circle.badge.exclamationmark"
        }
    }

    private var tint: Color {
        switch state {
        case .owner: .blue
        case .other: .purple
        case .uncertain: .orange
        case .listening: .green
        case .silence: .secondary
        case .unavailable: .secondary
        }
    }
}

struct MeetingProfileView: View {
    let store: MeetingProfileStore
    let voice: VoiceProfilePresentation
    let recordingIsBusy: Bool
    let prepareVoiceModels: () -> Void
    let beginEnrollment: () async -> Void
    let finishEnrollment: () -> Void
    let cancelEnrollment: () -> Void
    let deleteEnrollment: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var draftDisplayName = ""
    @State private var draftAliases = ""
    @State private var draftRole = ""
    @State private var draftTerm = ""
    @State private var draftSpokenAs = ""
    @State private var draftMeaning = ""
    @State private var draftCategory: GlossaryCategory = .general
    @State private var editingTermID: UUID?
    @State private var localMessage: String?
    @State private var showingVoiceEnrollmentGuide = false
    @State private var didAutoFinishVoiceEnrollment = false
    @State private var didRequestVoiceEnrollmentFinish = false
    @State private var voiceEnrollmentCompleted = false
    @State private var previousVoiceProfile: LocalVoiceProfile?
    @State private var hasStartedVoiceEnrollment = false
    @State private var isStartingVoiceEnrollment = false
    @State private var startVoiceEnrollmentTask: Task<Void, Never>?
    @State private var startVoiceEnrollmentID = UUID()
    @FocusState private var focusedInput: MeetingProfileInput?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                voiceCard
                profileCard
                glossaryCard
                statusCard
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.profileWindowBackground)
        .onAppear(perform: refreshDraftsFromStore)
        .onDisappear(perform: cancelActiveEnrollmentFromDismiss)
        .onChange(of: store.profile) { _, _ in refreshDraftsFromStore() }
        .sheet(isPresented: $showingVoiceEnrollmentGuide, onDismiss: cancelActiveEnrollmentFromDismiss) {
            VoiceEnrollmentGuideView(
                voice: hasStartedVoiceEnrollment ? voice : VoiceProfilePresentation(
                    modelsReady: voice.modelsReady, isPreparing: voice.isPreparing),
                hasExistingProfile: store.localVoice != nil,
                recordingIsBusy: recordingIsBusy,
                isStarting: isStartingVoiceEnrollment,
                isCompleted: voiceEnrollmentCompleted,
                onStart: startVoiceEnrollment,
                onFinish: finishVoiceEnrollment,
                onCancel: {
                    cancelVoiceEnrollmentFlow()
                    showingVoiceEnrollmentGuide = false
                },
                onClose: { showingVoiceEnrollmentGuide = false }
            )
            .presentationDetentsForVoiceEnrollment()
        }
        .onChange(of: voice) { _, newValue in
            if showingVoiceEnrollmentGuide,
               newValue.isEnrolling,
               newValue.elapsed >= VoiceEnrollmentGuidePolicy().maximumDuration,
               !didAutoFinishVoiceEnrollment {
                didAutoFinishVoiceEnrollment = true
                finishVoiceEnrollment()
            }
            guard showingVoiceEnrollmentGuide,
                  didRequestVoiceEnrollmentFinish,
                  !newValue.isEnrolling,
                  !newValue.isProcessing,
                  newValue.error == nil,
                  store.localVoice != nil,
                  store.localVoice != previousVoiceProfile else { return }
            voiceEnrollmentCompleted = true
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .background else { return }
            cancelVoiceEnrollmentFlow()
            showingVoiceEnrollmentGuide = false
        }
#if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done")) { focusedInput = nil }
                    .accessibilityIdentifier("profile-hide-keyboard")
            }
        }
#endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "Profile"), systemImage: "person.crop.circle")
                .font(.title2.weight(.semibold))
            Text(String(localized: "Help AI-NoteTaker recognize your role, names, and meeting vocabulary across linked devices."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var profileCard: some View {
        ProfileSettingsCard {
            Label(String(localized: "Text Profile"), systemImage: "person.text.rectangle")
                .font(.headline)
            Text(String(localized: "This text profile syncs through Cloudflare. API keys and voice enrollment stay on each device."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                profileFieldLabel("Display Name")
                TextField(String(localized: "Display Name"), text: $draftDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("profile-display-name")
                    .profileFocused($focusedInput, equals: .displayName)
                profileFieldLabel("Aliases, separated by commas")
                TextField(String(localized: "Aliases, separated by commas"), text: $draftAliases)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("profile-aliases")
                    .profileFocused($focusedInput, equals: .aliases)
                profileFieldLabel("Role")
                TextField(String(localized: "Role"), text: $draftRole)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("profile-role")
                    .profileFocused($focusedInput, equals: .role)
            }

            HStack {
                Button {
                    saveProfile()
                } label: {
                    Label(String(localized: "Save Profile"), systemImage: "square.and.arrow.down")
                }
                .disabled(!profileDraftHasChanges)
                .accessibilityIdentifier("profile-save")

                Button {
                    refreshDraftsFromStore()
                } label: {
                    Label(String(localized: "Revert"), systemImage: "arrow.uturn.backward")
                }
                .disabled(!profileDraftHasChanges)
                .accessibilityIdentifier("profile-revert")
            }
            .buttonStyle(.bordered)
        }
    }

    private var glossaryCard: some View {
        ProfileSettingsCard {
            HStack {
                Label(String(localized: "Glossary"), systemImage: "text.book.closed")
                    .font(.headline)
                Spacer()
                Text("\(store.profile.terms.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile-glossary-count")
            }

            if store.profile.terms.isEmpty {
                Text(String(localized: "Add names, products, acronyms, and project words that are often misheard in meetings."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                glossaryList
            }

            Divider()

            glossaryEditor
        }
    }

    private var glossaryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.profile.terms) { term in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(term.term, systemImage: icon(for: term.category))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Spacer()
                        Text(categoryTitle(term.category))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    if !term.spokenAs.isEmpty {
                        Text(String(localized: "Heard as: \(term.spokenAs)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !term.meaning.isEmpty {
                        Text(term.meaning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            editButton(for: term)
                            deleteButton(for: term)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            editButton(for: term)
                            deleteButton(for: term)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("profile-glossary-term-\(term.id.uuidString)")
            }
        }
    }

    private var glossaryEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editingTermID == nil ? String(localized: "Add Term") : String(localized: "Edit Term"))
                .font(.subheadline.weight(.semibold))
            TextField(String(localized: "Term"), text: $draftTerm)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("profile-glossary-term")
                .profileFocused($focusedInput, equals: .term)
            TextField(String(localized: "Spoken As"), text: $draftSpokenAs)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("profile-glossary-spoken-as")
                .profileFocused($focusedInput, equals: .spokenAs)
            TextField(String(localized: "Meaning"), text: $draftMeaning, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .accessibilityIdentifier("profile-glossary-meaning")
                .profileFocused($focusedInput, equals: .meaning)
            Picker(String(localized: "Category"), selection: $draftCategory) {
                ForEach(GlossaryCategory.allCases, id: \.self) { category in
                    Label(categoryTitle(category), systemImage: icon(for: category))
                        .tag(category)
                }
            }
            .accessibilityIdentifier("profile-glossary-category")

            ViewThatFits(in: .horizontal) {
                HStack { glossarySaveButton; glossaryCancelButton }
                VStack(alignment: .leading, spacing: 8) { glossarySaveButton; glossaryCancelButton }
            }
            .buttonStyle(.bordered)
        }
    }

    private var glossarySaveButton: some View {
        Button {
            saveGlossaryTerm()
        } label: {
            Label(editingTermID == nil ? String(localized: "Add Term") : String(localized: "Save Term"),
                  systemImage: editingTermID == nil ? "plus.circle" : "checkmark.circle")
        }
        .disabled(draftTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("profile-glossary-save")
    }

    private var glossaryCancelButton: some View {
        Button {
            resetGlossaryDraft()
        } label: {
            Label(String(localized: "Clear"), systemImage: "xmark.circle")
        }
        .disabled(!glossaryDraftHasContent)
        .accessibilityIdentifier("profile-glossary-clear")
    }

    private var voiceCard: some View {
        ProfileSettingsCard {
            HStack {
                Label(String(localized: "My Voice"), systemImage: "waveform.and.person.filled")
                    .font(.headline)
                Spacer()
                voiceBadge
            }

            Text(String(localized: "Voice enrollment is stored only on this device. It helps highlight likely owner speech, but uncertain matches still need review."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let localVoice = store.localVoice {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(localized: "Registered on this device"), systemImage: "checkmark.seal")
                        .font(.subheadline.weight(.semibold))
                    Text(localVoice.enrolledAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("profile-voice-enrolled-at")
                }
            } else {
                Label(String(localized: "No local voice profile is registered."), systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile-voice-empty")
            }

            if recordingIsBusy {
                Label(String(localized: "Voice enrollment is unavailable while recording."), systemImage: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile-voice-recording-busy")
            }

            if !voice.status.isEmpty || voice.isPreparing || voice.isEnrolling || voice.isProcessing {
                HStack {
                    if voice.isPreparing || voice.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(voiceStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("profile-voice-status")
                }
            }

            if let error = voice.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("profile-voice-error")
            }

            ViewThatFits(in: .horizontal) {
                voiceButtons
                VStack(alignment: .leading, spacing: 8) {
                    prepareButton
                    beginButton
                    deleteVoiceButton
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var voiceBadge: some View {
        Label(
            voice.modelsReady ? String(localized: "Ready") : String(localized: "Not Ready"),
            systemImage: voice.modelsReady ? "checkmark.circle.fill" : "circle"
        )
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .accessibilityIdentifier("profile-voice-ready")
    }

    private var voiceButtons: some View {
        HStack {
            prepareButton
            beginButton
            deleteVoiceButton
        }
    }

    private var prepareButton: some View {
        Button {
            prepareVoiceModels()
        } label: {
            Label(String(localized: "Prepare"), systemImage: "arrow.down.circle")
        }
        .disabled(voice.isPreparing || voice.modelsReady)
        .accessibilityIdentifier("profile-voice-prepare")
    }

    private var beginButton: some View {
        Button {
            focusedInput = nil
            didAutoFinishVoiceEnrollment = false
            didRequestVoiceEnrollmentFinish = false
            voiceEnrollmentCompleted = false
            hasStartedVoiceEnrollment = false
            showingVoiceEnrollmentGuide = true
        } label: {
            Label(store.localVoice == nil ? String(localized: "Record My Voice") : String(localized: "Re-record"), systemImage: "record.circle")
        }
        .disabled(recordingIsBusy || !voice.modelsReady || voice.isPreparing || voice.isEnrolling || voice.isProcessing)
        .accessibilityIdentifier("profile-voice-begin")
    }

    private var deleteVoiceButton: some View {
        Button(role: .destructive) {
            deleteEnrollment()
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
        .disabled(store.localVoice == nil || voice.isEnrolling || voice.isProcessing)
        .accessibilityIdentifier("profile-voice-delete")
    }

    private var statusCard: some View {
        ProfileSettingsCard {
            if let message = localMessage {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile-local-message")
            }
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("profile-store-error")
            }
            if store.pendingProfileUpload != nil {
                Label(String(localized: "Profile changes will sync when the Cloudflare connection is available."), systemImage: "icloud.and.arrow.up")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile-sync-pending")
            }
            if localMessage == nil, store.lastError == nil, store.pendingProfileUpload == nil {
                Label(String(localized: "Profile settings are saved on this device."), systemImage: "checklist")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile-status-ready")
            }
        }
    }

    private var profileDraftHasChanges: Bool {
        draftDisplayName != store.profile.displayName
            || splitAliases(draftAliases) != store.profile.aliases
            || draftRole != store.profile.role
    }

    private var glossaryDraftHasContent: Bool {
        editingTermID != nil
            || !draftTerm.isEmpty
            || !draftSpokenAs.isEmpty
            || !draftMeaning.isEmpty
            || draftCategory != .general
    }

    private var voiceStatusText: String {
        let status = voice.status.isEmpty ? String(localized: "Voice enrollment is in progress.") : voice.status
        guard voice.elapsed > 0 else { return status }
        return "\(status) \(ProfileDurationFormat.short(voice.elapsed))"
    }

    private func refreshDraftsFromStore() {
        draftDisplayName = store.profile.displayName
        draftAliases = store.profile.aliases.joined(separator: ", ")
        draftRole = store.profile.role
    }

    private func saveProfile() {
        focusedInput = nil
        do {
            let aliases = splitAliases(draftAliases)
            try store.updateProfile { profile in
                profile.displayName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                profile.aliases = aliases
                profile.role = draftRole.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            localMessage = String(localized: "Profile saved.")
            refreshDraftsFromStore()
        } catch {
            localMessage = error.localizedDescription
        }
    }

    private func cancelActiveEnrollmentFromDismiss() {
        cancelVoiceEnrollmentFlow()
    }

    private func startVoiceEnrollment() {
        guard startVoiceEnrollmentTask == nil, !isStartingVoiceEnrollment else { return }
        didAutoFinishVoiceEnrollment = false
        didRequestVoiceEnrollmentFinish = false
        voiceEnrollmentCompleted = false
        previousVoiceProfile = store.localVoice
        let taskID = UUID()
        startVoiceEnrollmentID = taskID
        hasStartedVoiceEnrollment = true
        isStartingVoiceEnrollment = true
        startVoiceEnrollmentTask = Task { @MainActor in
            await beginEnrollment()
            guard startVoiceEnrollmentID == taskID else { return }
            isStartingVoiceEnrollment = false
            startVoiceEnrollmentTask = nil
        }
    }

    private func cancelVoiceEnrollmentFlow() {
        startVoiceEnrollmentTask?.cancel()
        startVoiceEnrollmentTask = nil
        startVoiceEnrollmentID = UUID()
        isStartingVoiceEnrollment = false
        didAutoFinishVoiceEnrollment = false
        didRequestVoiceEnrollmentFinish = false
        voiceEnrollmentCompleted = false
        hasStartedVoiceEnrollment = false
        cancelEnrollment()
    }

    private func finishVoiceEnrollment() {
        guard !didRequestVoiceEnrollmentFinish, !isStartingVoiceEnrollment,
              voice.isEnrolling, !voice.isProcessing,
              VoiceEnrollmentGuidePolicy().canFinish(elapsed: voice.elapsed) else { return }
        didRequestVoiceEnrollmentFinish = true
        finishEnrollment()
    }

    private func saveGlossaryTerm() {
        focusedInput = nil
        let updatedTerm = GlossaryTerm(
            id: editingTermID ?? UUID(),
            term: draftTerm.trimmingCharacters(in: .whitespacesAndNewlines),
            spokenAs: draftSpokenAs.trimmingCharacters(in: .whitespacesAndNewlines),
            meaning: draftMeaning.trimmingCharacters(in: .whitespacesAndNewlines),
            category: draftCategory
        )
        do {
            try store.updateProfile { profile in
                if let editingTermID, let index = profile.terms.firstIndex(where: { $0.id == editingTermID }) {
                    profile.terms[index] = updatedTerm
                } else {
                    profile.terms.append(updatedTerm)
                }
            }
            localMessage = editingTermID == nil ? String(localized: "Glossary term added.") : String(localized: "Glossary term saved.")
            resetGlossaryDraft()
        } catch {
            localMessage = error.localizedDescription
        }
    }

    private func editTerm(_ term: GlossaryTerm) {
        editingTermID = term.id
        draftTerm = term.term
        draftSpokenAs = term.spokenAs
        draftMeaning = term.meaning
        draftCategory = term.category
        focusedInput = .term
    }

    private func deleteTerm(_ term: GlossaryTerm) {
        do {
            try store.updateProfile { profile in
                profile.terms.removeAll { $0.id == term.id }
            }
            if editingTermID == term.id { resetGlossaryDraft() }
            localMessage = String(localized: "Glossary term deleted.")
        } catch {
            localMessage = error.localizedDescription
        }
    }

    private func resetGlossaryDraft() {
        editingTermID = nil
        draftTerm = ""
        draftSpokenAs = ""
        draftMeaning = ""
        draftCategory = .general
        if focusedInput == .term || focusedInput == .spokenAs || focusedInput == .meaning {
            focusedInput = nil
        }
    }

    private func editButton(for term: GlossaryTerm) -> some View {
        Button {
            editTerm(term)
        } label: {
            Label(String(localized: "Edit"), systemImage: "pencil")
        }
        .accessibilityIdentifier("profile-glossary-edit-\(term.id.uuidString)")
    }

    private func deleteButton(for term: GlossaryTerm) -> some View {
        Button(role: .destructive) {
            deleteTerm(term)
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
        .accessibilityIdentifier("profile-glossary-delete-\(term.id.uuidString)")
    }


    private func profileFieldLabel(_ title: LocalizedStringResource) -> some View {
        Text(String(localized: title))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func categoryTitle(_ category: GlossaryCategory) -> String {
        switch category {
        case .person: String(localized: "Person")
        case .organization: String(localized: "Organization")
        case .project: String(localized: "Project")
        case .abbreviation: String(localized: "Abbreviation")
        case .general: String(localized: "General")
        }
    }

    private func splitAliases(_ aliases: String) -> [String] {
        aliases
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func icon(for category: GlossaryCategory) -> String {
        switch category {
        case .person: "person"
        case .organization: "building.2"
        case .project: "folder"
        case .abbreviation: "textformat.abc"
        case .general: "tag"
        }
    }
}

private enum MeetingProfileInput: Hashable {
    case displayName
    case aliases
    case role
    case term
    case spokenAs
    case meaning
}

private struct ProfileSettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.profileSeparator.opacity(0.45), lineWidth: 1)
        }
    }
}

enum ProfileDurationFormat {
    static func short(_ seconds: Double) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }
}

private extension View {
    func profileFocused(_ binding: FocusState<MeetingProfileInput?>.Binding, equals input: MeetingProfileInput) -> some View {
#if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused(binding, equals: input)
#else
        self
#endif
    }
}

private extension Color {
    static var profileWindowBackground: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .systemBackground)
#endif
    }

    static var profileSeparator: Color {
#if os(macOS)
        Color(nsColor: .separatorColor)
#else
        Color(uiColor: .separator)
#endif
    }
}
