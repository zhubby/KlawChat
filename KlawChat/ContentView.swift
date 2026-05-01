import MarkdownUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var isShowingSettings = false
    @State private var configuredSession: WorkspaceSession?

    var body: some View {
        NavigationSplitView {
            AgentListView(
                isShowingSettings: $isShowingSettings,
                configuredSession: $configuredSession
            )
        } detail: {
            if let session = viewModel.selectedSession {
                ChatDetailView(session: session, configuredSession: $configuredSession)
            } else {
                EmptyChatView()
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            GatewaySettingsView()
        }
        .sheet(item: $configuredSession) { session in
            AgentSettingsView(session: session)
        }
    }
}

private struct AgentListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var isShowingSettings: Bool
    @Binding var configuredSession: WorkspaceSession?

    var body: some View {
        List(selection: $viewModel.selectedSessionKey) {
            Section {
                ConnectionHeaderView(isShowingSettings: $isShowingSettings)
            }

            Section("Agents") {
                if !viewModel.isWorkspaceLoaded && viewModel.connectionState == .connected {
                    HStack {
                        ProgressView()
                        Text("Loading workspace...")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if viewModel.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Agents",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Connect to the gateway or create a new agent session.")
                    )
                } else {
                    ForEach(viewModel.sessions) { session in
                        NavigationLink {
                            ChatDetailView(session: session, configuredSession: $configuredSession)
                                .onAppear {
                                    viewModel.selectSession(session)
                                }
                        } label: {
                            AgentRowView(session: session)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.selectSession(session)
                        })
                        .contextMenu {
                            Button("Settings") {
                                viewModel.selectSession(session)
                                configuredSession = session
                            }
                            Button("Delete", role: .destructive) {
                                viewModel.deleteSession(session)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                viewModel.deleteSession(session)
                            }
                            Button("Settings") {
                                viewModel.selectSession(session)
                                configuredSession = session
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.createSession()
                } label: {
                    if viewModel.isCreatingSession {
                        ProgressView()
                    } else {
                        Label("New Agent", systemImage: "plus")
                    }
                }
                .disabled(!viewModel.canCreateSession)
            }
        }
        .task {
            if viewModel.connectionState == .disconnected {
                viewModel.connect()
            }
        }
    }
}

private struct ConnectionHeaderView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var isShowingSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(viewModel.connectionState.label, systemImage: statusIcon)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Spacer()
                Button(viewModel.connectionState == .connected ? "Reconnect" : "Connect") {
                    viewModel.connect()
                }
                .buttonStyle(.borderedProminent)
            }

            Text(viewModel.settings.baseURLString)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch viewModel.connectionState {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        case .disconnected:
            return "circle"
        }
    }

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .error:
            return .red
        case .disconnected:
            return .secondary
        }
    }
}

private struct AgentRowView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let session: WorkspaceSession

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(viewModel.selectedSessionKey == session.sessionKey ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.model ?? session.modelProvider ?? session.sessionKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ChatDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let session: WorkspaceSession
    @Binding var configuredSession: WorkspaceSession?

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(messages: viewModel.selectedMessages)
            Divider()
            ComposerView()
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    configuredSession = viewModel.selectedSession ?? session
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Agent settings")
            }
        }
        .task(id: session.sessionKey) {
            viewModel.ensureSelectedSessionReady()
        }
    }
}

private struct MessageListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let messages: [ChatMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            "Start the Conversation",
                            systemImage: "sparkles",
                            description: Text("Ask this agent a question. Replies will appear here in real time.")
                        )
                        .padding(.top, 80)
                    } else {
                        Button("Load older messages") {
                            viewModel.loadOlderHistory()
                        }
                        .font(.footnote)
                        .disabled(viewModel.isLoadingHistory)

                        ForEach(messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: messages.last?.text) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastID = messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

private struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if message.isStreaming {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
                if message.role == .assistant {
                    Markdown(message.text.isEmpty ? " " : message.text)
                        .markdownTextStyle {
                            FontSize(15)
                        }
                } else {
                    Text(message.text)
                        .font(.body)
                }
            }
            .padding(12)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
            if message.role != .user {
                Spacer(minLength: 40)
            }
        }
    }

    private var label: String {
        switch message.role {
        case .assistant:
            return "Klaw"
        case .system:
            return "System"
        case .user:
            return "You"
        }
    }

    private var background: Color {
        switch message.role {
        case .assistant:
            return Color(.secondarySystemBackground)
        case .system:
            return .orange.opacity(0.12)
        case .user:
            return .accentColor.opacity(0.18)
        }
    }
}

