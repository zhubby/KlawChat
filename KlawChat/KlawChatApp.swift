//
//  KlawChatApp.swift
//  KlawChat
//
//  Created by zhubby on 2026/5/1.
//

import SwiftUI

@main
struct KlawChatApp: App {
    @StateObject private var viewModel = ChatViewModel(
        repository: ChatRepository(
            client: StarscreamGatewayWebSocketClient(),
            settingsStore: UserDefaultsGatewaySettingsStore()
        )
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
