import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selectedRecordingID: UUID?
    var selectedFolder: RecordingFolder = .all
    var searchText = ""
    var searchFocusRequestID = 0
    var searchBlurRequestID = 0
    var isSplitViewVisible = true
    var isEditingText = false
}
