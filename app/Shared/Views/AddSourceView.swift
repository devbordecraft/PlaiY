import SwiftUI

struct AddSourceView: View {
    @ObservedObject var sourcesVM: SourcesViewModel
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

    var body: some View {
        VStack(spacing: 16) {
            header
            typePicker

            if sourceType == .plex && !showManualPlex {
                plexOAuthFlow
            } else {
                manualConnectionFields
            }

            Spacer()
            actionButtons
        }
        .onAppear { focusedField = .displayName }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Add Source")
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
                        password = plexAuth.token ?? ""
                        username = "" // Token auth, no username
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
                if sourceType != .plex || showManualPlex {
                    GridRow {
                        Text(sourceType == .plex ? "Email" : "Username")
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        TextField(sourceType == .plex ? "Leave empty for token auth" : "Optional",
                                  text: $username)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .username)
                    }
                }
                GridRow {
                    Text(sourceType == .plex ? "Token" : "Password")
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    SecureField(sourceType == .plex ? "X-Plex-Token or password" : "Optional",
                                text: $password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .password)
                }
                if sourceType == .plex && showManualPlex {
                    GridRow {
                        Spacer()
                            .frame(width: 80)
                        Text("Enter your X-Plex-Token for direct auth, or email + password for plex.tv login")
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

            Button("Save") {
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
        return !address.isEmpty && !displayName.isEmpty
    }

    // MARK: - Helpers

    private var addressPlaceholder: String {
        switch sourceType {
        case .smb: "smb://192.168.1.50/share"
        case .nfs: "nfs://192.168.1.50/export"
        case .http: "http://example.com/video.mp4"
        case .local: "/Users/me/Movies"
        case .plex: "http://192.168.1.50:32400"
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        let config = SourceConfig(
            displayName: displayName,
            type: sourceType,
            baseURI: normalizedAddress,
            username: username
        )

        let tempId = config.id
        switch sourcesVM.bridge.addSource(config) {
        case .success:
            break
        case .failure(let err):
            isTesting = false
            testResult = err.message.isEmpty ? "Failed to create source" : err.message
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let connectResult = sourcesVM.bridge.connect(sourceId: tempId, password: password)
            let connected = (try? connectResult.get()) != nil && sourcesVM.bridge.isConnected(sourceId: tempId)
            let failureMessage: String
            if case .failure(let err) = connectResult {
                failureMessage = err.message
            } else {
                failureMessage = ""
            }

            if connected {
                sourcesVM.bridge.disconnect(sourceId: tempId)
            }
            sourcesVM.bridge.removeSource(id: tempId)

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
        let config = SourceConfig(
            displayName: displayName,
            type: sourceType,
            baseURI: normalizedAddress,
            username: username
        )

        let autoConnect = sourceType == .plex && !showManualPlex && selectedServer != nil
        if autoConnect {
            sourcesVM.addSourceAndConnect(config, password: password)
        } else {
            sourcesVM.addSource(config, password: password)
        }
        onDismiss()
    }

    private var normalizedAddress: String {
        var addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceType == .smb && !addr.hasPrefix("smb://") {
            addr = "smb://" + addr
        }
        if sourceType == .plex {
            while addr.hasSuffix("/") { addr = String(addr.dropLast()) }
            if !addr.hasPrefix("http://") && !addr.hasPrefix("https://") {
                addr = "http://" + addr
            }
        }
        return addr
    }
}
