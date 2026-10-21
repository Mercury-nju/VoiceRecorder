import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingDeleteConfirmation = false

    var body: some View {
        ZStack {
            AmbientBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "设置")
                        Text("设置")
                            .font(.system(size: 31, weight: .bold, design: .rounded))
                        Text("所有声音和文字，默认留在你的设备上。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    GlassSurface {
                        settingsSection(title: "录音状态", symbol: "waveform.and.mic") {
                            LabeledContent("当前状态", value: model.recording.state.title)
                            Toggle("登录时打开声音记录仪", isOn: Binding(
                                get: { model.settings.launchAtLogin },
                                set: { model.settings.setLaunchAtLogin($0) }
                            ))
                            if let message = model.settings.launchAtLoginMessage {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("关闭窗口不会停止录音。使用菜单栏或主窗口中的状态按钮暂停。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GlassSurface {
                        settingsSection(title: "设备端转录", symbol: "text.bubble") {
                            Picker("识别语言", selection: Binding(
                                get: { model.transcription.selectedLanguage },
                                set: { model.transcription.selectedLanguage = $0 }
                            )) {
                                Text("简体中文").tag("zh-CN")
                                Text("English (US)").tag("en-US")
                            }
                            Text("使用 Apple Speech 的设备端模式。没有本地语言包时，音频仍会安全保留。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            LabeledContent("队列状态", value: model.transcription.statusMessage)
                        }
                    }

                    GlassSurface {
                        settingsSection(title: "本地隐私", symbol: "lock.shield") {
                            LabeledContent("本地占用", value: model.storageUsageText)
                            Text("音频、转录文字和搜索索引默认只保存于此 Mac，应用不会上传这些数据。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("打开存储位置") { model.openStorageFolder() }
                                    .buttonStyle(SoftButtonStyle())
                                Spacer()
                                Button("删除所有本地数据", role: .destructive) { showingDeleteConfirmation = true }
                                    .buttonStyle(SoftButtonStyle())
                            }
                        }
                    }


                    GlassSurface {
                        settingsSection(title: "录音合规", symbol: "person.2") {
                            Text("录制涉及他人的谈话前，请确认已遵守所在地关于录音、知情与同意的适用法律。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(28)
            }
        }
        .preferredColorScheme(.light)
        .frame(width: 620, height: 700)
        .alert("删除所有本地数据？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) { model.clearAllLocalData() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这会删除本机内的音频、转录文字和搜索索引，且无法恢复。")
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: symbol).foregroundStyle(VoiceColors.cyan)
                Text(title).font(.headline.weight(.bold))
            }
            content()
        }
    }
}
