import ArgumentParser
import Foundation
import Testing
@testable import xcinfo

struct ReadmeTests {
    private static let readme = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("README.md")

    @Test(arguments: XCInfo.configuration.subcommands.map { $0._commandName })
    func `the readme names every option of each subcommand`(name: String) throws {
        let readme = try String(contentsOf: Self.readme, encoding: .utf8)
        let help = try XCInfo.helpMessage(for: #require(XCInfo.configuration.subcommands.first { $0._commandName == name }), columns: 200)
        let options = Set(help.matches(of: /(^|[\s\[,\/])(--[a-z][a-z-]*)/.anchorsMatchLineEndings()).map { String($0.output.2) })
            .subtracting(["--help", "--version"])

        #expect(readme.contains("### \(name)") || readme.contains("`\(name)`"))
        for option in options.sorted() {
            #expect(readme.contains(option), "\(name) \(option)")
        }
    }
}
