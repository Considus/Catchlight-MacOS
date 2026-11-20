import XCTest

/// The Mac ships the Cobalt app icon, the Art Director's Icon Composer file from Catchlight-iOS,
/// and only that one: a Mac app can't switch its icon as the iPhone's App icon row does. The tests
/// don't load into the app, so they check what the build reads: the file and the project setting.
final class AppIconTests: XCTestCase {
    private let repo = WebViewHarness.repoUI.deletingLastPathComponent()

    func testTheCobaltIconComposerFileIsThere() throws {
        let icon = repo.appendingPathComponent("App/Resources/AppIcon.icon")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: icon.appendingPathComponent("icon.json"))) as? [String: Any])
        let fills = try XCTUnwrap(json["fill-specializations"] as? [[String: Any]])
        let light = try XCTUnwrap(fills.first { $0["appearance"] == nil }?["value"] as? [String: String])
        XCTAssertEqual(light["solid"], "srgb:0.17255,0.25490,0.90980,1.00000", "Cobalt's blue, #2C41E8")
        for layer in ["ring.svg", "dot.svg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: icon.appendingPathComponent("Assets/\(layer)").path), layer)
        }
    }

    func testTheAppTargetUsesItAndNoAlternates() throws {
        let project = try String(contentsOf: repo.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon"))
        XCTAssertTrue(project.contains("- path: App/Resources/AppIcon.icon"))
        XCTAssertFalse(project.contains("ALTERNATE_APPICON"), "the Mac has no alternate icons")
    }
}
