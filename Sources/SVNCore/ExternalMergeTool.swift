import Foundation

/// Known command-line contracts; paths remain individual arguments, never shell text.
public enum ExternalMergeTool: String, CaseIterable, Identifiable, Sendable {
    case idea, vscode, beyondCompare, kaleidoscope, kdiff3, fileMerge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idea: "IntelliJ IDEA"
        case .vscode: "Visual Studio Code"
        case .beyondCompare: "Beyond Compare"
        case .kaleidoscope: "Kaleidoscope"
        case .kdiff3: "KDiff3"
        case .fileMerge: "FileMerge（Xcode）"
        }
    }

    public var applicationName: String {
        switch self {
        case .idea: "IntelliJ IDEA.app"
        case .vscode: "Visual Studio Code.app"
        case .beyondCompare: "Beyond Compare.app"
        case .kaleidoscope: "Kaleidoscope.app"
        case .kdiff3: "kdiff3.app"
        case .fileMerge: "Xcode.app"
        }
    }

    public var executableInApplication: String {
        switch self {
        case .idea: "Contents/MacOS/idea"
        case .vscode: "Contents/Resources/app/bin/code"
        case .beyondCompare: "Contents/MacOS/bcomp"
        case .kaleidoscope: "Contents/MacOS/ksdiff"
        case .kdiff3: "Contents/MacOS/kdiff3"
        case .fileMerge: "Contents/Developer/usr/bin/opendiff"
        }
    }

    public func discoverExecutable() -> URL? {
        let directories = [URL(fileURLWithPath: "/Applications"),
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return directories.map {
            $0.appendingPathComponent(applicationName).appendingPathComponent(executableInApplication)
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Accept an application bundle or its CLI launcher, including nonstandard installations.
    public func executableURL(for path: String) throws -> URL {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw SVNError("请选择 \(title) 应用或填写完整的命令行工具路径。")
        }
        var url = URL(fileURLWithPath: expanded).standardizedFileURL
        if url.pathExtension.lowercased() == "app" {
            url.appendPathComponent(executableInApplication)
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              !directory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw SVNError("未找到 \(title) 的可执行工具，请检查安装位置。")
        }
        return url
    }

    public func arguments(for files: ExternalMergeFiles) -> [String] {
        let local = files.local.path
        let incoming = files.incoming.path
        let base = files.base.path
        let output = files.working.path
        switch self {
        case .idea:
            return ["merge", local, incoming, base, output]
        case .vscode:
            return ["--wait", "--merge", local, incoming, base, output]
        case .beyondCompare:
            return [local, incoming, base, output]
        case .kaleidoscope:
            return ["--merge", "--output", output, "--base", base, "--", local, incoming]
        case .kdiff3:
            return [base, local, incoming, "-o", output]
        case .fileMerge:
            return [local, incoming, "-ancestor", base, "-merge", output]
        }
    }
}

public struct ExternalMergeFiles: Sendable {
    public let base: URL
    public let local: URL
    public let incoming: URL
    public let working: URL
}

extension SVNClient {
    /// Reload the conflict identity before exposing its files to an external editor.
    public func externalMergeFiles(_ details: ConflictDetails) async throws -> ExternalMergeFiles {
        let current = try await conflictDetails(path: details.entry.path, at: details.root)
        guard current.canMarkResolved, current.entry == details.entry,
              current.metadataDigest == details.metadataDigest else {
            throw SVNError("冲突状态已变化，或包含属性／树冲突，请重新读取详情。")
        }
        func file(_ id: String) throws -> URL {
            guard let file = current.files.first(where: { $0.id == id }) else {
                throw SVNError("该冲突缺少三方合并所需的版本文件，请重新读取详情。")
            }
            _ = try conflictFileContent(file, at: details.root)
            return file.url
        }
        return try ExternalMergeFiles(base: file("prev-base-file"), local: file("prev-wc-file"),
                                      incoming: file("cur-base-file"), working: file("working"))
    }
}
