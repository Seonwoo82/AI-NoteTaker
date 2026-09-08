#if os(macOS)
import AppKit
import SwiftUI
import Testing

#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite
struct OutlineSnapshotTests {
  @Test("meeting notes outline renders deterministic visual QA snapshots")
  func meetingNotesOutlineRendersDeterministicVisualQASnapshots() throws {
    let outputDirectory =
      outlineSnapshotRepositoryRoot
      .appending(path: "build/outline-visual-qa", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let document = MarkdownDocument(outlineSource)
    let headings = document.outlineHeadings
    let selectedHeading = try #require(headings.first { $0.text == "결정 사항 **정리**" })

    #expect(headings.count == 8)
    #expect(Set(headings.map(\.text)).count < headings.count)

    for snapshotCase in SnapshotCase.allCases {
      let url = outputDirectory.appending(path: "\(snapshotCase.name).png")
      let image = try renderOutline(
        headings: headings,
        selectedBlockIndex: selectedHeading.blockIndex,
        colorScheme: snapshotCase.colorScheme,
        width: snapshotCase.width,
        height: 550,
        to: url
      )

      #expect(imageMatchesPointSize(image, width: snapshotCase.width, height: 550))
      #expect(try pngSize(at: url) > snapshotCase.minimumPNGSize)
      #expect(imageContainsVisibleContent(image))
    }
  }

  private func renderOutline(
    headings: [MarkdownDocument.Heading],
    selectedBlockIndex: Int,
    colorScheme: ColorScheme,
    width: Int,
    height: Int,
    to url: URL
  ) throws -> NSBitmapImageRep {
    let rootView = MeetingNotesOutline(
      headings: headings,
      selectedBlockIndex: selectedBlockIndex,
      onSelect: { _ in }
    )
    .environment(\.colorScheme, colorScheme)
    .padding(16)
    .frame(width: CGFloat(width), height: CGFloat(height), alignment: .top)
    .background(Color(nsColor: .windowBackgroundColor))

    let hostingView = NSHostingView(rootView: rootView)
    let size = NSSize(width: CGFloat(width), height: CGFloat(height))
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.wantsLayer = true

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    window.contentView = hostingView
    defer {
      window.contentView = nil
      window.close()
    }

    hostingView.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    else {
      throw SnapshotError.couldNotCreateBitmap
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
    guard let png = representation.representation(using: .png, properties: [:]) else {
      throw SnapshotError.couldNotEncodePNG
    }
    try png.write(to: url, options: .atomic)
    return representation
  }
}

private struct SnapshotCase {
  let name: String
  let colorScheme: ColorScheme
  let width: Int
  let minimumPNGSize: Int

  static let allCases: [SnapshotCase] = [
    SnapshotCase(
      name: "outline-light-narrow", colorScheme: .light, width: 340, minimumPNGSize: 14_000),
    SnapshotCase(
      name: "outline-dark-narrow", colorScheme: .dark, width: 340, minimumPNGSize: 14_000),
    SnapshotCase(
      name: "outline-light-wide", colorScheme: .light, width: 680, minimumPNGSize: 18_000),
    SnapshotCase(name: "outline-dark-wide", colorScheme: .dark, width: 680, minimumPNGSize: 18_000),
  ]
}

private enum SnapshotError: Error {
  case couldNotCreateBitmap
  case couldNotEncodePNG
}

private let outlineSource = """
  # 주간 회의

  ## 시작 인사와 오늘 다룰 흐름
  첫 문단입니다.

  ## 결정 사항 **정리**
  선택된 항목입니다.

  ## 실행 계획 검토 및 부서별 다음 단계 조율
  긴 제목 줄바꿈을 확인합니다.

  ## 고객 피드백 공유
  메모입니다.

  ## 결정 사항 **정리**
  중복 제목입니다.

  ## 일정 위험 요소와 대응 방안
  메모입니다.

  ## 예산 변경 검토
  메모입니다.

  ## 마무리 질문과 후속 확인
  메모입니다.
  """

private var outlineSnapshotRepositoryRoot: URL {
  URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private func pngSize(at url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require(attributes[FileAttributeKey.size] as? Int)
}

private func imageContainsVisibleContent(_ image: NSBitmapImageRep) -> Bool {
  var distinctColors = Set<Int>()
  let sampleStride = max(1, image.pixelsWide / 40)

  for x in stride(from: 0, to: image.pixelsWide, by: sampleStride) {
    for y in stride(from: 0, to: image.pixelsHigh, by: sampleStride) {
      guard let color = image.colorAt(x: x, y: y) else { continue }
      distinctColors.insert(colorSignature(color))
      if distinctColors.count >= 8 {
        return true
      }
    }
  }

  return false
}

private func imageMatchesPointSize(_ image: NSBitmapImageRep, width: Int, height: Int) -> Bool {
  image.size.width == CGFloat(width) && image.size.height == CGFloat(height)
    && image.pixelsWide >= width && image.pixelsHigh >= height
}

private func colorSignature(_ color: NSColor) -> Int {
  let converted = color.usingColorSpace(.sRGB) ?? color
  let red = Int((converted.redComponent * 255).rounded())
  let green = Int((converted.greenComponent * 255).rounded())
  let blue = Int((converted.blueComponent * 255).rounded())
  let alpha = Int((converted.alphaComponent * 255).rounded())
  return red << 24 | green << 16 | blue << 8 | alpha
}

#endif
