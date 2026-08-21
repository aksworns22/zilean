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
    init() {
        guard ZileanMCPServer.shouldRun else { return }
        ZileanMCPServer.run()
        exit(EXIT_SUCCESS)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
