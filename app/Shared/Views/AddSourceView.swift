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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Source")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            Form {
                Section("Type") {
                    Picker("Protocol", selection: $sourceType) {
                        ForEach(SourceType.allCases.filter(\.isAvailable), id: \.self) { type in
                            Label(type.displayName, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Connection") {
                    TextField("Display Name", text: $displayName, prompt: Text("My NAS"))
                    TextField("Address", text: $address, prompt: Text(addressPlaceholder))
                    TextField("Username", text: $username, prompt: Text("Optional"))
                    SecureField("Password", text: $password, prompt: Text("Optional"))
                }

                Section {
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
                }
            }
            .formStyle(.grouped)
        }
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
