import SwiftUI

struct MeetingBriefingView: View {
    let sources: [MeetingBriefingSource]
    var initialProject: String? = nil
    let onOpen: (UUID, [String]) -> Void
    @State private var project = ""
    @Environment(\.dismiss) private var dismiss

    private var projects: [String] {
        Array(Set(sources.map { $0.resolvedDocument.projectName }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(String(localized: "Prepare for the Next Meeting"), systemImage: "calendar.badge.clock")
                        .font(.title2.bold())
                    Text(String(localized: "Review prior decisions, open commitments, and unanswered questions with links to the original meeting."))
                        .foregroundStyle(.secondary)
                    if projects.isEmpty {
                        ContentUnavailableView(String(localized: "No Project Meetings Yet"), systemImage: "folder",
                            description: Text(String(localized: "Analyze a recording and assign a project to start building meeting briefings.")))
                    } else {
                        Picker(String(localized: "Project"), selection: $project) {
                            Text(String(localized: "Choose a project")).tag("")
                            ForEach(projects, id: \.self) { Text($0).tag($0) }
                        }
                        .accessibilityIdentifier("briefing-project")
                        if !project.isEmpty {
                            let briefing = MeetingBriefingBuilder.build(projectName: project, sources: sources)
                            section("Recent Decisions", items: briefing.decisions, icon: "checkmark.seal")
                            section("Open Actions", items: briefing.openActions, icon: "checklist")
                            section("Unanswered Questions", items: briefing.unansweredQuestions, icon: "questionmark.bubble")
                        }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(String(localized: "Meeting Briefing"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Close")) { dismiss() } }
            }
        }
        .frame(minWidth: 300, minHeight: 420)
        .onAppear(perform: chooseDefaultProjectIfNeeded)
        .onChange(of: projects) { _, _ in chooseDefaultProjectIfNeeded() }
    }


    private func chooseDefaultProjectIfNeeded() {
        if projects.contains(project) { return }
        let requested = initialProject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if projects.contains(requested) {
            project = requested
        } else if projects.count == 1 {
            project = projects[0]
        } else {
            project = ""
        }
    }

    private func section(_ title: String, items: [MeetingBriefingItem], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizedStringKey(title), systemImage: icon).font(.headline)
            if items.isEmpty { Text(String(localized: "Nothing to review here.")).foregroundStyle(.secondary) }
            ForEach(items, id: \.id) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.text).fixedSize(horizontal: false, vertical: true)
                    Button { onOpen(item.recordingID, item.turnIDs); dismiss() } label: {
                        Label(item.recordingTitle, systemImage: "arrow.up.forward.app")
                            .font(.caption)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
