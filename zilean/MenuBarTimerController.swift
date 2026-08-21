import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let zileanShowFocusTimer = Notification.Name("zilean.showFocusTimer")
}

@MainActor
final class MenuBarTimerController: ObservableObject {
    private let viewModel: ConversationViewModel
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var timerSubscription: AnyCancellable?

    init(viewModel: ConversationViewModel) {
        self.viewModel = viewModel
        timerSubscription = viewModel.$focusTimer.sink { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        refreshTimer?.invalidate()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        timerSubscription?.cancel()
    }

    private func refresh() {
        let state = FocusTimerMenuBarState.make(timer: viewModel.focusTimer, now: .now)
        guard case let .running(taskTitle, remainingText) = state else {
            removeStatusItem()
            return
        }

        let statusItem = statusItem ?? makeStatusItem()
        statusItem.button?.title = remainingText
        statusItem.button?.toolTip = "\(taskTitle) · 남은 시간 \(remainingText)"
        statusItem.button?.setAccessibilityLabel("집중 타이머 남은 시간 \(remainingText)")
        startRefreshTimerIfNeeded()
    }

    private func makeStatusItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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

    private func startRefreshTimerIfNeeded() {
        guard refreshTimer == nil else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func removeStatusItem() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func showFocusTimer() {
        guard viewModel.focusTimer?.status == .running else {
            refresh()
            return
        }

        NotificationCenter.default.post(name: .zileanShowFocusTimer, object: nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let window = NSApp.windows.first(where: { $0.canBecomeKey }) else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}
