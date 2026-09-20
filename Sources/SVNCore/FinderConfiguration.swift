import Foundation

/// Non-sensitive menu configuration only. Messages never authorize file access or SVN writes.
public struct FinderConfiguration: Codable, Sendable, Equatable {
    public static let changed = Notification.Name("io.github.codeowls.mac-svn.finder.configuration")
    public static let requested = Notification.Name("io.github.codeowls.mac-svn.finder.request-configuration")
    public static let applied = Notification.Name("io.github.codeowls.mac-svn.finder.configuration-applied")
    public let roots: [String]
    public let language: String

    public init(roots: [String], language: String) {
        self.roots = roots
        self.language = language
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static func decode(_ value: String) throws -> FinderConfiguration {
        let configuration = try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        guard configuration.roots.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              ["en", "zh-Hans"].contains(configuration.language) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return configuration
    }
}
