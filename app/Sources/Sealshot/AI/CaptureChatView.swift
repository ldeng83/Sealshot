import SwiftUI

/// Chat panel for asking the on-device model about the current capture (and,
/// via the library-search tool, other captures). Presented as a sheet.
struct CaptureChatView: View {
    @Bindable var viewModel: CaptureChatViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask about this Capture").font(.headline)
                Spacer()
                Button("Done", action: onClose)
            }
            .padding()
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if viewModel.messages.isEmpty {
                            Text("Ask about what's on screen — or your whole library.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                        ForEach(viewModel.messages) { message in
                            messageRow(message).id(message.id)
                        }
                        if viewModel.isResponding {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: viewModel.messages.count) {
                    if let last = viewModel.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Ask a question…", text: $viewModel.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(viewModel.send)
                Button("Send", action: viewModel.send)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(viewModel.input.trimmingCharacters(in: .whitespaces).isEmpty
                              || viewModel.isResponding)
            }
            .padding()
        }
        .frame(width: 480, height: 460)
    }

    @ViewBuilder
    private func messageRow(_ message: AIChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(8)
                .background(message.role == .user
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }
}
