//
//  MVPlayerView.swift
//  Auralis
//
//  Full-screen MV (Music Video) player overlay with native video rendering
//  and custom SwiftUI controls matching the app's existing style.
//

import AVFoundation
import AVKit
import Combine
import SwiftUI

// MARK: - AVPlayerView Representable

struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - MV Player View

struct MVPlayerView: View {
    @EnvironmentObject var mvPlayerModel: MVPlayerModel
    @StateObject private var mvPlayerState = MVPlayerState()
    @EnvironmentObject var playStatus: PlayStatus

    @State private var sliderValue: Double = 0
    @State private var isSeeking: Bool = false
    @State private var contentPhase: CGFloat = 0
    @State private var showControls: Bool = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var wasAudioPlaying: Bool = false
    @State private var volume: Float = 1.0
    @State private var isDismissing = false

    private func secondsToMinutesAndSeconds(seconds: Double) -> String {
        formatPlaybackTime(seconds)
    }

    private func formatPlayCount(_ count: Int?) -> String {
        guard let count = count else { return "" }
        if count >= 100_000_000 {
            return String(format: "%.1f亿", Double(count) / 100_000_000)
        } else if count >= 10_000 {
            return String(format: "%.1f万", Double(count) / 10_000)
        }
        return "\(count)"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                Color.black
                    .ignoresSafeArea()

                // Layout: header (top) + video (center) + controls (bottom)
                VStack(spacing: 0) {
                    // Header bar - fixed height, fades with showControls
                    headerBar
                        .frame(height: 36)
                        .opacity(showControls && contentPhase >= 0.3 ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: showControls)

                    // Video area - fills remaining space, centered
                    Group {
                        if mvPlayerState.videoURL != nil {
                            AVPlayerViewRepresentable(player: mvPlayerState.avPlayer)
                        } else if mvPlayerState.error != nil {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                                Text(mvPlayerState.error ?? "")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        } else {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .controlSize(.large)
                                Text("mv.loading")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(contentPhase >= 0.3 ? 1 : 0)
                    .scaleEffect(contentPhase >= 0.3 ? 1 : 0.92, anchor: .center)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: contentPhase)

                    // Controls bar - fixed height, fades with showControls
                    controlsBar
                        .frame(height: 52)
                        .opacity(showControls && contentPhase >= 0.5 ? 1 : 0)
                        .offset(y: contentPhase >= 0.5 ? 0 : 15)
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.85).delay(0.06),
                            value: contentPhase
                        )
                        .animation(.easeInOut(duration: 0.2), value: showControls)
                }
                .ignoresSafeArea()

                // Center play/pause indicator (shows when paused and controls hidden)
                if !mvPlayerState.isPlaying && mvPlayerState.videoURL != nil && !showControls {
                    Image(systemName: "play.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.7))
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            volume = playStatus.volume
            mvPlayerState.volume = volume
            wasAudioPlaying = playStatus.playerState == .playing
            if wasAudioPlaying {
                playStatus.pausePlay()
            }

            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                contentPhase = 1
            }

            if let mv = mvPlayerModel.currentMV {
                Task {
                    await mvPlayerState.loadMV(mv)
                }
            }

            scheduleAutoHideControls()
        }
        .onDisappear {
            // Cancel any pending auto-hide task first
            hideControlsTask?.cancel()
            hideControlsTask = nil

            // Tear down the player synchronously before the view is removed.
            // This removes all time observers and KVO, preventing deadlocks.
            mvPlayerState.cleanup()
            contentPhase = 0
            isDismissing = false

            // Resume audio playback after a short delay so it doesn't
            // conflict with the view removal transition animation.
            if wasAudioPlaying {
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3s
                    await playStatus.startPlay()
                }
            }
        }
        .onReceive(mvPlayerState.$currentTime) { newTime in
            if !isSeeking {
                sliderValue = newTime
            }
        }
        .onReceive(mvPlayerState.$isPlaying) { playing in
            if playing {
                scheduleAutoHideControls()
            } else {
                showControls = true
                hideControlsTask?.cancel()
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showControls = true
                if mvPlayerState.isPlaying {
                    scheduleAutoHideControls()
                }
            case .ended:
                break
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.space) {
            mvPlayerState.togglePlayPause()
            return .handled
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(LanguageManager.shared.string("mv.close"))

            Spacer()

            VStack(spacing: 1) {
                Text(mvPlayerModel.currentMV?.name ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let artist = mvPlayerModel.currentMV?.artistName {
                    Text(artist)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer()

            VolumePopoverButtonMV(volume: Binding(
                get: { mvPlayerState.volume },
                set: { mvPlayerState.volume = $0 }
            ))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Controls Bar

    private var controlsBar: some View {
        HStack(spacing: 14) {
            // Play/Pause
            Button(action: {
                mvPlayerState.togglePlayPause()
            }) {
                Image(systemName: mvPlayerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(mvPlayerState.videoURL == nil)
            .help(mvPlayerState.isPlaying ? "Pause" : "Play")

            // Current time
            Text(secondsToMinutesAndSeconds(seconds: isSeeking ? sliderValue : mvPlayerState.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 56, alignment: .trailing)

            // Progress slider
            Slider(
                value: $sliderValue,
                in: 0...max(mvPlayerState.duration, 1),
                onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing {
                        mvPlayerState.seek(to: sliderValue)
                    }
                }
            )
            .tint(.white)
            .disabled(mvPlayerState.duration <= 0)

            // Total duration
            Text(secondsToMinutesAndSeconds(seconds: mvPlayerState.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 56, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func close() {
        guard !isDismissing else { return }
        isDismissing = true
        hideControlsTask?.cancel()

        // Single-phase dismiss: the removal transition (.bottomSlide) handles
        // the visual exit without a two-phase dead zone.
        mvPlayerModel.close()
    }

    private func scheduleAutoHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds
            if !Task.isCancelled && mvPlayerState.isPlaying {
                await MainActor.run {
                    showControls = false
                }
            }
        }
    }
}

// MARK: - Volume Popover (MV variant)

struct VolumePopoverButtonMV: View {
    @Binding var volume: Float
    @State private var showVolumePopover = false

    private var volumeIconName: String {
        if volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        Button(action: {
            showVolumePopover.toggle()
        }) {
            Image(systemName: volumeIconName)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(LanguageManager.shared.string("player.volume"))
        .popover(isPresented: $showVolumePopover) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Slider(value: $volume, in: 0...1)
                        .frame(width: 120)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }
}
