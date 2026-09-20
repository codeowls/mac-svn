import Foundation
import Testing
@testable import SVNCore

struct LocalizationTests {
    @Test func loadsBothSupportedLanguages() {
        let chinese = L10n.resourceBundle(for: .chinese)
        let english = L10n.resourceBundle(for: .english)
        #expect(chinese.localizedString(forKey: "关闭", value: nil, table: nil) == "关闭")
        #expect(english.localizedString(forKey: "关闭", value: nil, table: nil) == "Close")
    }
}
