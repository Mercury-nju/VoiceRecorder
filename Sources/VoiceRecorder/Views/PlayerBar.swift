import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingExport: Bool
    @State private var volume = 0.72
    @State private var isBookmarked = false
    private var hasPlayback: Bool { model.playback.totalDuration > 0 && model.playback.currentPlaybackDate != nil }
    private var contextDate: Date? { model.playback.currentPlaybackDate }
    private var playbackSegment: RecordingSegment? {
        guard let date = model.playback.currentPlaybackDate else { return nil }
        return model.segments.first { $0.startTime <= date && $0.endTime > date }
    }

    var body: some View {
        let waveform = playbackSegment.flatMap { model.waveforms.samples[$0.id] } ?? []
        let segmentProgress: Double = {
            guard let segment = playbackSegment, let date = model.playback.currentPlaybackDate, segment.duration > 0 else { return 0 }
            return max(0, min(1, date.timeIntervalSince(segment.startTime) / segment.duration))
        }()
        HStack(spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(hasPlayback ? VoiceColors.coral : .secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(contextDate.map { DateTools.shortDate($0) } ?? "未选择录音").font(.subheadline.weight(.bold)).lineLimit(1)
                    Text(playbackSegment.map { "\(DateTools.time($0.startTime)) – \(DateTools.time($0.endTime))" } ?? "选择时间线或转录开始回听")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }.frame(width: 195, alignment: .leading)
            }

            Button { model.playback.rate = model.playback.rate >= 2 ? 1 : model.playback.rate + 0.25 } label: {
                Text(String(format: "%.2g×", model.playback.rate)).font(.caption.weight(.bold)).frame(width: 34, height: 34)
            }.buttonStyle(.plain).disabled(!hasPlayback).opacity(hasPlayback ? 1 : 0.38).help("调整播放速度")

            Button { model.playback.seek(to: max(0, model.playback.currentTime - 15)) } label: { Image(systemName: "gobackward.15").font(.system(size: 18)) }.buttonStyle(.plain).disabled(!hasPlayback).opacity(hasPlayback ? 1 : 0.36).help("后退 15 秒")
            Button { model.playback.toggle() } label: {
                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold)).frame(width: 48, height: 48)
                    .foregroundStyle(hasPlayback ? Color.white : Color.gray.opacity(0.54))
                    .background(hasPlayback ? VoiceColors.coral : Color.gray.opacity(0.14), in: Circle())
            }.buttonStyle(.plain).disabled(!hasPlayback).help(model.playback.isPlaying ? "暂停" : "播放")
            Button { model.playback.seek(to: min(model.playback.totalDuration, model.playback.currentTime + 15)) } label: { Image(systemName: "goforward.15").font(.system(size: 18)) }.buttonStyle(.plain).disabled(!hasPlayback).opacity(hasPlayback ? 1 : 0.36).help("前进 15 秒")

            VStack(spacing: 4) {
                if hasPlayback {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        if waveform.isEmpty {
                            Capsule().fill(Color.gray.opacity(0.22)).frame(maxWidth: .infinity).frame(height: 2)
                        } else {
                            ForEach(Array(waveform.enumerated()), id: \.offset) { index, amplitude in
                                let progress = Double(index) / Double(waveform.count)
                                Capsule()
                                    .fill(progress < segmentProgress ? VoiceColors.coral.opacity(0.78) : Color(red: 0.77, green: 0.79, blue: 0.83))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: max(2, amplitude * 30))
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard model.playback.totalDuration > 0 else { return }
                        model.playback.seek(to: max(0, min(1, value.location.x / geometry.size.width)) * model.playback.totalDuration)
                    })
                }.frame(height: 34)
                HStack { Text(clock(model.playback.currentTime)); Spacer(); Text(clock(model.playback.totalDuration)) }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Capsule().fill(Color.black.opacity(0.10)).frame(height: 3)
                    Text("无可播放录音").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity).padding(.horizontal, 4)

            Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(.secondary.opacity(hasPlayback ? 1 : 0.45))
            Slider(value: $volume, in: 0...1).tint(VoiceColors.ink).frame(width: 90).onChange(of: volume) { _, value in model.playback.setVolume(Float(value)) }.disabled(!hasPlayback).opacity(hasPlayback ? 1 : 0.36)
            Button { isBookmarked.toggle(); model.notice = isBookmarked ? "已为当前播放位置添加书签。" : "已移除书签。" } label: { Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark").font(.system(size: 15)) }.buttonStyle(.plain).disabled(!hasPlayback).opacity(hasPlayback ? 1 : 0.36).help("添加书签")
            Menu {
                Button("导出音频…") { showingExport = true }
                Button("停止播放", role: .destructive) { model.playback.stop() }
            } label: { Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).frame(width: 28, height: 32).contentShape(Rectangle()) }.menuStyle(.borderlessButton).disabled(!hasPlayback).help("更多播放操作")
        }
        .padding(.horizontal, 17).padding(.vertical, 10)
        .background(Color.white.opacity(hasPlayback ? 0.96 : 0.68), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 13).stroke(VoiceColors.line.opacity(hasPlayback ? 1 : 0.52), lineWidth: 0.8) }
        .shadow(color: .black.opacity(hasPlayback ? 0.035 : 0), radius: 5, y: -1)
    }

    private func clock(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return DateTools.time(date)
    }
    private func clock(_ interval: Double) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
