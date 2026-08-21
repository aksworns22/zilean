//
//  zileanApp.swift
//  zilean
//
//  Created by 장대한 on 8/20/26.
//

import AppKit
import Darwin
import SwiftUI

@main
struct ZileanApp: App {
    @StateObject private var viewModel: ConversationViewModel

    init() {
        let viewModel = ConversationViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)

        guard ZileanMCPServer.shouldRun else { return }
        ZileanMCPServer.run()
        exit(EXIT_SUCCESS)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra(
            isInserted: Binding(
                get: { viewModel.focusTimer?.status == .running },
                set: { _ in }
            )
        ) {
            if let timer = viewModel.focusTimer, timer.status == .running {
                Button {
                    showFocusTimerWindow()
                } label: {
                    Label("집중 타이머 열기", systemImage: "macwindow")
                }

                Divider()

                Button("타이머 완료") {
                    viewModel.completeFocusTimer()
                }
            }
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let timer = viewModel.focusTimer, timer.status == .running {
                    Label(
                        timer.remainingText(at: context.date),
                        systemImage: "timer"
                    )
                    .font(.system(.body, design: .monospaced))
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }

    private func showFocusTimerWindow() {
        NotificationCenter.default.post(name: .zileanShowFocusTimer, object: nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let window = NSApp.windows.first(where: { $0.canBecomeKey }) else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}
