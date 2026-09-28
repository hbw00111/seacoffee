import ServiceManagement
import SwiftUI

/// Launch at login through the system's own login-item service (macOS 13+). The system keeps
/// the setting, so it is read back from `SMAppService` rather than stored by the app.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var message: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
        if needsApproval { message = "已加入登录项，需在“系统设置 › 通用 › 登录项”中允许 Sea Coffee" }
    }

    func set(_ on: Bool) {
        message = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // `swift run` has no app bundle to register; say so instead of failing silently.
            message = Bundle.main.bundleURL.pathExtension == "app"
                ? "无法\(on ? "开启" : "关闭")开机自启：\(error.localizedDescription)"
                : "请从 Sea Coffee.app 启动后再开启开机自启"
        }
        refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// The settings control: a switch, plus the approval shortcut and any problem in words.
struct LaunchAtLoginToggle: View {
    @ObservedObject var launch: LaunchAtLogin
    var body: some View {
        HStack(spacing: 10) {
            if let message = launch.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            if launch.needsApproval {
                Button("打开登录项") { launch.openLoginItems() }.buttonStyle(GlassButtonStyle(compact: true))
            }
            Spacer(minLength: 0)
            Toggle("开机自启", isOn: Binding(get: { launch.enabled }, set: { launch.set($0) })).labelsHidden()
        }
        // The user may approve or remove the item in System Settings while this window is open.
        .onAppear { launch.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in launch.refresh() }
    }
}
