//
//  x_shredderApp.swift
//  x-shredder
//
//  Created by Preet Minhas on 13/10/26.
//

import SwiftUI

@main
struct x_shredderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Remove Helper") { model.uninstallHelper() }
                    .disabled(model.helperState == .notRegistered || model.isErasing)
            }
        }
    }
}
