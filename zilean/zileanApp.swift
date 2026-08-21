//
//  zileanApp.swift
//  zilean
//
//  Created by 장대한 on 8/20/26.
//

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
    }
}
