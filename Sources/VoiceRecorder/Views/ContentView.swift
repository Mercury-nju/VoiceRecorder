import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingExport = false

    var body: some View {
        VStack(spacing: 0) {
                WorkspaceHeader(showingExport: $showingExport)
                HStack(spacing: 0) {
                    DateSidebar().frame(minWidth: 190, idealWidth: 214, maxWidth: 238)
                    Rectangle().fill(VoiceColors.line).frame(width: 1)
                    TranscriptPane().frame(minWidth: 460, maxWidth: .infinity)
                    Rectangle().fill(VoiceColors.line).frame(width: 1)
                    InsightsPane().frame(minWidth: 250, idealWidth: 286, maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                PlayerBar(showingExport: $showingExport)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
        }
        .background(Color.white)
        .preferredColorScheme(.light)
        .frame(minWidth: 1180, minHeight: 760)
        .sheet(isPresented: $showingExport) {
            ExportSheet(date: model.selectedDate).environmentObject(model)
        }
        .alert("声音记录仪", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
}

private struct WorkspaceHeader: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingExport: Bool
    @FocusState private var searchFocused: Bool
    @State private var showingRecentSearches = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 19, weight: .semibold)).foregroundStyle(VoiceColors.coral)
                Text("EchoLog").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(VoiceColors.ink)
            }
            .frame(width: 214, alignment: .leading)
            .padding(.leading, 22)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索转录内容…", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { model.saveCurrentSearch(); showingRecentSearches = false; searchFocused = false }
                    .onChange(of: searchFocused) { _, focused in
                        showingRecentSearches = focused && model.searchText.isEmpty && !model.recentSearches.isEmpty
                    }
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
                Text("⌘ K").font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3).background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 13).frame(width: 255, height: 38)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .popover(isPresented: $showingRecentSearches, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近搜索").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.top, 7)
                    ForEach(model.recentSearches, id: \.self) { query in
                        Button {
                            model.searchText = query
                            showingRecentSearches = false
                            searchFocused = false
                        } label: {
                            HStack { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary); Text(query).lineLimit(1); Spacer() }
                                .font(.subheadline).padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(6).frame(width: 250)
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                if model.recording.state.isRecording {
                    LiveDot(active: true)
                    Text("正在录音").font(.subheadline.weight(.semibold)).foregroundStyle(VoiceColors.coral)
                    Text(durationClock(model.recording.elapsedRecordingTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    MiniWaveform().frame(width: 55, height: 24).foregroundStyle(VoiceColors.coral.opacity(0.75))
                } else {
                    Image(systemName: model.recording.state.symbolName).foregroundStyle(model.recording.state == .pausedByUser ? .secondary : VoiceColors.coral)
                    Text(model.recording.state.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(VoiceColors.coral.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
            Spacer(minLength: 14)
            if model.recording.microphoneGranted {
                Button { model.recording.toggleRecording() } label: {
                    Label(recordingButtonTitle, systemImage: recordingButtonSymbol)
                }.buttonStyle(WorkspaceButtonStyle())
            }
            Rectangle().fill(VoiceColors.line).frame(width: 1, height: 26).padding(.horizontal, 12)
            Button { showingExport = true } label: { Label("导出", systemImage: "square.and.arrow.up") }.buttonStyle(.plain).disabled(model.segments.isEmpty).padding(.trailing, 18)
            SettingsLink { Image(systemName: "gearshape").font(.system(size: 16)).foregroundStyle(VoiceColors.ink) }.padding(.trailing, 22)
        }
        .frame(height: 68)
        .background(Color.white)
        .overlay(alignment: .bottom) { Rectangle().fill(VoiceColors.line).frame(height: 1) }
    }

    private var recordingButtonTitle: String {
        switch model.recording.state {
        case .recording: return "暂停录音"
        case .pausedByUser: return "继续录音"
        case .error: return "重试录音"
        case .recovering: return "暂停录音"
        default: return "开始录音"
        }
    }

    private var recordingButtonSymbol: String {
        return model.recording.state.isRecording ? "pause.fill" : "record.circle.fill"
    }
}

private struct DateSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingFavorites = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("日期").font(.title3.weight(.bold)).padding(.horizontal, 8).padding(.top, 18)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.availableDays, id: \.self) { day in
                        DateRow(day: day, selected: DateTools.startOfDay(day) == model.selectedDate) { model.select(day: day) }
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                SidebarAction(title: "收藏片段", icon: "star", value: "\(model.favoriteTranscriptIDs.count)") {
                    showingFavorites = true
                }
            }
            .padding(.top, 10).overlay(alignment: .top) { Rectangle().fill(VoiceColors.line).frame(height: 1) }
        }
        .padding(.horizontal, 13).padding(.bottom, 14)
        .sheet(isPresented: $showingFavorites) {
            NavigationStack {
                List(model.favoriteTranscriptItems) { item in
                    Button { showingFavorites = false; model.play(item) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DateTools.time(item.startTime)).font(.caption.monospacedDigit()).foregroundStyle(VoiceColors.coral)
                            Text(item.text).foregroundStyle(.primary)
                        }
                    }.buttonStyle(.plain)
                }
                .navigationTitle("收藏片段")
                .overlay { if model.favoriteTranscriptItems.isEmpty { ContentUnavailableView("暂无收藏", systemImage: "star") } }
            }.frame(minWidth: 420, minHeight: 360)
        }
    }
}

