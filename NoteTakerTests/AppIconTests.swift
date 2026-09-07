import Foundation
import Testing

@Suite
struct AppIconTests {
    @Test("project declares the AppIcon asset catalog name")
    func projectDeclaresAppIconAssetCatalogName() throws {
        let projectYAML = try String(contentsOf: repositoryRoot.appending(path: "project.yml"), encoding: .utf8)

        #expect(projectYAML.contains("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon"))
    }

    @Test("AppIcon set contains every macOS representation declared in Contents.json")
    func appIconSetContainsEveryMacOSRepresentation() throws {
        let iconSet = repositoryRoot
            .appending(path: "NoteTaker/Resources/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)
        let contentsURL = iconSet.appending(path: "Contents.json")
        let data = try Data(contentsOf: contentsURL)
        let contents = try JSONDecoder().decode(AppIconContents.self, from: data)
        let expected = Set([
            "16x16@1x", "16x16@2x",
            "32x32@1x", "32x32@2x",
            "128x128@1x", "128x128@2x",
            "256x256@1x", "256x256@2x",
            "512x512@1x", "512x512@2x"
        ])

        #expect(Set(contents.images.map { "\($0.size)@\($0.scale)" }) == expected)

        for image in contents.images {
            let filename = try #require(image.filename)
            let imageURL = iconSet.appending(path: filename)
            let attributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
            let fileSize = try #require(attributes[.size] as? Int)

            #expect(fileSize > 0)
        }
    }
}

private struct AppIconContents: Decodable {
    let images: [AppIconImage]
}

private struct AppIconImage: Decodable {
    let filename: String?
    let scale: String
    let size: String
}

private var repositoryRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
