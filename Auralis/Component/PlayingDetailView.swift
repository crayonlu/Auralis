//
//  Auralis
//
//  Created by Elsa on 2024/5/16.
//

import Foundation
import SwiftUI


struct LyricView: View {
    var lyric: [CloudMusicApi.LyricLine]
    @EnvironmentObject var playStatus: PlayStatus
    @EnvironmentObject var appSettings: AppSettings
    @ObservedObject var lyricStatus: LyricStatus
    @Binding var hasRoma: Bool
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        ScrollViewReader { proxy in
            let scrollToIdx: (Int) -> Void = { idx in
                guard !lyric.isEmpty else { return }
                let clamped = max(0, min(idx, lyric.count - 1))
                withAnimation(.spring) {
                    proxy.scrollTo("lyric-\(clamped)", anchor: .center)
                }
            }

            let scrollToCurrentLyric: () -> Void = {
                if let currentIndex = lyricStatus.currentLyricIndex {
                    scrollToIdx(currentIndex)
                }
            }

            let formatTimestamp: (Double) -> String = { seconds in
                guard seconds.isFinite else { return "00:00.00" }
                let hundredths = max(0, Int((seconds * 100).rounded()))
                let minutes = hundredths / 6000
                let secondsComponent = (hundredths % 6000) / 100
                let subSecond = hundredths % 100
                return String(format: "%02d:%02d.%02d", minutes, secondsComponent, subSecond)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .center) {
                    ForEach(
                        lyric.indices, id: \.self
                    ) { index in
                        let line = lyric[index]
                        let currentPlaying = lyricStatus.currentLyricIndex == index

                        VStack(alignment: .center) {
                            if appSettings.showTimestamp {
                                Text(formatTimestamp(line.time))
                                    .lineLimit(1)
                                    .font(.footnote)
                                    .foregroundColor(hoveredIndex == index ? .primary : .gray)
                            }

                            if appSettings.showRoma, let romalrc = line.romalrc {
                                Text(romalrc)
                                    .font(.body)
                                    .foregroundStyle(
                                        Color(
                                            nsColor: currentPlaying
                                                ? NSColor.textColor : NSColor.placeholderTextColor))
                            }

                            Text(line.lyric)
                                .font(.title3)
                                .foregroundStyle(
                                    Color(
                                        nsColor: currentPlaying
                                            ? NSColor.textColor : NSColor.placeholderTextColor)
                                )
                                .id("lyric-\(index)")

                            if let tlyric = line.tlyric {
                                Text(tlyric)
                                    .font(.title3)
                                    .foregroundStyle(
                                        Color(
                                            nsColor: currentPlaying
                                                ? NSColor.textColor : NSColor.placeholderTextColor))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(hoveredIndex == index ? Color.gray.opacity(0.12) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                            withAnimation(.easeInOut(duration: 0.15)) {
                                hoveredIndex = hovering ? index : nil
                            }
                        }
                        .onTapGesture {
                            Task {
                                await playStatus.seekToOffset(offset: line.time)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
                .onChange(of: lyricStatus.currentLyricIndex) { _, newIndex in
                    #if DEBUG
                        print("LyricView: currentLyricIndex changed to \(String(describing: newIndex))")
                    #endif
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let index = newIndex {
                            scrollToIdx(index)
                        } else {
                            scrollToIdx(0)
                        }
                    }
                }
                .onChange(of: lyricStatus.scrollResetToken) { _, _ in
                    guard !lyric.isEmpty, !lyricStatus.lyricTimeline.isEmpty else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollToIdx(0)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .focusCurrentPlayingItem)) {
                    notification in
                    if let index = notification.userInfo?["scrollToIndex"] as? Int {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToIdx(index)
                        }
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToCurrentLyric()
                        }
                    }
                }
            }
        }
    }
}

struct PlayingDetailView: View {
    @State private var lyric: [CloudMusicApi.LyricLine]?
    @EnvironmentObject var playStatus: PlayStatus
    @EnvironmentObject var playlistStatus: PlaylistStatus
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var playingDetailModel: PlayingDetailModel
    @EnvironmentObject var userInfo: UserInfo
    @State var hasRoma: Bool = false
    @State private var showNoLyricMessage: Bool = false
    @State private var sliderValue: Double = 0.0
    @State private var isSeeking: Bool = false
    @State private var contentPhase: CGFloat = 0
    @State private var isDismissing = false

