import Foundation
import SwiftUI
import SVNCore

@MainActor
final class RepositoryBrowserModel: ObservableObject {
    @Published var address = ""
    @Published private(set) var location: RepositoryLocation?
    @Published private(set) var entries: [RepositoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedDirectories: Set<String> = []
    private var history: [String] = []
    private var request: Task<Void, Never>?
    private var requestID = UUID()

    var canGoBack: Bool { !history.isEmpty && !isLoading }
    var checkoutURL: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Editing the address invalidates the listing, so checkout never uses a stale selection.
    func addressChanged() {
        guard location?.url != checkoutURL else { return }
        cancel()
        location = nil
        entries = []
        selectedDirectories = []
        history = []
        errorMessage = nil
    }

    func browse(using client: SVNClient) {
        load(checkoutURL, using: client, previous: nil, goingBack: false)
    }

    func enter(_ entry: RepositoryEntry, using client: SVNClient) {
        guard entry.isDirectory, let location else { return }
        do {
            let url = try SVNClient.childRepositoryURL(parent: location.url, name: entry.name)
            load(url, using: client, previous: location.url, goingBack: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goBack(using client: SVNClient) {
        guard let url = history.last else { return }
        load(url, using: client, previous: nil, goingBack: true)
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func cancel() {
        request?.cancel()
        requestID = UUID()
        isLoading = false
    }

    /// Publish the address and listing together only after both remote reads succeed.
    private func load(_ url: String, using client: SVNClient, previous: String?, goingBack: Bool) {
        cancel()
        selectedDirectories = []
        let id = requestID
        isLoading = true
        errorMessage = nil
        request = Task {
            do {
                let newLocation = try await client.repositoryLocation(url)
                let newEntries = try await client.listRepository(newLocation.url)
                guard !Task.isCancelled, requestID == id else { return }
                if goingBack { history.removeLast() }
                if let previous { history.append(previous) }
                location = newLocation
                entries = newEntries
                address = newLocation.url
                isLoading = false
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}
