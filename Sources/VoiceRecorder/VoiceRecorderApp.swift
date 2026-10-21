import SwiftUI

@main
struct VoiceRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("声音记录仪") {
            ContentView()
                .environmentObject(model)
                .background(WindowConfigurator())
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("显示声音记录仪") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }

        MenuBarExtra("声音记录仪", systemImage: model.recording.state.symbolName) {
            MenuBarView()
                .environmentObject(model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

private struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text(model.recording.state.title)
        if model.recording.state.isRecording {
            Button("暂停录音") { model.recording.pauseByUser() }
        } else {
            Button("开始录音") {
                if model.recording.microphoneGranted {
                    model.recording.resumeByUser()
                } else {
                    model.recording.requestPermissionsAndStart()
                }
            }
        }
        Divider()
        Button("显示主窗口") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出声音记录仪") { NSApp.terminate(nil) }
    }
}
