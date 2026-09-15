# Windows 0.2 · Apple component adaptation

2026-09-14. The user requested the Apple app's UI/UX and components on Windows. This change uses the existing SwiftUI views as the component specification and implements their supported workflows in WPF.

## Component mapping

| Existing Apple source | Windows implementation |
| --- | --- |
| `NoteTaker/App/RootView.swift` | Split workspace; 260 DIP sidebar; mutually exclusive empty, playback and recording detail states |
| `NoteTaker/Sidebar/SidebarView.swift` | Search field; all/favorite/deleted navigation with counts; compact recording rows; bottom recording control |
| `NoteTaker/Sidebar/RecordingRow.swift` | 12pt semibold title, 10pt metadata, blue selection and white selected text; context actions |
| `NoteTaker/Recording/RecordButton.swift` | 72 DIP hit area, 64 DIP surround, 58 DIP ring, 52 DIP red center; mode/device popover beneath the button or on right-click |
| `NoteTaker/Recording/RecordingView.swift` | Centered 17pt heading and 31pt monospaced timer; per-source red input rails; pause, resume and done controls |
| `NoteTaker/Playback/PlaybackDetailView.swift` | Centered title/date/mode, actual audio waveform, overview, transport and bottom actions |
| `NoteTaker/Playback/WaveformView.swift` | 148 DIP primary waveform and 30 DIP overview, bounded timeline marks, blue playhead, click/drag and keyboard seeking |
| `NoteTaker/Playback/TransportControls.swift` | 44 DIP circular targets, play/pause, backward/forward 15 seconds |
| `NoteTaker/AI/RecordingDetailTabsView.swift` | Segmented audio / AI notes selection; notes / transcript segmented selection |
| `NoteTaker/AI/AISettingsView.swift` | Grouped notice, API key, models and output-language cards |

Shared definitions live in `Windows/NoteTaker.Windows/Components/AppleTheme.xaml`. It defines buttons, focus rings, search/text/password fields, pop-up pickers, segmented tabs, list selection, checkboxes, progress rails, scrollbars, menus and tooltips. `AppleIcon` uses original vector paths rather than a required external symbol font. `WindowControls` maps the three round window controls to actual Windows close/minimize/maximize commands. WindowChrome retains dragging, resizing and Windows keyboard window commands.

Light/dark palettes follow the Windows application appearance and update in response to preference changes. High-contrast palettes map core foreground/background/selection brushes to Windows system brushes. SF Pro and SF Symbols are not bundled; installed Windows system fonts are used. No SwiftUI/CoreAudio runtime or macOS materials run on Windows.

## Behavior and implementation details

- Waveforms are sampled from the actual local audio on a background task, with bounded peak storage, cancellation and recording-identity checks. A failed load displays a reload action. No fabricated waveform is shown for a missing file.
- Both waveforms seek the same audio player. A range-value automation peer exposes waveform position to accessibility clients. Playback-device initialization is deferred until play, so seeking remains available without an output device.
- Ctrl+N/O/F/comma and Space cover common app actions. Text entry, focused buttons, tabs and popovers retain their own keyboard behavior.
- Recording mode controls disable the irrelevant device picker. During recording, the sidebar start control and mode picker are disabled, and the dedicated recording state replaces saved-note views.
- Input meters, pause/resume button enabled states, finishing state, saved library row and return to playback were verified through the real WPF event handlers.
- The note renderer retains text-only Markdown behavior and updates its text color with the appearance. Tab header weight is scoped to the header so it does not make the document content bold.

## Verification

- 32 automated core tests pass, including new waveform amplitude/silence boundaries, cancellation and seek clamping. Device-dependent cases are opt-in.
- `Windows/build.ps1 audio-smoke`: all 5 real-device tests pass, including microphone, loopback, mixed recording and player pause/resume. The test tone renderer is initialized after capture starts, because opening a Bluetooth microphone may change its audio profile; see [Microsoft's Bluetooth Classic audio documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/bluetooth/bluetooth-classic-audio).
- `Windows/build.ps1 smoke-ui`: empty library, playback, meeting notes, recording-state fixture, capture popover, minimum window size (840×600), and light/dark settings are rendered. Favorite, delete/restore, search, real fixture waveform loading, waveform seeking, 15-second transport, mode gating and graceful close are exercised.
- `Windows/build.ps1 ui-audio-smoke`: real microphone/system devices through the WPF record → pause → resume → done flow; finalized WAV, duration and return to playback verified. Test recording is removed afterward.
- Release and self-contained x64 package are rebuilt under `Windows/artifacts/0.2.0/win-x64/`; packaged smoke mode is used for the final executable verification.
- Visual evidence is generated under `Windows/artifacts/ui-smoke/`, `Windows/artifacts/ui-audio-smoke/` and the packaged smoke output directory. Screenshots contain generated/example content. They are layout evidence, not a real AI output claim.

## Boundaries

This is a source-based reconstruction of the Apple components, not a pixel comparison against a running macOS 26 app. Windows typography, window materials and system file dialogs differ. Folder sync, meeting analysis, local speaker identity and paused-recording preview playback remain outside the existing Windows feature scope; their inactive UI is not presented as working. No actual paid AI provider call or Mac/iPhone regression suite was run for this UI change.
