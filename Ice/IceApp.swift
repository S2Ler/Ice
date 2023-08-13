//
//  IceApp.swift
//  Ice
//

import SwiftUI

@main
struct IceApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    var body: some Scene {
        SettingsWindow()
    }

    init() {
        NSSplitViewItem.swizzle()
    }
}