private struct SidebarAction: View {
    let title: String
    let icon: String
    let value: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { Image(systemName: icon).frame(width: 18).foregroundStyle(VoiceColors.violet); Text(title); Spacer(); if let value { Text(value).foregroundStyle(.secondary) } }
                .font(.subheadline).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct DateRow: View {
    let day: Date
    let selected: Bool
    let action: () -> Void
    private var title: String { Calendar.current.isDateInToday(day) ? "今天" : Calendar.current.isDateInYesterday(day) ? "昨天" : DateTools.shortDate(day) }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: Calendar.current.isDateInToday(day) || Calendar.current.isDateInYesterday(day) ? "clock" : "calendar").foregroundStyle(selected ? VoiceColors.coral : VoiceColors.violet).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(daySummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(10).background(selected ? VoiceColors.coral.opacity(0.095) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    @EnvironmentObject private var model: AppModel
    private var daySummary: String {
        let segments = model.database.segments(on: day)
        let start = DateTools.startOfDay(day)
        let end = DateTools.endOfDay(day)
        let duration = segments.reduce(0) { total, segment in
            total + max(0, min(segment.endTime, end).timeIntervalSince(max(segment.startTime, start)))
        }
        return "\(durationText(duration)) · \(segments.count) 段"
    }
}

private struct TranscriptPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Calendar.current.isDateInToday(model.selectedDate) ? "今天" : DateTools.shortDate(model.selectedDate)) · \(DateTools.fullDate(model.selectedDate).components(separatedBy: " ").first ?? "")")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("\(durationText(model.selectedDayDuration)) · \(model.segments.count) 段录音 · \(model.transcriptItems.count) 段转录")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 28).padding(.top, 23).padding(.bottom, 18)
            Rectangle().fill(VoiceColors.line).frame(height: 1)
            Group {
                if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { SearchResultsView() }
                else if !model.recording.microphoneGranted && model.segments.isEmpty { OnboardingView() }
                else { DayTranscriptView() }
            }
        }
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.mic").font(.system(size: 36)).foregroundStyle(VoiceColors.coral)
            Text("让说过的话随时可找回").font(.title2.weight(.bold))
            Text("开启麦克风权限后，EchoLog 会在 Mac 本地保存声音并生成转录。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Button("授权麦克风并开始记录") { model.recording.requestPermissionsAndStart() }.buttonStyle(WorkspaceButtonStyle())
            Text("可随时暂停或删除录音。录制他人谈话前，请确认已获得适用法律要求的同意。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DayTranscriptView: View {
    @EnvironmentObject private var model: AppModel
    @State private var highlightedID: Int64?
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.filteredTranscriptItems.isEmpty { EmptyTranscriptState() }
                    ForEach(model.filteredTranscriptItems) { item in
                        TranscriptRow(
                            item: item,
                            highlighted: highlightedID == item.id || model.currentTranscriptItem?.id == item.id,
                            isPlaying: model.playback.isPlaying && model.currentTranscriptItem?.id == item.id,
                            isFavorite: model.favoriteTranscriptIDs.contains(item.id),
                            toggleFavorite: { model.toggleFavorite(item) }
                        ) { model.play(item) }.id(item.id)
                    }
                }.padding(.horizontal, 26).padding(.vertical, 14)
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(VoiceColors.line).frame(width: 1).padding(.vertical, 23).offset(x: 36).allowsHitTesting(false)
            }
            .onChange(of: model.focusedTranscriptID) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
                highlightedID = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if highlightedID == target { highlightedID = nil } }
            }
            .onAppear {
                guard let target = model.focusedTranscriptID else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
                    highlightedID = target
                }
            }
            .onChange(of: model.currentTranscriptItem?.id) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }
}

