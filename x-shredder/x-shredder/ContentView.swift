//
//  ContentView.swift
//  x-shredder
//
//  Created by Preet Minhas on 13/10/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .devices:
                DeviceListView()
            case .confirm(let disk):
                ConfirmationView(disk: disk)
            case .erasing(let disk):
                EraseProgressView(disk: disk)
            case .result(let result):
                ResultView(result: result)
            }
        }
        .padding(20)
        .onAppear { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have just approved the helper in System Settings.
            model.refreshHelperState()
        }
        .alert(
            "x-shredder",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            presenting: model.alertMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

extension AppModel {
    var isErasing: Bool {
        if case .erasing = screen { return true }
        return false
    }
}
