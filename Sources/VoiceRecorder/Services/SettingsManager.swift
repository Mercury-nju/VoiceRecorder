import Combine
import Foundation
import ServiceManagement

@MainActor
final class SettingsManager: ObservableObject {
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginMessage: String?

    init() {
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = launchAtLogin == enabled ? nil : "系统未确认登录项状态，请在系统设置中检查。"
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = "无法更新登录项：\(error.localizedDescription)"
        }
    }
}
