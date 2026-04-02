import SwiftUI

struct AddSourceView: View {
    @ObservedObject var sourcesVM: SourcesViewModel
    let reconnectSource: SourceConfig?
    let onDismiss: () -> Void

    @State private var sourceType: SourceType = .smb
    @State private var displayName = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var showManualPlex = false
    @FocusState private var focusedField: Field?

    @StateObject private var plexAuth = PlexAuth()
    @State private var selectedServer: PlexServer?

    private enum Field: Hashable {
        case displayName, address, username, password
    }

    init(sourcesVM: SourcesViewModel,
         reconnectSource: SourceConfig? = nil,
         onDismiss: @escaping () -> Void) {
        self.sourcesVM = sourcesVM
        self.reconnectSource = reconnectSource
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            if !isReconnectFlow {
                typePicker
            }

            if sourceType == .plex && !showManualPlex {
                plexOAuthFlow
            } else {
                manualConnectionFields
            }

            Spacer()
            actionButtons
        }
        .onAppear { configureInitialState() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(isReconnectFlow ? "Reconnect Plex" : "Add Source")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button("Cancel") { onDismiss() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.top)
    }

    // MARK: - Type picker

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type")
                .font(.headline)
            Picker("Protocol", selection: $sourceType) {
                ForEach(SourceType.allCases.filter(\.isAvailable), id: \.self) { type in
                    Label(type.displayName, systemImage: type.systemImage)
                        .tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: sourceType) {
                // Reset Plex auth state when switching types
                plexAuth.cancel()
                selectedServer = nil
                showManualPlex = false
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Plex OAuth flow

    private var plexOAuthFlow: some View {
        VStack(spacing: 16) {
            switch plexAuth.state {
            case .idle:
                plexSignInPrompt
            case .waitingForBrowser, .polling:
                plexWaitingView
            case .discoveringServers:
                ProgressView("Discovering servers...")
            case .done:
                plexServerPicker
            case .failed:
                plexErrorView
            }
        }
        .padding(.horizontal)
    }

    private var plexSignInPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Sign in with your Plex account")
                .font(.headline)

            Text("This will open plex.tv in your browser to sign in securely.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                plexAuth.startAuth()
            } label: {
                Label("Sign in with Plex", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button("Enter server details manually instead") {
                showManualPlex = true
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var plexWaitingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Waiting for sign in...")
                .font(.headline)
            Text("Complete the sign in in your browser, then come back here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel") {
                plexAuth.cancel()
            }
            .buttonStyle(.bordered)
        }
    }

    private var plexServerPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Signed in successfully", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)

            if plexAuth.servers.isEmpty {
                Text("No Plex servers found on your account.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a server:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(plexAuth.servers) { server in
                    Button {
                        selectedServer = server
                        // Auto-fill fields
                        displayName = server.name
                        address = server.bestURI ?? ""
                        password = server.accessToken
                        username = ""
                    } label: {
                        HStack {
                            Image(systemName: "server.rack")
                            VStack(alignment: .leading) {
                                Text(server.name)
                                    .fontWeight(.medium)
                                if let uri = server.bestURI {
                                    Text(uri)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if selectedServer?.id == server.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedServer?.id == server.id
                                      ? Color.accentColor.opacity(0.1)
                                      : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var plexErrorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.red)
            Text(plexAuth.error ?? "Authentication failed")
                .foregroundStyle(.secondary)
            HStack {
                Button("Try Again") {
                    plexAuth.startAuth()
                }
                .buttonStyle(.borderedProminent)
                Button("Enter manually") {
                    showManualPlex = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Manual connection fields

    private var manualConnectionFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    TextField("My NAS", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .displayName)
                }
                GridRow {
                    Text("Address")
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    TextField(addressPlaceholder, text: $address)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .address)
                }
                if showsUsernameField {
                    GridRow {
                        Text("Username")
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        TextField("Optional", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .username)
                    }
                }
                if showsCredentialsFields {
                    GridRow {
                        Text(sourceType == .plex ? "Token" : "Password")
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        SecureField(sourceType == .plex ? "X-Plex-Token" : "Optional",
                                    text: $password)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .password)
                    }
                }
                if sourceType == .plex && showManualPlex {
                    GridRow {
                        Spacer()
                            .frame(width: 80)
                        Text("Enter your Plex server URL and X-Plex-Token.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if sourceType == .http || sourceType == .nfs {
                    GridRow {
                        Spacer()
                            .frame(width: 80)
                        Text("Use a direct media URL. These sources expose a single playable item instead of remote folder browsing.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack {
            if sourceType != .plex || showManualPlex {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(address.isEmpty || isTesting)

                if isTesting {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("Success") ? .green : .red)
                }
            }

            Spacer()

            Button(isReconnectFlow ? "Reconnect" : "Save") {
                saveSource()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding()
    }

    private var canSave: Bool {
        if sourceType == .plex && !showManualPlex {
            return selectedServer != nil
        }
        if sourceType == .plex {
            return !address.isEmpty && !displayName.isEmpty && persistedAuthToken != nil
        }
        return !address.isEmpty && !displayName.isEmpty
    }

    // MARK: - Helpers

    private var showsCredentialsFields: Bool {
        if sourceType == .plex {
            return showManualPlex
        }
        return sourceType != .http && sourceType != .nfs
    }

    private var showsUsernameField: Bool {
        showsCredentialsFields && sourceType != .plex
    }

    private var isReconnectFlow: Bool {
        reconnectSource != nil
    }

    private var addressPlaceholder: String {
        switch sourceType {
        case .smb: "smb://192.168.1.50/share"
        case .nfs: "nfs://192.168.1.50/export/movie.mkv"
        case .http: "http://example.com/video.mp4"
        case .local: "/Users/me/Movies"
        case .plex: "http://192.168.1.50:32400"
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        let config = makeSourceConfig()

        let tempId = config.id
        let bridge = sourcesVM.bridge
        let connectPassword = connectionPassword
        switch sourcesVM.bridge.addSource(config) {
        case .success:
            break
        case .failure(let err):
            isTesting = false
            testResult = err.message.isEmpty ? "Failed to create source" : err.message
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let connectResult = bridge.connect(sourceId: tempId, password: connectPassword)
            let connected = (try? connectResult.get()) != nil && bridge.isConnected(sourceId: tempId)
            let failureMessage: String
            if case .failure(let err) = connectResult {
                failureMessage = err.message
            } else {
                failureMessage = ""
            }

            if connected {
                bridge.disconnect(sourceId: tempId)
            }
            bridge.removeSource(id: tempId)

            DispatchQueue.main.async {
                isTesting = false
                if connected {
                    testResult = "Success"
                } else {
                    testResult = failureMessage.isEmpty ? "Connection failed" : failureMessage
                }
            }
        }
    }

    private func saveSource() {
        let config = makeSourceConfig()

        let autoConnect = sourceType == .plex && !showManualPlex && selectedServer != nil
        if isReconnectFlow {
            sourcesVM.reconnectPlexSource(config)
        } else if autoConnect {
            sourcesVM.addSourceAndConnect(config, password: persistedPassword)
        } else {
            sourcesVM.addSource(config, password: persistedPassword)
        }
        onDismiss()
    }

    private var normalizedAddress: String {
        var addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceType == .smb && !addr.hasPrefix("smb://") {
            addr = "smb://" + addr
        }
        if sourceType == .nfs && !addr.hasPrefix("nfs://") {
            addr = "nfs://" + addr
        }
        if sourceType == .http &&
           !addr.hasPrefix("http://") &&
           !addr.hasPrefix("https://") {
            addr = "http://" + addr
        }
        if sourceType == .plex {
            while addr.hasSuffix("/") { addr = String(addr.dropLast()) }
            if !addr.hasPrefix("http://") && !addr.hasPrefix("https://") {
                addr = "http://" + addr
            }
        }
        return addr
    }

    private var persistedUsername: String {
        if sourceType == .http || sourceType == .nfs || sourceType == .plex {
            return ""
        }
        return username
    }

    private var persistedAuthToken: String? {
        guard sourceType == .plex else { return nil }
        let token = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private var persistedPassword: String {
        if sourceType == .http || sourceType == .nfs || sourceType == .plex {
            return ""
        }
        return password
    }

    private var connectionPassword: String {
        sourceType == .plex ? "" : persistedPassword
    }

    private func makeSourceConfig() -> SourceConfig {
        SourceConfig(
            id: reconnectSource?.id ?? UUID().uuidString,
            displayName: displayName,
            type: sourceType,
            baseURI: normalizedAddress,
            username: persistedUsername,
            authToken: persistedAuthToken
        )
    }

    private func configureInitialState() {
        focusedField = .displayName

        guard let reconnectSource else { return }

        sourceType = .plex
        displayName = reconnectSource.displayName
        address = reconnectSource.baseURI
        username = ""
        password = ""
        showManualPlex = false
        focusedField = .address
    }
}