    func secondsToMinutesAndSeconds(seconds: Double) -> String {
        formatPlaybackTime(seconds)
    }

    func updateLyric() async {
        showNoLyricMessage = false
        lyric = nil

        let defaultLyricLine = CloudMusicApi.LyricLine(
            time: 0,
            lyric: LanguageManager.shared.string("lyrics.no_lyrics"),
            tlyric: nil,
            romalrc: nil
        )

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            if lyric == nil {
                showNoLyricMessage = true
            }
        }

        if let currentId = playStatus.currentItem?.id,
            let lyric = await CloudMusicApi(cacheTtl: -1).lyric_new(id: currentId)
        {
            self.hasRoma = !(lyric.romalrc?.lyric.isEmpty ?? true)
            var lyric = lyric.merge()
            if lyric.isEmpty {
                lyric = [defaultLyricLine]
            }
            self.lyric = lyric
            await self.playStatus.lyricStatus.loadTimeline(
                lyric.map { Int($0.time * 10) },
                currentTime: self.playStatus.playbackProgress.playedSecond
            )

            if let currentIndex = self.playStatus.lyricStatus.currentLyricIndex {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(
                        name: .focusCurrentPlayingItem,
                        object: nil,
                        userInfo: ["scrollToIndex": currentIndex]
                    )
                }
            }

            // Force restart lyric synchronization with new lyrics
            if playStatus.playerState == .playing {
                playStatus.restartLyricSynchronization()
            }