private struct EmptyTranscriptState: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.segments.isEmpty {
                ContentUnavailableView("当天尚无记录", systemImage: "waveform", description: Text("开始记录后，转录会显示在这里。")).frame(maxWidth: .infinity, minHeight: 300)
            } else {
                Text("音频已保存，转录正在后台处理。此 Mac 不支持所选语言时，可在设置中更改语言。").foregroundStyle(.secondary).padding(.vertical, 16)
                ForEach(model.segments) { segment in
                    HStack { Text(DateTools.time(segment.startTime)).font(.caption.monospacedDigit()); Text(segment.transcriptionState).font(.caption).foregroundStyle(.secondary); Spacer(); if segment.transcriptionState == "failed" || segment.transcriptionState == "unavailable" { Button("重试") { model.retryTranscription(for: segment) } } }
                        .padding(10).overlay(alignment: .bottom) { Rectangle().fill(VoiceColors.line).frame(height: 1) }
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let item: TranscriptItem
    var highlighted = false
    var isPlaying = false
    var isFavorite = false
    var toggleFavorite: () -> Void = {}
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 17) {
                Circle().fill(highlighted ? VoiceColors.coral : Color.secondary.opacity(0.7)).frame(width: 7, height: 7).padding(.top, 8)
                Text(DateFormatter.localizedString(from: item.startTime, dateStyle: .none, timeStyle: .medium)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 86, alignment: .leading).padding(.top, 2)
                Text(item.text).font(.system(size: 15, weight: .regular)).lineSpacing(5).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption).foregroundStyle(isFavorite ? VoiceColors.coral : .secondary)
                }.buttonStyle(.plain).help(isFavorite ? "取消收藏" : "收藏片段")
            }
            .padding(.horizontal, 11).padding(.vertical, 16)
            .background(highlighted ? VoiceColors.coral.opacity(isPlaying ? 0.12 : 0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .bottom) { Rectangle().fill(VoiceColors.line.opacity(0.7)).frame(height: 1).padding(.leading, 96) }
        }.buttonStyle(.plain)
    }
}

private struct SearchResultsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List(model.searchResults) { item in
            Button { model.play(item) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(DateTools.shortDate(item.startTime)) · \(DateTools.time(item.startTime))").font(.caption.weight(.semibold)).foregroundStyle(VoiceColors.coral)
                    Text(item.text).lineLimit(3)
                }.padding(.vertical, 8)
            }.buttonStyle(.plain).listRowBackground(Color.clear)
        }.scrollContentBackground(.hidden).overlay { if model.searchResults.isEmpty { ContentUnavailableView.search(text: model.searchText) } }
    }
}

