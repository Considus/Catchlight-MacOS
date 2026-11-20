import XCTest

/// A check on the tests themselves. WebKit snaps a border's width down to whole device pixels, and
/// the CI Mac has a 1x display, so a test that expects a computed border of "1.5px" passes on a
/// Retina Mac and fails on CI (slice 4's Cancel square, slice 5's confirm slots). SVG strokes are
/// not snapped, so only borders and edges are checked.
final class HalfPixelBorderLintTests: XCTestCase {
    func testNoBorderAssertionExpectsAHalfPixelWithoutThePixelRatio() throws {
        let dir = WebViewHarness.repoUI.deletingLastPathComponent().appendingPathComponent("App/Tests")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "found the test files")
        let halfPixel = try NSRegularExpression(pattern: #""\d+\.5px"#)
        var bad: [String] = []
        for file in files where file.lastPathComponent != "HalfPixelBorderLintTests.swift" {
            for (n, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard halfPixel.firstMatch(in: line, range: range) != nil,
                      line.range(of: #"edge|border"#, options: [.regularExpression, .caseInsensitive]) != nil,
                      line.range(of: "dpr|devicePixelRatio|snapped", options: .regularExpression) == nil else { continue }
                bad.append("\(file.lastPathComponent):\(n + 1)")
            }
        }
        XCTAssertEqual(bad, [], """
            These assert a half-pixel border, which the 1x CI Mac draws a pixel thinner. Read
            devicePixelRatio in the page and expect floor(width × dpr) / dpr, as
            EditorBarLookTests and OnboardingLookTests do.
            """)
    }
}