private struct ComposerView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message this agent", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(.separator).opacity(0.45), lineWidth: 1)
                }
                .focused($isFocused)
                .onSubmit {
                    viewModel.sendDraft()
                }

            Button {
                viewModel.sendDraft()
                isFocused = true
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.headline)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(!viewModel.canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct AgentSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    let session: WorkspaceSession

    @State private var title: String
    @State private var selectedProviderID: String
    @State private var model: String

    init(session: WorkspaceSession) {
        self.session = session
        _title = State(initialValue: session.displayTitle)
        _selectedProviderID = State(initialValue: session.modelProvider ?? "")
        _model = State(initialValue: session.model ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    TextField("Agent name", text: $title)
                }

                Section("Model") {
                    Picker("Provider", selection: $selectedProviderID) {
                        Text("Default").tag("")
                        ForEach(viewModel.providerCatalog.providers) { provider in
                            Text(provider.name ?? provider.id).tag(provider.id)
                        }
                    }
                    .onChange(of: selectedProviderID) { _, newValue in
                        if let provider = viewModel.providerCatalog.providers.first(where: { $0.id == newValue }) {
                            model = provider.defaultModel
                        }
                    }

                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)

                    if let provider = selectedProvider {
                        Text("Default: \(provider.defaultModel)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Agent Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.updateSelectedSession(
                            title: title,
                            modelProvider: selectedProviderID.nilIfBlank,
                            model: model.nilIfBlank ?? selectedProvider?.defaultModel
                        )
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            let route = viewModel.providerCatalog.resolvedRoute(
                provider: session.modelProvider,
                model: session.model
            )
            if selectedProviderID.isEmpty {
                selectedProviderID = route.provider
            }
            if model.isEmpty {
                model = route.model
            }
        }
    }

    private var selectedProvider: Provider? {
        viewModel.providerCatalog.providers.first { $0.id == selectedProviderID }
    }
}

private struct GatewaySettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isTokenVisible = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    TextField("Base URL", text: $viewModel.settings.baseURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    HStack {
                        Group {
                            if isTokenVisible {
                                TextField("Token", text: $viewModel.settings.token)
                            } else {
                                SecureField("Token", text: $viewModel.settings.token)
                            }
                        }
                        .textInputAutocapitalization(.never)

                        Button {
                            isTokenVisible.toggle()
                        } label: {
                            Image(systemName: isTokenVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isTokenVisible ? "Hide token" : "Show token")
                    }
                }
                Section {
                    Toggle("Stream replies", isOn: $viewModel.settings.streamEnabled)
                }
            }
            .navigationTitle("Gateway Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.saveSettings()
                        viewModel.connect()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct EmptyChatView: View {
    var body: some View {
        ContentUnavailableView(
            "Select an Agent",
            systemImage: "bubble.left.and.text.bubble.right",
            description: Text("Choose an agent session from the list or create a new one.")
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(ChatViewModel(repository: PreviewChatRepository()))
}

private final class PreviewChatRepository: ChatRepositoryProtocol {
    var frames: AsyncStream<ServerFrame> { AsyncStream { _ in } }
    var settings = GatewaySettings.defaults

    func save(settings: GatewaySettings) {}
    func connect(settings: GatewaySettings) async throws {}
    func disconnect() {}
    func bootstrap() async throws -> String { "preview-bootstrap" }
    func listProviders() async throws {}
    func createSession() async throws {}
    func updateSession(sessionKey: String, title: String, modelProvider: String?, model: String?) async throws {}
    func deleteSession(sessionKey: String) async throws {}
    func subscribe(sessionKey: String) async throws {}
    func loadHistory(sessionKey: String, beforeMessageID: String?, limit: Int) async throws {}
    func submit(sessionKey: String, input: String, stream: Bool, route: ModelRoute, attachments: [ArchiveAttachment]) async throws {}
}
