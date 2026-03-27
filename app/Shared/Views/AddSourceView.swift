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
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case displayName, address, username, password
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
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

            // Type picker
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
            }
            .padding(.horizontal)

            // Connection fields
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
                    GridRow {
                        Text("Username")
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        TextField("Optional", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .username)
                    }
                    GridRow {
                        Text("Password")
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        SecureField("Optional", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .password)
                    }
                }
            }
            .padding(.horizontal)

            Spacer()

            // Actions
            HStack {
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

                Spacer()

                Button("Save") {
                    saveSource()
                }
                .buttonStyle(.borderedProminent)
                .disabled(address.isEmpty || displayName.isEmpty)
            }
            .padding()
        }
        .onAppear { focusedField = .displayName }
    }

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

        // Add temporarily, test, then remove
        let tempId = config.id
        guard sourcesVM.bridge.addSource(config) else {
            isTesting = false
            testResult = "Failed to create source"
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let success = sourcesVM.bridge.connect(sourceId: tempId, password: password)
            let connected = success && sourcesVM.bridge.isConnected(sourceId: tempId)

            if connected {
                sourcesVM.bridge.disconnect(sourceId: tempId)
            }
            sourcesVM.bridge.removeSource(id: tempId)

            DispatchQueue.main.async {
                isTesting = false
                testResult = connected ? "Success" : "Connection failed"
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
        sourcesVM.addSource(config, password: password)
        onDismiss()
    }

    private var normalizedAddress: String {
        var addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceType == .smb && !addr.hasPrefix("smb://") {
            addr = "smb://" + addr
        }
        return addr
    }
}