            showNoLyricMessage = false
        } else {
            let fallback = [defaultLyricLine]
            self.lyric = fallback
            self.hasRoma = false
            await self.playStatus.lyricStatus.loadTimeline(
                fallback.map { Int($0.time * 10) },
                currentTime: self.playStatus.playbackProgress.playedSecond
            )
            showNoLyricMessage = false
        }
    }

    private var isCurrentSongLiked: Bool {
        guard let songId = playStatus.currentItem?.id else { return false }
        return userInfo.likelist.contains(songId)
    }

    private func toggleLike() async {
        guard let songId = playStatus.currentItem?.id else { return }
        let newLikeState = !isCurrentSongLiked
        do {
            try await CloudMusicApi(cacheTtl: 0).like(id: songId, like: newLikeState)
            await MainActor.run {
                if newLikeState {
                    userInfo.likelist.insert(songId)
                } else {
                    userInfo.likelist.remove(songId)
                }
            }
        } catch {
            print("Failed to toggle like: \(error)")
        }
    }

    private func artworkSize(for size: CGSize) -> CGFloat {
        // Scale the cover with the window, with a higher cap for large screens.
        // The width factor is kept conservative so the layout stays balanced.
        min(540, max(260, size.height * 0.48), size.width * 0.30)
    }

    var body: some View {
        GeometryReader { geo in
            let artworkSize = artworkSize(for: geo.size)

            VStack(spacing: 0) {
                // Main content area
                let hStackSpacing: CGFloat = min(80, max(32, geo.size.width * 0.04))
            HStack(spacing: hStackSpacing) {
                    // Left side: Album art + info, vertically centered as a group
                    VStack(spacing: 0) {
                        // Album art
                        Group {
                            if let url = playStatus.currentItem?.artworkUrl {
                                AsyncImageWithCache(url: url) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color.gray.opacity(0.3))
                                }
                            } else {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.gray.opacity(0.3))
                            }
                        }
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                        .scaleEffect(contentPhase >= 0.3 ? 1 : 0.65, anchor: .bottom)
                        .opacity(contentPhase >= 0.3 ? 1 : 0)
                        .animation(
                            .spring(response: 0.5, dampingFraction: 0.7, blendDuration: 0.3),
                            value: contentPhase
                        )

                        // Song title
                        Text(playStatus.currentItem?.title ?? "")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .padding(.top, 24)

                        // Artist
                        Text(playStatus.currentItem?.artist ?? "")
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .padding(.top, 4)

                        // Favorite button
                        Button(action: {
                            Task { await toggleLike() }
                        }) {
                            Image(systemName: isCurrentSongLiked ? "heart.fill" : "heart")
                                .font(.title3)
                                .foregroundColor(isCurrentSongLiked ? .red : .secondary)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 16)
                    }
                    .frame(width: artworkSize)
                    .frame(maxHeight: .infinity)
                    .opacity(contentPhase >= 0.3 ? 1 : 0)
                    .offset(y: contentPhase >= 0.3 ? 0 : 25)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: contentPhase)

                    // Right side: Lyrics
                    VStack {
                        if playStatus.currentItem != nil {
                            if let lyric = lyric {
                                LyricView(
                                    lyric: lyric,
                                    lyricStatus: playStatus.lyricStatus,
                                    hasRoma: $hasRoma
                                )
                                .id(playStatus.currentItem?.id ?? 0)
                            } else if showNoLyricMessage {
                                Spacer()
                                Text("lyrics.no_lyrics_yet")
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: min(geo.size.width * 0.45, 560), maxHeight: .infinity)
                    .opacity(contentPhase >= 0.5 ? 1 : 0)
                    .offset(x: contentPhase >= 0.5 ? 0 : 15)
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.85).delay(0.08),
                        value: contentPhase
                    )
                }
                .padding(.horizontal, 56)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                    .padding(.horizontal, 40)

                // Bottom bar
                VStack(spacing: 14) {
                    // Progress row
                    HStack(spacing: 12) {
                        Text(secondsToMinutesAndSeconds(seconds: isSeeking ? sliderValue : playStatus.playbackProgress.playedSecond))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 62, alignment: .trailing)

                        Slider(
                            value: $sliderValue,
                            in: 0...max(playStatus.playbackProgress.duration, 1),
                            onEditingChanged: { editing in
                                isSeeking = editing
                                if !editing {
                                    Task {
                                        await playStatus.seekToOffset(offset: sliderValue)
                                    }
                                }
                            }
                        )
                        .tint(.secondary)

                        Text(secondsToMinutesAndSeconds(seconds: playStatus.playbackProgress.duration))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 62, alignment: .leading)
                    }
                    .frame(maxWidth: 620)

                    // Controls row: transport controls are truly centered via ZStack,
                    // with close on the leading edge and loop mode on the trailing edge.
                    ZStack {
                        HStack(spacing: 32) {
                            Button(action: {
                                Task { await playlistStatus.previousTrack() }
                            }) {
                                Image(systemName: "backward.fill")
                                    .font(.title2)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Previous")

                            Button(action: {
                                Task { await playStatus.togglePlayPause() }
                            }) {
                                Image(systemName: playStatus.playerState == .playing ? "pause.fill" : "play.fill")
                                    .font(.system(size: 30))
                                    .frame(width: 40, height: 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(playStatus.playerState == .playing ? "Pause" : "Play")

                            Button(action: {
                                Task { await playlistStatus.nextTrack() }
                            }) {
                                Image(systemName: "forward.fill")
                                    .font(.title2)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Next")
                        }

                        HStack {
                            Button(action: {
                                dismiss()
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Close")

                            Spacer()

                            Button(action: {
                                playlistStatus.switchToNextLoopMode()
                            }) {
                                Image(systemName: loopModeIcon)
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(loopModeHelp)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .opacity(contentPhase >= 0.7 ? 1 : 0)
                .offset(y: contentPhase >= 0.7 ? 0 : 20)
                .animation(
                    .spring(response: 0.4, dampingFraction: 0.85).delay(0.12),
                    value: contentPhase
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .navigationBarBackButtonHidden(true)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                contentPhase = 1
            }
        }
        .onDisappear {
            contentPhase = 0
            isDismissing = false
        }
        .task {
            await updateLyric()
        }
        .onChange(of: playStatus.playbackGeneration) {
            #if DEBUG
                print("PlayingDetailView: playbackGeneration changed, reloading lyrics")
            #endif
            Task {
                await updateLyric()
            }
        }
        .onReceive(playStatus.playbackProgress.objectWillChange) { _ in
            if !isSeeking {
                sliderValue = playStatus.playbackProgress.playedSecond
            }
        }
    }

    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        // Single-phase dismiss: the removal transition (.bottomSlide) handles
        // the visual exit. Content stays visible and fades with the overlay,
        // eliminating the previous two-phase dead zone.
        playingDetailModel.closePlayingDetail()
    }

    private var loopModeIcon: String {
        switch playlistStatus.loopMode {
        case .once:
            return "repeat.1"
        case .shuffle:
            return "shuffle"
        case .sequence:
            return "repeat"
        case .intelligence:
            return "sparkles"
        }
    }

    private var loopModeHelp: String {
        switch playlistStatus.loopMode {
        case .once:
            return "Repeat One"
        case .shuffle:
            return "Shuffle"
        case .sequence:
            return "Repeat All"
        case .intelligence:
            return "Intelligence Mode"
        }
    }
}
