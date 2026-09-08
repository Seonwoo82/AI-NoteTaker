import SwiftUI

struct MeetingConversationView: View {
    let content: MeetingResolvedDocument?
    let status: String
    let isBusy: Bool
    let hasAPIKey: Bool
    let editable: Bool
    var initialSection: MeetingConversationTab = .transcript
    var canPlayTurns = true
    let profile: MeetingUserProfile
    let onAnalyze: () -> Void
    let onCancel: () -> Void
    let onOpenAISettings: () -> Void
    let onOpenProfile: () -> Void
    let onPlayTurns: ([String]) -> Void
    let onEdit: (MeetingEditKind, String, String) -> Void

    @State private var selectedTab: MeetingConversationTab = .transcript
    @State private var appliedInitialSection = false
    @State private var transcriptFilter: TranscriptFilter = .all
    @State private var actionFilter: ActionFilter = .all
    @State private var questionFilter: QuestionFilter = .all
    @State private var visibleTurnLimit = 100
    @State private var projectDraft = ""
    @State private var speakerNameDrafts: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                stateContent
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.meetingBackground)
        .onAppear(perform: prepareInitialState)
        .onChange(of: content?.projectName) { _, _ in refreshDrafts() }
        .onChange(of: content?.source.mutationID) { _, _ in resetTranscriptPaging() }
        .onChange(of: transcriptFilter) { _, _ in resetTranscriptPaging() }
        .onChange(of: content?.transcript.speakers) { _, _ in refreshSpeakerDrafts() }
        .accessibilityIdentifier("meeting-conversation")
    }

    private var header: some View {
        MeetingConversationCard {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    titleBlock
                    Spacer()
                    primaryControls
                }
                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    primaryControls
                }
            }

            if let content {
                projectEditor(content)
                if content.unresolvedEditCount > 0 {
                    Label(String(localized: "\(content.unresolvedEditCount) edits need review"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("meeting-unresolved-edits")
                }
            }

            if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(status, systemImage: isBusy ? "clock.arrow.circlepath" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meeting-status")
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "AI Meeting"), systemImage: "person.2.wave.2")
                .font(.title3.weight(.semibold))
            Text(String(localized: "Review speaker-separated transcript, commitments, questions, and decision history."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var primaryControls: some View {
        HStack(spacing: 8) {
            if isBusy {
                Button(action: onCancel) {
                    Label(String(localized: "Cancel"), systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("meeting-cancel-analysis")
            } else if hasAPIKey {
                Button(action: onAnalyze) {
                    Label(content == nil ? String(localized: "Analyze") : String(localized: "Reanalyze"),
                          systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!editable)
                .accessibilityIdentifier("meeting-analyze")
            } else {
                Button(action: onOpenAISettings) {
                    Label(String(localized: "Open AI Settings"), systemImage: "key")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("meeting-open-ai-settings")
            }

            Button(action: onOpenProfile) {
                Label(String(localized: "Profile"), systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("meeting-open-profile")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var stateContent: some View {
        if isBusy, content == nil {
            MeetingConversationCard {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Analyzing meeting audio"))
                    .font(.headline)
                Text(String(localized: "The transcript and meeting intelligence will appear here when processing finishes."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("meeting-loading-state")
        } else if !hasAPIKey, content == nil {
            MeetingConversationCard {
                ContentUnavailableView(
                    String(localized: "AI setup needed"),
                    systemImage: "key",
                    description: Text(String(localized: "Save an OpenRouter API key before analyzing this meeting."))
                )
                Button(action: onOpenAISettings) {
                    Label(String(localized: "Open AI Settings"), systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("meeting-key-required")
            }
        } else if content == nil {
            MeetingConversationCard {
                ContentUnavailableView(
                    String(localized: "No Meeting Analysis"),
                    systemImage: "person.2.slash",
                    description: Text(String(localized: "Run AI analysis to create speaker-separated transcript and meeting intelligence."))
                )
                Button(action: onAnalyze) {
                    Label(String(localized: "Analyze"), systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !editable)
                .accessibilityIdentifier("meeting-empty-analyze")
            }
        } else if let content {
            tabs(content)
        }
    }

    private func tabs(_ content: MeetingResolvedDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(String(localized: "Meeting Sections"), selection: $selectedTab) {
                ForEach(MeetingConversationTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("meeting-section-tabs")

            switch selectedTab {
            case .transcript:
                transcriptSection(content)
            case .actions:
                actionsSection(content)
            case .questions:
                questionsSection(content)
            case .decisions:
                decisionsSection(content)
            case .speakers:
                speakersSection(content)
            }
        }
    }

    private func transcriptSection(_ content: MeetingResolvedDocument) -> some View {
        MeetingConversationCard {
            ViewThatFits(in: .horizontal) {
                HStack {
                    sectionTitle(String(localized: "Transcript"), systemImage: "quote.bubble")
                    Spacer()
                    transcriptControls(content)
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(String(localized: "Transcript"), systemImage: "quote.bubble")
                    transcriptControls(content)
                }
            }

            let filteredTurns = filteredTurns(content)
            let visibleTurns = Array(filteredTurns.prefix(visibleTurnLimit))
            if filteredTurns.isEmpty {
                Text(String(localized: "No turns match this filter."))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting-transcript-empty")
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleTurns, id: \.id) { turn in
                        transcriptRow(turn, content: content)
                    }
                }
                if filteredTurns.count > visibleTurns.count {
                    Button {
                        visibleTurnLimit += 100
                    } label: {
                        Label(String(localized: "Load More Transcript Turns"), systemImage: "chevron.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("meeting-transcript-load-more")
                }
            }
        }
    }

    private func transcriptControls(_ content: MeetingResolvedDocument) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Picker(String(localized: "Transcript Filter"), selection: $transcriptFilter) {
                    Text(String(localized: "All")).tag(TranscriptFilter.all)
                    Text(String(localized: "Me")).tag(TranscriptFilter.owner)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                .accessibilityIdentifier("meeting-transcript-filter")

                Button {
                    onPlayTurns(content.ownerTurns.map(\.id))
                } label: {
                    Label(String(localized: "Play My Turns"), systemImage: "play.circle")
                }
                .disabled(content.ownerTurns.isEmpty || !canPlayTurns)
                .accessibilityIdentifier("meeting-play-owner-turns")
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker(String(localized: "Transcript Filter"), selection: $transcriptFilter) {
                    Text(String(localized: "All")).tag(TranscriptFilter.all)
                    Text(String(localized: "Me")).tag(TranscriptFilter.owner)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("meeting-transcript-filter")

                Button {
                    onPlayTurns(content.ownerTurns.map(\.id))
                } label: {
                    Label(String(localized: "Play My Turns"), systemImage: "play.circle")
                }
                .disabled(content.ownerTurns.isEmpty || !canPlayTurns)
                .accessibilityIdentifier("meeting-play-owner-turns")
            }
        }
    }

    private func transcriptRow(_ turn: TranscriptTurn, content: MeetingResolvedDocument) -> some View {
        let speaker = speaker(for: turn.speakerID, in: content)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(color(for: turn.speakerID))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(speaker.displayName)
                    .font(.subheadline.weight(.semibold))
                if speaker.isOwner {
                    Text(String(localized: "Me"))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.16), in: Capsule())
                        .foregroundStyle(.blue)
                        .accessibilityIdentifier("meeting-speaker-me-badge")
                }
                Spacer()
                Text(timeRange(turn))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(turn.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            glossaryAnnotations(for: turn.text)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button {
                        onPlayTurns([turn.id])
                    } label: {
                        Label(String(localized: "Play"), systemImage: "play.fill")
                    }
                    .disabled(!canPlayTurns)
                    turnSpeakerMenu(turn, content: content)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        onPlayTurns([turn.id])
                    } label: {
                        Label(String(localized: "Play"), systemImage: "play.fill")
                    }
                    .disabled(!canPlayTurns)
                    turnSpeakerMenu(turn, content: content)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color(for: turn.speakerID))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-transcript-turn-\(turn.id)")
    }


    @ViewBuilder
    private func glossaryAnnotations(for text: String) -> some View {
        let substitutions = profile.glossaryDisplaySubstitutions(in: text)
        if !substitutions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(substitutions.prefix(4), id: \.termID) { substitution in
                    Label(String(localized: "Terminology: \(substitution.sourceText) → \(substitution.displayText)"), systemImage: "text.book.closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("meeting-glossary-annotation-\(substitution.termID.uuidString)")
                }
                if substitutions.count > 4 {
                    Text(String(localized: "+\(substitutions.count - 4) more glossary matches"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionsSection(_ content: MeetingResolvedDocument) -> some View {
        MeetingConversationCard {
            ViewThatFits(in: .horizontal) {
                HStack {
                    sectionTitle(String(localized: "Commitments and Requests"), systemImage: "checklist")
                    Spacer()
                    actionFilterPicker
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(String(localized: "Commitments and Requests"), systemImage: "checklist")
                    actionFilterPicker
                }
            }

            let actions = filteredActions(content)
            if actions.isEmpty {
                Text(String(localized: "No commitments or requests match this filter."))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting-actions-empty")
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(actions, id: \.id) { action in
                        actionRow(action, content: content)
                    }
                }
            }
        }
    }

    private var actionFilterPicker: some View {
        Picker(String(localized: "Action Filter"), selection: $actionFilter) {
            Text(String(localized: "All")).tag(ActionFilter.all)
            Text(String(localized: "My")).tag(ActionFilter.mine)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 160)
        .accessibilityIdentifier("meeting-action-filter")
    }

    private func actionRow(_ action: MeetingAction, content: MeetingResolvedDocument) -> some View {
        let status = content.actionStatus(for: action.id)
        let evidence = content.evidenceTurns(for: action.evidenceTurnIDs)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(action.kind == .commitment ? String(localized: "Commitment") : String(localized: "Request"),
                      systemImage: action.kind == .commitment ? "person.badge.clock" : "arrowshape.turn.up.left")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                actionStatusMenu(actionID: action.id, status: status)
            }

            Text(action.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            actionMetadata(action, content: content)
            evidenceStrip(evidence, prefix: "action")
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("meeting-action-\(action.id)")
    }

    private func actionMetadata(_ action: MeetingAction, content: MeetingResolvedDocument) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionMetadataItems(action, content: content) }
            VStack(alignment: .leading, spacing: 6) { actionMetadataItems(action, content: content) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func actionMetadataItems(_ action: MeetingAction, content: MeetingResolvedDocument) -> some View {
        Label(speaker(for: action.actorSpeakerID, in: content).displayName, systemImage: "person")
        if let targetSpeakerID = action.targetSpeakerID {
            Label(speaker(for: targetSpeakerID, in: content).displayName, systemImage: "target")
        }
        if let dueText = action.dueText, !dueText.isEmpty {
            Label(dueText, systemImage: "calendar")
        }
    }

    private func actionStatusMenu(actionID: String, status: MeetingActionStatus) -> some View {
        Menu {
            ForEach(MeetingActionStatus.allUIStatuses, id: \.self) { nextStatus in
                Button {
                    onEdit(.actionStatus, actionID, nextStatus.rawValue)
                } label: {
                    Label(nextStatus.title, systemImage: nextStatus == status ? "checkmark" : nextStatus.systemImage)
                }
                .disabled(!editable)
            }
        } label: {
            Label(status.title, systemImage: status.systemImage)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .accessibilityIdentifier("meeting-action-status-\(actionID)")
    }

    private func questionsSection(_ content: MeetingResolvedDocument) -> some View {
        MeetingConversationCard {
            ViewThatFits(in: .horizontal) {
                HStack {
                    sectionTitle(String(localized: "Questions and Answers"), systemImage: "questionmark.bubble")
                    Spacer()
                    questionFilterPicker
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(String(localized: "Questions and Answers"), systemImage: "questionmark.bubble")
                    questionFilterPicker
                }
            }

            let questions = filteredQuestions(content)
            if questions.isEmpty {
                Text(String(localized: "No questions match this filter."))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting-questions-empty")
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(questions, id: \.id) { question in
                        questionRow(question, content: content)
                    }
                }
            }
        }
    }

    private var questionFilterPicker: some View {
        Picker(String(localized: "Question Filter"), selection: $questionFilter) {
            Text(String(localized: "All")).tag(QuestionFilter.all)
            Text(String(localized: "Unanswered")).tag(QuestionFilter.unanswered)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 220)
        .accessibilityIdentifier("meeting-question-filter")
    }

    private func questionRow(_ question: MeetingQuestion, content: MeetingResolvedDocument) -> some View {
        let questionTurns = content.evidenceTurns(for: question.questionTurnIDs)
        let questionIDs = Set(question.questionTurnIDs)
        let answerTurns = content.evidenceTurns(for: question.answerTurnIDs).filter { !questionIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(question.status.title, systemImage: question.status.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(question.status.tint)
                Spacer()
            }
            Text(question.question)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let answer = question.answer, !answer.isEmpty {
                Text(answer)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(String(localized: "No answer was captured."))
                    .foregroundStyle(.secondary)
            }
            evidenceStrip(questionTurns, prefix: "question")
            if !answerTurns.isEmpty {
                evidenceStrip(answerTurns, prefix: "answer")
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("meeting-question-\(question.id)")
    }

    private func decisionsSection(_ content: MeetingResolvedDocument) -> some View {
        MeetingConversationCard {
            sectionTitle(String(localized: "Decision History"), systemImage: "point.3.connected.trianglepath.dotted")

            let decisions = content.insights?.decisions ?? []
            if decisions.isEmpty {
                Text(String(localized: "No decisions were identified."))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting-decisions-empty")
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(decisions, id: \.id) { decision in
                        decisionRow(decision, content: content)
                    }
                }
            }
        }
    }

    private func decisionRow(_ decision: MeetingDecision, content: MeetingResolvedDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(decision.topic, systemImage: decision.status.systemImage)
                    .font(.headline)
                Spacer()
                Text(decision.status.title)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(decision.steps.enumerated()), id: \.offset) { index, step in
                    decisionStepRow(step, index: index, content: content)
                }
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("meeting-decision-\(decision.id)")
    }

    private func decisionStepRow(_ step: MeetingDecisionStep, index: Int, content: MeetingResolvedDocument) -> some View {
        let evidence = content.evidenceTurns(for: step.evidenceTurnIDs)
        return HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 24, height: 24)
                .background(step.kind.tint.opacity(0.16), in: Circle())
                .foregroundStyle(step.kind.tint)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(step.kind.title)
                        .font(.subheadline.weight(.semibold))
                    Text(speaker(for: step.speakerID, in: content).displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(step.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                evidenceStrip(evidence, prefix: "decision")
            }
        }
        .accessibilityIdentifier("meeting-decision-step-\(index)")
    }

    private func speakersSection(_ content: MeetingResolvedDocument) -> some View {
        MeetingConversationCard {
            sectionTitle(String(localized: "Speaker Correction"), systemImage: "person.2.badge.gearshape")

            if content.transcript.speakers.isEmpty {
                Text(String(localized: "No speaker groups were detected."))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting-speakers-empty")
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(content.transcript.speakers, id: \.id) { speaker in
                        speakerEditor(speaker, content: content)
                    }
                }
            }
        }
    }

    private func speakerEditor(_ speaker: MeetingSpeaker, content: MeetingResolvedDocument) -> some View {
        let turns = content.transcript.turns.filter { $0.speakerID == speaker.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(color(for: speaker.id))
                    .frame(width: 12, height: 12)
                TextField(String(localized: "Speaker Name"), text: bindingForSpeakerName(speaker))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!editable)
                    .onSubmit {
                        saveSpeakerName(speaker)
                    }
                    .accessibilityIdentifier("meeting-speaker-name-\(speaker.id)")
                Button {
                    saveSpeakerName(speaker)
                } label: {
                    Label(String(localized: "Save"), systemImage: "checkmark.circle")
                }
                .disabled(!editable || normalized(speakerNameDrafts[speaker.id] ?? "") == normalized(speaker.name))
                .accessibilityIdentifier("meeting-speaker-save-\(speaker.id)")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { speakerSummaryControls(speaker, turnCount: turns.count) }
                VStack(alignment: .leading, spacing: 8) { speakerSummaryControls(speaker, turnCount: turns.count) }
            }
            if speaker.isOwner {
                Text(ownerDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("meeting-speaker-\(speaker.id)")
    }

    @ViewBuilder
    private func speakerSummaryControls(_ speaker: MeetingSpeaker, turnCount: Int) -> some View {
        Label(String(localized: "\(turnCount) turns"), systemImage: "quote.bubble")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button {
            onEdit(.speakerOwner, speaker.id, speaker.isOwner ? "false" : "true")
        } label: {
            Label(speaker.isOwner ? String(localized: "Unmark Me") : String(localized: "Mark Me"),
                  systemImage: speaker.isOwner ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.checkmark")
        }
        .disabled(!editable)
        .accessibilityIdentifier("meeting-speaker-owner-\(speaker.id)")
    }

    private func turnSpeakerMenu(_ turn: TranscriptTurn, content: MeetingResolvedDocument) -> some View {
        Menu {
            ForEach(turnSpeakerChoices(content), id: \.id) { speaker in
                Button {
                    onEdit(.turnSpeaker, turn.id, speaker.id)
                } label: {
                    Label(speaker.displayName, systemImage: speaker.id == turn.speakerID ? "checkmark" : "person")
                }
                .disabled(!editable)
            }
            Button {
                onEdit(.turnSpeaker, turn.id, "")
            } label: {
                Label(String(localized: "Unknown Speaker"), systemImage: turn.speakerID == nil ? "checkmark" : "questionmark.circle")
            }
            .disabled(!editable)
        } label: {
            Label(String(localized: "Assign Speaker"), systemImage: "person.line.dotted.person")
        }
        .accessibilityIdentifier("meeting-turn-speaker-\(turn.id)")
    }

    private func evidenceStrip(_ turns: [TranscriptTurn], prefix: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                evidenceButtons(turns, prefix: prefix)
            }
            VStack(alignment: .leading, spacing: 8) {
                evidenceButtons(turns, prefix: prefix)
            }
        }
    }

    @ViewBuilder
    private func evidenceButtons(_ turns: [TranscriptTurn], prefix: String) -> some View {
        ForEach(turns.prefix(4), id: \.id) { turn in
            Button {
                onPlayTurns([turn.id])
            } label: {
                Label(timeRange(turn), systemImage: "play.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canPlayTurns)
            .accessibilityIdentifier("meeting-\(prefix)-evidence-\(turn.id)")
        }
        if turns.count > 4 {
            Button {
                onPlayTurns(turns.map(\.id))
            } label: {
                Label(String(localized: "Play All Evidence"), systemImage: "play.rectangle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canPlayTurns)
            .accessibilityIdentifier("meeting-\(prefix)-evidence-all")
        }
    }

    private func projectEditor(_ content: MeetingResolvedDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(String(localized: "Project Name"), text: $projectDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(!editable)
                .onSubmit(saveProjectName)
                .accessibilityIdentifier("meeting-project-name")
            HStack {
                Button {
                    saveProjectName()
                } label: {
                    Label(String(localized: "Save Project"), systemImage: "folder.badge.gearshape")
                }
                .disabled(!editable || normalized(projectDraft) == normalized(content.projectName))
                .accessibilityIdentifier("meeting-project-save")

                Text(String(localized: "Used to connect previous decisions and open items for the same project."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .accessibilityIdentifier("meeting-section-title")
    }

    private func filteredTurns(_ content: MeetingResolvedDocument) -> [TranscriptTurn] {
        switch transcriptFilter {
        case .all:
            return content.transcript.turns
        case .owner:
            return content.ownerTurns
        }
    }

    private func filteredActions(_ content: MeetingResolvedDocument) -> [MeetingAction] {
        guard let insights = content.insights else { return [] }
        switch actionFilter {
        case .all:
            return insights.actions
        case .mine:
            let ids = Set((content.myCommitments + content.receivedRequests).map(\.id))
            return insights.actions.filter { ids.contains($0.id) }
        }
    }

    private func filteredQuestions(_ content: MeetingResolvedDocument) -> [MeetingQuestion] {
        guard let insights = content.insights else { return [] }
        switch questionFilter {
        case .all:
            return insights.questions
        case .unanswered:
            return insights.questions.filter { $0.status == .unanswered || $0.status == .uncertain }
        }
    }

    private func speaker(for id: String?, in content: MeetingResolvedDocument) -> SpeakerDisplay {
        guard let id,
              let speaker = content.transcript.speakers.first(where: { $0.id == id }) else {
            return SpeakerDisplay(id: id ?? "unknown", displayName: String(localized: "Unknown Speaker"), isOwner: false)
        }
        return SpeakerDisplay(id: speaker.id, displayName: speaker.name, isOwner: speaker.isOwner)
    }

    private func turnSpeakerChoices(_ content: MeetingResolvedDocument) -> [SpeakerDisplay] {
        var choices = content.transcript.speakers.map {
            SpeakerDisplay(id: $0.id, displayName: $0.isOwner ? "\($0.name) (\(String(localized: "Me")))" : $0.name, isOwner: $0.isOwner)
        }
        let ownerID = content.transcript.speakers.first(where: \.isOwner)?.id ?? "owner"
        if !choices.contains(where: { $0.id == ownerID }) {
            choices.insert(SpeakerDisplay(id: ownerID, displayName: ownerDescription, isOwner: true), at: 0)
        }
        return choices
    }

    private func bindingForSpeakerName(_ speaker: MeetingSpeaker) -> Binding<String> {
        Binding(
            get: { speakerNameDrafts[speaker.id] ?? speaker.name },
            set: { speakerNameDrafts[speaker.id] = $0 }
        )
    }

    private func saveProjectName() {
        onEdit(.projectName, "", String(projectDraft.prefix(256)))
    }

    private func saveSpeakerName(_ speaker: MeetingSpeaker) {
        let value = speakerNameDrafts[speaker.id] ?? speaker.name
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onEdit(.speakerName, speaker.id, String(trimmed.prefix(256)))
    }



    private func prepareInitialState() {
        if !appliedInitialSection {
            selectedTab = initialSection
            appliedInitialSection = true
        }
        refreshDrafts()
    }

    private func resetTranscriptPaging() {
        visibleTurnLimit = 100
    }

    private func refreshDrafts() {
        projectDraft = content?.projectName ?? ""
        refreshSpeakerDrafts()
    }

    private func refreshSpeakerDrafts() {
        guard let content else {
            speakerNameDrafts = [:]
            return
        }
        speakerNameDrafts = Dictionary(uniqueKeysWithValues: content.transcript.speakers.map { ($0.id, $0.name) })
    }

    private func color(for speakerID: String?) -> Color {
        guard let speakerID else { return .secondary.opacity(0.55) }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]
        let total = speakerID.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[abs(total) % palette.count]
    }

    private func timeRange(_ turn: TranscriptTurn) -> String {
        "\(formatTime(turn.start))-\(formatTime(turn.end))"
    }

    private func formatTime(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ownerDescription: String {
        if !profile.displayName.isEmpty {
            return String(localized: "Me: \(profile.displayName)")
        }
        return String(localized: "Me")
    }
}

private struct MeetingConversationCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.meetingCardBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SpeakerDisplay: Equatable {
    let id: String
    let displayName: String
    let isOwner: Bool
}

enum MeetingConversationTab: CaseIterable {
    case transcript
    case actions
    case questions
    case decisions
    case speakers

    var title: String {
        switch self {
        case .transcript: String(localized: "Transcript")
        case .actions: String(localized: "Actions")
        case .questions: String(localized: "Q&A")
        case .decisions: String(localized: "Decisions")
        case .speakers: String(localized: "Speakers")
        }
    }

    var systemImage: String {
        switch self {
        case .transcript: "quote.bubble"
        case .actions: "checklist"
        case .questions: "questionmark.bubble"
        case .decisions: "point.3.connected.trianglepath.dotted"
        case .speakers: "person.2.badge.gearshape"
        }
    }
}

private enum TranscriptFilter {
    case all
    case owner
}

private enum ActionFilter {
    case all
    case mine
}

private enum QuestionFilter {
    case all
    case unanswered
}

private extension MeetingActionStatus {
    static var allUIStatuses: [MeetingActionStatus] { [.open, .done, .dismissed] }

    var title: String {
        switch self {
        case .open: String(localized: "Open")
        case .done: String(localized: "Done")
        case .dismissed: String(localized: "Dismissed")
        }
    }

    var systemImage: String {
        switch self {
        case .open: "circle"
        case .done: "checkmark.circle"
        case .dismissed: "minus.circle"
        }
    }
}

private extension MeetingQuestionStatus {
    var title: String {
        switch self {
        case .answered: String(localized: "Answered")
        case .partial: String(localized: "Partially Answered")
        case .unanswered: String(localized: "Unanswered")
        case .uncertain: String(localized: "Needs Review")
        }
    }

    var systemImage: String {
        switch self {
        case .answered: "checkmark.circle"
        case .partial: "circle.lefthalf.filled"
        case .unanswered: "questionmark.circle"
        case .uncertain: "exclamationmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .answered: .green
        case .partial: .orange
        case .unanswered: .red
        case .uncertain: .orange
        }
    }
}

private extension MeetingDecisionStatus {
    var title: String {
        switch self {
        case .decided: String(localized: "Decided")
        case .deferred: String(localized: "Deferred")
        case .unresolved: String(localized: "Unresolved")
        }
    }

    var systemImage: String {
        switch self {
        case .decided: "checkmark.seal"
        case .deferred: "clock"
        case .unresolved: "questionmark.diamond"
        }
    }
}

private extension MeetingDecisionStepKind {
    var title: String {
        switch self {
        case .proposal: String(localized: "Proposal")
        case .concern: String(localized: "Concern")
        case .decision: String(localized: "Decision")
        case .deferred: String(localized: "Deferred")
        case .revised: String(localized: "Revised")
        }
    }

    var tint: Color {
        switch self {
        case .proposal: .blue
        case .concern: .orange
        case .decision: .green
        case .deferred: .secondary
        case .revised: .purple
        }
    }
}

private extension Color {
    static var meetingBackground: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .systemGroupedBackground)
#endif
    }

    static var meetingCardBackground: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(uiColor: .secondarySystemGroupedBackground)
#endif
    }
}
