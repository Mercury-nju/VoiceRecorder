import SwiftUI

struct ExportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var resultMessage: String?
    @State private var exporting = false

    init(date: Date) {
        let initialStart = DateTools.startOfDay(date)
        _start = State(initialValue: initialStart)
        _end = State(initialValue: min(Date(), DateTools.endOfDay(date)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导出片段")
                .font(.title2.weight(.semibold))
            Text("应用会自动拼接跨越多个五分钟切片的音频。文本仅包含已经完成设备端转录的内容。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            DatePicker("开始", selection: $start, displayedComponents: [.date, .hourAndMinute])
            DatePicker("结束", selection: $end, displayedComponents: [.date, .hourAndMinute])

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("导出 TXT") { exportText() }
                    .disabled(exporting || end <= start)
                Button("导出 M4A") { exportAudio() }
                    .buttonStyle(.borderedProminent)
                    .disabled(exporting || end <= start)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func exportAudio() {
        exporting = true
        model.exportAudio(from: start, to: end) { result in
            exporting = false
            switch result {
            case .success(let url): resultMessage = "已导出到 \(url.lastPathComponent)"
            case .failure(let error): resultMessage = error.localizedDescription
            }
        }
    }

    private func exportText() {
        exporting = true
        model.exportText(from: start, to: end) { result in
            exporting = false
            switch result {
            case .success(let url): resultMessage = "已导出到 \(url.lastPathComponent)"
            case .failure(let error): resultMessage = error.localizedDescription
            }
        }
    }
}
