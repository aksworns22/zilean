import AppKit
import Combine
import Foundation

@MainActor
final class MenuBarTimerController: ObservableObject {
    private let viewModel: ConversationViewModel
    private var statusItem: NSStatusItem?
    private var timerSubscription: AnyCancellable?

    init(viewModel: ConversationViewModel) {
        self.viewModel = viewModel
        timerSubscription = viewModel.$focusTimerPresentation.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    deinit {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        timerSubscription?.cancel()
    }

    private func refresh() {
        let state = FocusTimerMenuBarState.make(presentation: viewModel.focusTimerPresentation)
        guard case let .running(taskTitle, remainingText) = state else {
            removeStatusItem()
            return
        }

        let statusItem = statusItem ?? makeStatusItem()
        statusItem.button?.title = remainingText
        statusItem.button?.toolTip = "\(taskTitle) · 남은 시간 \(remainingText)"
        statusItem.button?.setAccessibilityLabel("집중 타이머 남은 시간 \(remainingText)")
        statusItem.isVisible = true
    }

    private func makeStatusItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "com.aksworns22.zilean.focus-timer"
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showFocusTimer)
        statusItem.button?.image = NSImage(
            systemSymbolName: "timer",
            accessibilityDescription: "집중 타이머"
        )
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        self.statusItem = statusItem
        return statusItem
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func showFocusTimer() {
        guard viewModel.focusTimer?.status == .running else {
            refresh()
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        guard let window = NSApp.windows.first(where: { $0.canBecomeKey }) else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}