private struct InsightsPane: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("时间线").font(.headline.weight(.bold))
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(model.availableDays, id: \.self) { day in
                            Button(DateTools.shortDate(day)) { model.select(day: day) }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(Calendar.current.isDateInToday(model.selectedDate) ? "今天" : DateTools.shortDate(model.selectedDate))
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(VoiceColors.line))
                    }.menuStyle(.borderlessButton)
                }
                timeline.frame(maxWidth: .infinity).frame(height: 560)
            }.padding(17)
        }
    }

    private var timeline: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(stride(from: 0, through: 24, by: 3)), id: \.self) { index in
                    Text(String(format: "%02d:00", index)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(height: index == 24 ? 0 : geometry.size.height / 8, alignment: .top)
                }
            }.frame(width: 38)
            GeometryReader { plot in
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) { ForEach(0..<8, id: \.self) { _ in Rectangle().fill(VoiceColors.line.opacity(0.72)).frame(height: 1).frame(maxHeight: .infinity) } }
                    ForEach(model.segments) { segment in
                        let dayStart = DateTools.startOfDay(model.selectedDate)
                        let segmentStart = max(0, segment.startTime.timeIntervalSince(dayStart)) / 86400
                        let color = timelineColor(Int(segmentStart * 96))
                        Capsule().fill(color)
                            .frame(width: activityWidth(model.waveforms.samples[segment.id] ?? [], maximum: plot.size.width - 4), height: 3)
                            .offset(x: 0, y: CGFloat(segmentStart) * plot.size.height)
                            .onTapGesture { model.navigateTimeline(to: segment.startTime) }
                            .accessibilityLabel("\(DateTools.time(segment.startTime)) 录音活动")
                    }
                    if model.recording.state.isRecording {
                        let livePosition = max(0, min(1, Date().timeIntervalSince(DateTools.startOfDay(model.selectedDate)) / 86400)) * plot.size.height
                        Capsule().fill(VoiceColors.coral)
                            .frame(width: activityWidth(model.recording.liveMeterLevels, maximum: plot.size.width - 4), height: 3)
                            .offset(x: 0, y: livePosition)
                            .allowsHitTesting(false)
                    }
                    if (!model.segments.isEmpty || model.recording.state.isRecording),
                       DateTools.startOfDay(model.selectedTimelineDate) == DateTools.startOfDay(model.selectedDate),
                       let markerTime = model.playback.currentPlaybackDate ?? (model.recording.state.isRecording ? Date() : nil) {
                        let position = max(0, min(1, markerTime.timeIntervalSince(DateTools.startOfDay(model.selectedDate)) / 86400)) * plot.size.height
                        Rectangle().fill(VoiceColors.coral.opacity(0.6)).frame(height: 1).offset(y: position)
                        Circle().fill(VoiceColors.coral).frame(width: 7, height: 7).offset(x: -3, y: position - 3)
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    let fraction = max(0, min(1, value.location.y / plot.size.height))
                    let target = DateTools.startOfDay(model.selectedDate).addingTimeInterval(fraction * 86400)
                    model.navigateTimeline(to: target)
                })
            }
            }.padding(.vertical, 2)
        }
    }

    private func timelineColor(_ slot: Int) -> Color {
        let hour = slot / 4
        let color: Color
        switch hour {
        case 0..<6: color = Color(red: 0.78, green: 0.80, blue: 0.84)
        case 6..<12: color = Color(red: 0.98, green: 0.70, blue: 0.52)
        case 12..<18: color = Color(red: 0.72, green: 0.63, blue: 0.86)
        default: color = Color(red: 0.94, green: 0.55, blue: 0.64)
        }
        return color.opacity(0.78)
    }

    private func activityWidth(_ values: [CGFloat], maximum: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return 7 }
        let average = values.reduce(0, +) / CGFloat(values.count)
        return min(maximum, max(7, 14 + average * min(72, maximum - 14)))
    }
}

private struct MiniWaveform: View {
    private let bars: [CGFloat] = [5, 10, 16, 8, 20, 12, 7, 18, 11, 6, 14, 9, 18, 6, 12]
    var body: some View {
        HStack(alignment: .center, spacing: 2) { ForEach(Array(bars.enumerated()), id: \.offset) { _, height in Capsule().fill(.primary.opacity(0.55)).frame(width: 2, height: height) } }
    }
}

private struct WorkspaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.weight(.semibold)).foregroundStyle(VoiceColors.ink).padding(.horizontal, 12).padding(.vertical, 8).background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(VoiceColors.line, lineWidth: 0.7)).opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private func durationText(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    return hours > 0 ? "\(hours)小时\(minutes)分钟" : "\(minutes)分钟"
}

private func durationClock(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
}
