import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Discovered Plex server with connection info.
struct PlexServer: Identifiable, Sendable {
    let id: String          // clientIdentifier
    let name: String        // friendly name
    let connections: [PlexConnection]

    /// Best available connection URI (prefer local, then relay).
    var bestURI: String? {
        // Prefer non-relay local connections first
        let local = connections.first { !$0.relay && $0.local }
        let direct = connections.first { !$0.relay }
        let any = connections.first
        return (local ?? direct ?? any)?.uri
    }
}

struct PlexConnection: Sendable {
    let uri: String
    let local: Bool
    let relay: Bool
}

/// Handles the Plex PIN-based OAuth flow and server discovery.
/// All methods are async and run on the caller's context.
@MainActor
class PlexAuth: ObservableObject {
    @Published var state: AuthState = .idle
    @Published var servers: [PlexServer] = []
    @Published var error: String?

    enum AuthState: Equatable {
        case idle
        case waitingForBrowser  // PIN created, browser opened
        case polling            // Polling for token
        case discoveringServers // Token obtained, fetching servers
        case done               // Servers discovered
        case failed
    }

    private var authToken: String?
    private var pinId: Int?
    private let clientId: String

    private static let plexTVBase = "https://plex.tv/api/v2"

    init() {
        // Persistent client ID across sessions
        let key = "plexClientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            clientId = existing
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: key)
            clientId = newId
        }
    }

    /// The obtained auth token (available after state == .done).
    var token: String? { authToken }

    // MARK: - Public API

    /// Start the full PIN auth flow: create PIN, open browser, poll, discover.
    func startAuth() {
        state = .idle
        error = nil
        authToken = nil
        servers = []

        Task {
            do {
                // Step 1: Create PIN
                let (id, code) = try await createPin()
                pinId = id

                // Step 2: Open browser
                var components = URLComponents(string: "https://app.plex.tv/auth")!
                components.fragment = "?" + [
                    "clientID=\(clientId)",
                    "code=\(code)",
                    "context[device][product]=PlaiY",
                    "context[device][version]=1.0",
                    "context[device][platform]=\(platformName)",
                ].joined(separator: "&")
                openURL(components.string!)
                state = .waitingForBrowser

                // Step 3: Poll for token
                state = .polling
                let token = try await pollForToken(pinId: id)
                authToken = token

                // Step 4: Discover servers
                state = .discoveringServers
                servers = try await discoverServers(token: token)
                state = .done
            } catch is CancellationError {
                // User cancelled
                state = .idle
            } catch {
                self.error = error.localizedDescription
                state = .failed
            }
        }
    }

    func cancel() {
        state = .idle
        error = nil
    }

    // MARK: - PIN Creation

    private func createPin() async throws -> (id: Int, code: String) {
        var request = URLRequest(url: URL(string: "\(Self.plexTVBase)/pins?strong=true")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyPlexHeaders(&request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw PlexAuthError.pinCreationFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? Int,
              let code = json?["code"] as? String else {
            throw PlexAuthError.pinCreationFailed
        }

        return (id, code)
    }

    // MARK: - Polling

    private func pollForToken(pinId: Int) async throws -> String {
        let url = URL(string: "\(Self.plexTVBase)/pins/\(pinId)")!
        let maxAttempts = 120 // 2 minutes at 1s intervals
        for _ in 0..<maxAttempts {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            applyPlexHeaders(&request)

            let (data, _) = try await session.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let token = json?["authToken"] as? String, !token.isEmpty {
                return token
            }
        }
        throw PlexAuthError.timeout
    }

    // MARK: - Server Discovery

    private func discoverServers(token: String) async throws -> [PlexServer] {
        var request = URLRequest(url: URL(string: "\(Self.plexTVBase)/resources?includeHttps=1&includeRelay=1")!)
        applyPlexHeaders(&request)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PlexAuthError.serverDiscoveryFailed
        }

        guard let resources = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PlexAuthError.serverDiscoveryFailed
        }

        var servers: [PlexServer] = []
        for resource in resources {
            guard let provides = resource["provides"] as? String,
                  provides.contains("server") else { continue }

            let name = resource["name"] as? String ?? "Unknown Server"
            let clientId = resource["clientIdentifier"] as? String ?? UUID().uuidString
            let conns = resource["connections"] as? [[String: Any]] ?? []

            let connections = conns.compactMap { conn -> PlexConnection? in
                guard let uri = conn["uri"] as? String else { return nil }
                let local = conn["local"] as? Bool ?? false
                let relay = conn["relay"] as? Bool ?? false
                return PlexConnection(uri: uri, local: local, relay: relay)
            }

            if !connections.isEmpty {
                servers.append(PlexServer(id: clientId, name: name, connections: connections))
            }
        }

        return servers
    }

    // MARK: - Helpers

    private func applyPlexHeaders(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientId, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("PlaiY", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("1.0", forHTTPHeaderField: "X-Plex-Version")
        request.setValue(platformName, forHTTPHeaderField: "X-Plex-Platform")
    }

    private var platformName: String {
        #if os(macOS)
        "macOS"
        #elseif os(tvOS)
        "tvOS"
        #else
        "iOS"
        #endif
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
}

enum PlexAuthError: LocalizedError {
    case pinCreationFailed
    case timeout
    case serverDiscoveryFailed

    var errorDescription: String? {
        switch self {
        case .pinCreationFailed: "Failed to create Plex authentication PIN"
        case .timeout: "Authentication timed out -- sign in was not completed in the browser"
        case .serverDiscoveryFailed: "Failed to discover Plex servers"
        }
    }
}
