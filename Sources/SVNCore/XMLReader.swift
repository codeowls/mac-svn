import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A small XML tree preserves escaped names, multiline log messages and nested SVN elements.
final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { child in
            (child.name == name ? [child] : []) + child.descendants(name)
        }
    }
}

final class XMLReader: NSObject, XMLParserDelegate {
    private var stack: [XMLNode] = []
    private var root: XMLNode?

    static func parse(_ xml: String) throws -> XMLNode {
        let reader = XMLReader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), let root = reader.root else {
            throw SVNError(L10n.text("无法解析 SVN XML：%@", parser.parserError?.localizedDescription ?? L10n.text("缺少根节点")))
        }
        return root
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        stack.removeLast()
    }
}

enum SVNXML {
    static func repositoryInfo(_ xml: String) throws -> RepositoryLocation {
        let root = try XMLReader.parse(xml)
        guard root.name == "info",
              let entry = root.child("entry"),
              entry.attributes["kind"] == "dir",
              let url = entry.child("url")?.text,
              let repositoryRoot = entry.child("repository")?.child("root")?.text,
              let revision = entry.attributes["revision"] else {
            throw SVNError(L10n.text("请选择远端仓库中的目录或分支，不能检出单个文件。"))
        }
        return RepositoryLocation(url: url, rootURL: repositoryRoot, revision: revision)
    }

    static func repositoryEntries(_ xml: String) throws -> [RepositoryEntry] {
        let root = try XMLReader.parse(xml)
        guard root.name == "lists", let list = root.child("list") else {
            throw SVNError(L10n.text("SVN 仓库目录响应格式不正确"))
        }
        return try list.children.filter { $0.name == "entry" }.map { entry in
            guard let name = entry.child("name")?.text,
                  let kind = entry.attributes["kind"], ["dir", "file"].contains(kind) else {
                throw SVNError(L10n.text("SVN 仓库目录响应缺少必要字段"))
            }
            return RepositoryEntry(
                name: name,
                isDirectory: kind == "dir",
                revision: entry.child("commit")?.attributes["revision"] ?? "",
                author: entry.child("commit")?.child("author")?.text ?? ""
            )
        }.sorted { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    static func status(_ xml: String) throws -> [StatusEntry] {
        let root = try XMLReader.parse(xml)
        guard root.name == "status" else { throw SVNError(L10n.text("SVN 状态响应格式不正确")) }
        return try root.descendants("entry").map { node in
            guard let path = node.attributes["path"],
                  let status = node.child("wc-status"),
                  let item = status.attributes["item"],
                  let properties = status.attributes["props"] else {
                throw SVNError(L10n.text("SVN 状态响应缺少必要字段"))
            }
            return StatusEntry(
                path: path,
                item: item,
                properties: properties,
                treeConflict: status.attributes["tree-conflicted"] == "true",
                copied: status.attributes["copied"] == "true"
            )
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func info(_ xml: String) throws -> WorkingCopy {
        let root = try XMLReader.parse(xml)
        guard root.name == "info",
              let entry = root.child("entry"),
              let path = entry.child("wc-info")?.child("wcroot-abspath")?.text,
              let url = entry.child("url")?.text,
              let revision = entry.attributes["revision"] else {
            throw SVNError(L10n.text("所选目录不是有效的 SVN 工作副本"))
        }
        return WorkingCopy(root: URL(fileURLWithPath: path), repositoryURL: url, revision: revision)
    }

    static func log(_ xml: String) throws -> [LogEntry] {
        let root = try XMLReader.parse(xml)
        guard root.name == "log" else { throw SVNError(L10n.text("SVN 历史响应格式不正确")) }
        return try root.children.filter { $0.name == "logentry" }.map { node in
            guard let revision = node.attributes["revision"] else {
                throw SVNError(L10n.text("SVN 历史响应缺少版本号"))
            }
            return LogEntry(
                revision: revision,
                author: node.child("author")?.text ?? L10n.text("（无作者）"),
                date: node.child("date")?.text ?? "",
                message: node.child("msg")?.text ?? "",
                changedPaths: try (node.child("paths")?.children ?? [])
                    .filter { $0.name == "path" }
                    .map { path in
                        guard let action = path.attributes["action"], !path.text.isEmpty else {
                            throw SVNError(L10n.text("SVN 历史变更项缺少路径或操作类型"))
                        }
                        return LogChangedPath(
                            path: path.text,
                            action: action,
                            kind: path.attributes["kind"],
                            copyFromPath: path.attributes["copyfrom-path"],
                            copyFromRevision: path.attributes["copyfrom-rev"],
                            textModified: path.attributes["text-mods"].flatMap(Bool.init),
                            propertiesModified: path.attributes["prop-mods"].flatMap(Bool.init)
                        )
                    }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            )
        }
    }
}
