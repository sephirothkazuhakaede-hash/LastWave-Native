import SwiftUI

@MainActor
struct BackendSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var connection = BackendConnectionStatus.shared
    @State private var serverURL = BackendConfiguration.savedURLString
    @State private var enabled = BackendConfiguration.isEnabled
    @State private var testing = false
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Faster streaming", systemImage: "bolt.horizontal.circle.fill")
                            .font(.title2.bold())
                            .foregroundStyle(Color.waveBlue)
                        Text("CapyFlow can try your private streaming server first. If it is unavailable, playback and downloads automatically return to the built-in YouTube connection.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .waveGlass(radius: 24)

                    VStack(alignment: .leading, spacing: 15) {
                        Toggle(isOn: $enabled) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Use custom server").font(.headline)
                                Text("Built-in fallback always stays available")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(Color.waveBlue)

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Server address")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            TextField("https://music.example.com", text: $serverURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .padding(.horizontal, 14)
                                .frame(height: 50)
                                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .disabled(!enabled || testing)
                            Text("HTTPS is recommended. A local address such as http://192.168.1.20:8000 is also supported for a server on your home network.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            testServer()
                        } label: {
                            HStack(spacing: 9) {
                                if testing { ProgressView().tint(.black) }
                                else { Image(systemName: "network.badge.shield.half.filled") }
                                Text(testing ? "Checking…" : "Test connection")
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.waveBlue)
                        .foregroundStyle(.black)
                        .disabled(!enabled || testing || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(18)
                    .waveGlass(radius: 24)

                    statusCard

                    Label {
                        Text("Only use a server you trust. On HTTPS, CapyFlow sends a short-lived Firebase identity token so the server can recognize your account. Identity tokens are never sent to local HTTP servers, and your Google password is never shared.")
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Streaming Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(testing || (enabled && serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3.bold())
                .foregroundStyle(statusColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(feedbackIsError ? "Connection problem" : "Server status")
                    .font(.headline)
                Text(feedback ?? connectionMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .waveGlass(radius: 22)
    }

    private var connectionMessage: String {
        switch connection.state {
        case .disabled:
            return "Using CapyFlow’s built-in YouTube connection."
        case .checking:
            return "The custom server has not been checked yet."
        case .connected(let message), .fallback(let message):
            return message
        }
    }

    private var statusIcon: String {
        if testing { return "arrow.triangle.2.circlepath" }
        if feedbackIsError { return "exclamationmark.triangle.fill" }
        switch connection.state {
        case .connected: return "checkmark.circle.fill"
        case .fallback: return "arrow.uturn.backward.circle.fill"
        case .checking: return "questionmark.circle.fill"
        case .disabled: return "network.slash"
        }
    }

    private var statusColor: Color {
        if feedbackIsError { return .orange }
        if case .connected = connection.state { return .green }
        return Color.waveBlue
    }

    private func testServer() {
        guard !testing else { return }
        testing = true
        feedback = nil
        feedbackIsError = false
        let candidate = serverURL
        Task { @MainActor in
            defer { testing = false }
            do {
                let result = try await BackendClient.shared.testConnection(to: candidate)
                feedback = result.message
            } catch {
                feedback = error.localizedDescription
                feedbackIsError = true
            }
        }
    }

    private func save() {
        do {
            _ = try BackendConfiguration.save(urlString: serverURL, enabled: enabled)
            Task { await BackendClient.shared.configurationDidChange() }
            dismiss()
        } catch {
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }
}
