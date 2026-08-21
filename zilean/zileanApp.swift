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
    @StateObject private var menuBarTimerController: MenuBarTimerController

    init() {
        let viewModel = ConversationViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        _menuBarTimerController = StateObject(
            wrappedValue: MenuBarTimerController(viewModel: viewModel)
        )

        guard ZileanMCPServer.shouldRun else { return }
        ZileanMCPServer.run()
        exit(EXIT_SUCCESS)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .environmentObject(menuBarTimerController)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
