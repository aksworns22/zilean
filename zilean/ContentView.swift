//
//  ContentView.swift
//  zilean
//
//  Created by 장대한 on 8/20/26.
//

import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ConversationViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            workspaceBar
            Divider()
            conversation
            Divider()
            composer
        }
        .frame(minWidth: 760, minHeight: 560)
        .task {
            await viewModel.connect()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            viewModel.shutdown()
        }
        .onDisappear {
            viewModel.shutdown()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Zilean")
                    .font(.headline)
                Text("로컬 Codex 대화")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.phase.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            StatusBadge(phase: viewModel.phase)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var workspaceBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedDirectory?.lastPathComponent ?? "작업 폴더를 선택하세요")
                        .lineLimit(1)
                    if let path = viewModel.selectedDirectory?.path {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Button("폴더 선택", systemImage: "folder.badge.plus") {
                    chooseDirectory()
                }

                Button("새 대화", systemImage: "plus.bubble") {
                    Task { await viewModel.createConversation() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canCreateConversation)
            }

            if let detail = viewModel.phase.detail {
                ErrorBanner(
                    message: detail,
                    showsRetry: viewModel.canRetryConnection,
                    retry: { Task { await viewModel.connect() } }
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var conversation: some View {
        if viewModel.messages.isEmpty {
            ContentUnavailableView {
                Label(
                    viewModel.hasConversation ? "첫 메시지를 보내세요" : "새 대화를 시작하세요",
                    systemImage: viewModel.hasConversation ? "bubble.left.and.bubble.right" : "folder.badge.plus"
                )
            } description: {
                Text(
                    viewModel.hasConversation
                        ? "Codex 응답이 이곳에 실시간으로 표시됩니다."
                        : "작업 폴더를 선택한 다음 새 대화를 만드세요."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(viewModel.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: viewModel.messages) { _, messages in
                    guard let lastID = messages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Codex에 메시지 보내기", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .disabled(!viewModel.hasConversation || viewModel.phase.isBusy)
                .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            .disabled(!viewModel.canSend)
            .help("메시지 보내기")
        }
        .padding(16)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Codex 작업 폴더 선택"
        panel.prompt = "선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.selectDirectory(url)
    }

    private func sendMessage() {
        guard viewModel.canSend else { return }
        Task { await viewModel.sendMessage() }
    }
}

private struct StatusBadge: View {
    let phase: ConversationPhase

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(phase.title)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }

    private var color: Color {
        switch phase {
        case .failed:
            .red
        case .completed:
            .green
        case .responding, .connecting, .creatingConversation:
            .orange
        case .ready, .idle:
            .blue
        case .disconnected:
            .secondary
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let showsRetry: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if showsRetry {
                Button("연결 재시도", action: retry)
            }
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MessageRow: View {
    let message: ConversationMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 80)
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
            }

            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14))

            if message.role == .agent {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)
    }
}

#Preview {
    ContentView()
}
