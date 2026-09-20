import Foundation
import Testing
@testable import SVNCore

struct FinderConfigurationTests {
    @Test func preservesConfigurationAndSupportsDisablingAllRoots() throws {
        let value = FinderConfiguration(roots: ["/tmp/中文 空格@副本"], language: "en")
        #expect(try FinderConfiguration.decode(value.encoded()) == value)
        let disabled = FinderConfiguration(roots: [], language: "zh-Hans")
        #expect(try FinderConfiguration.decode(disabled.encoded()).roots.isEmpty)
    }

    @Test func rejectsInvalidDirectoryAndLanguage() throws {
        for value in [
            FinderConfiguration(roots: ["relative"], language: "en"),
            FinderConfiguration(roots: ["/tmp/\0name"], language: "en"),
            FinderConfiguration(roots: [], language: "unsupported")
        ] {
            #expect(throws: (any Error).self) { try FinderConfiguration.decode(value.encoded()) }
        }
    }
}
