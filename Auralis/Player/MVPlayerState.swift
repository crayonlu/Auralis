//
//  MVPlayerState.swift
//  Auralis
//
//  MV (Music Video) playback state management.
//

import AVFoundation
import Combine
import Foundation
import SwiftUI

// MARK: - MV Player Model (presentation state)

@MainActor
final class MVPlayerModel: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var currentMV: CloudMusicApi.MVItem?

    func open(mv: CloudMusicApi.MVItem) {
        currentMV = mv
        withAnimation(.spring(response: 0.38, dampingFraction: 1)) {
            isPresented = true
        }
    }

    func close() {
        withAnimation(.spring(response: 0.38, dampingFraction: 1)) {
            isPresented = false
        }
        // Keep currentMV for fade-out animation; clear after a delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !isPresented {
                currentMV = nil
            }
        }
    }
}

// MARK: - MV Player State (playback state)

@MainActor
final class MVPlayerState: ObservableObject {
    private var player = AVPlayer()
    private var periodicTimeObserverToken: Any?
    private var rateObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?

    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading: Bool = false
    @Published var videoURL: URL?
    @Published var error: String?

    /// Set to false during cleanup to stop observer callbacks from
    /// touching @Published properties after the view is gone.
    private var isLive: Bool = true

    private let timeScale = CMTimeScale(NSEC_PER_SEC)

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        setupObservers()
    }

    nonisolated deinit {
        // Must run synchronously on whatever thread deinit is called from.
        // These AVFoundation calls are all thread-safe.
        if let token = periodicTimeObserverToken {
            player.removeTimeObserver(token)
        }
        rateObserver?.invalidate()
        itemObserver?.invalidate()
        player.replaceCurrentItem(with: nil)
    }

    private func setupObservers() {
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] avPlayer, _ in
            guard let self = self else { return }
            let playing = !avPlayer.rate.isZero
            Task { @MainActor [weak self] in
                guard let self = self, self.isLive else { return }
                if self.isPlaying != playing {
                    self.isPlaying = playing
                }
            }
        }

        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: timeScale), queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self, self.isLive else { return }
                let newTime = self.player.currentTime().seconds
                if Int(self.currentTime) != Int(newTime) {
                    self.currentTime = newTime
                }
                if let item = self.player.currentItem {
                    let d = item.duration.seconds
                    if d.isFinite && d > 0 && Int(self.duration) != Int(d) {
                        self.duration = d
                    }
                }
            }
        }
    }

    // MARK: - Loading

    func loadMV(_ mv: CloudMusicApi.MVItem) async {
        // Reset state
        self.error = nil
        self.isLoading = true
        self.currentTime = 0
        self.duration = 0
        self.videoURL = nil

        // Fetch MV URL from API
        guard let urlData = await CloudMusicApi(cacheTtl: 0).mv_url(id: mv.id),
              let urlString = urlData.url,
              !urlString.isEmpty
        else {
            if isLive {
                self.error = LanguageManager.shared.string("mv.error_load_failed")
                self.isLoading = false
            }
            return
        }

        let httpsURLString = urlString.https
        guard let url = URL(string: httpsURLString) else {
            if isLive {
                self.error = LanguageManager.shared.string("mv.error_load_failed")
                self.isLoading = false
            }
            return
        }

        self.videoURL = url

        let item = AVPlayerItem(url: url)

        // Observe item readiness
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self, self.isLive else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.isLoading = false
                    let d = observedItem.duration.seconds
                    if d.isFinite && d > 0 {
                        self.duration = d
                    }
                case .failed:
                    self.isLoading = false
                    self.error = observedItem.error?.localizedDescription
                        ?? LanguageManager.shared.string("mv.error_load_failed")
                default:
                    break
                }
            }
        }

        self.player.replaceCurrentItem(with: item)

        // Auto-play once ready
        play()
    }

    // MARK: - Playback controls

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: Double) {
        let target = CMTime(seconds: time, preferredTimescale: timeScale)
        player.seek(to: target)
        currentTime = time
    }

    func seekByOffset(_ offset: Double) {
        let newTime = max(0, min(duration, currentTime + offset))
        seek(to: newTime)
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    /// Tear down all playback resources synchronously.
    /// Must be called before the view is removed to prevent
    /// observer callbacks from deadlocking the main thread.
    func cleanup() {
        // Stop all observer callbacks first
        isLive = false

        // Remove periodic time observer (prevents 0.25s callbacks)
        if let token = periodicTimeObserverToken {
            player.removeTimeObserver(token)
            periodicTimeObserverToken = nil
        }

        // Invalidate KVO observers
        rateObserver?.invalidate()
        rateObserver = nil
        itemObserver?.invalidate()
        itemObserver = nil

        // Stop and release the player item
        player.pause()
        player.replaceCurrentItem(with: nil)

        // Reset published state synchronously (no Task wrapper needed,
        // we're already on @MainActor)
        isPlaying = false
        currentTime = 0
        duration = 0
        videoURL = nil
        isLoading = false
        error = nil
    }

    var avPlayer: AVPlayer {
        player
    }
}
