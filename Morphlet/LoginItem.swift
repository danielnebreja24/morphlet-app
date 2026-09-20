//
//  LoginItem.swift
//  Morphlet
//
//  Launch at login, via SMAppService (macOS 13+). The modern replacement for
//  SMLoginItemSetEnabled and for planting a plist in ~/Library/LaunchAgents:
//  registering the main app is enough, no helper bundle required.
//

import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp`.
///
/// The authoritative state lives in the system, not in `UserDefaults` — the
/// user can turn this off in System Settings ▸ General ▸ Login Items, and macOS
/// can put a registration into `.requiresApproval` on its own. So this always
/// reports what `SMAppService` says rather than caching a preference that could
/// quietly disagree with reality.
@MainActor
final class LoginItem: ObservableObject {

    /// True only when the login item is registered *and* approved.
    @Published private(set) var isEnabled = false

    /// Set when macOS has the registration but the user hasn't approved it yet.
    /// The toggle can't fix this — only System Settings can.
    @Published private(set) var needsApproval = false

    /// Last registration failure, for display. Nil when the last change worked.
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    /// Re-reads the system state. Worth calling whenever the menu opens, since
    /// the user can change this in System Settings behind our back.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // Most often this is an unsigned or badly-located build:
            // SMAppService wants a stable, signed app, which in practice means
            // /Applications rather than a path inside build/.
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Opens System Settings ▸ General ▸ Login Items, the only place an
    /// approval-pending registration can actually be approved.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
