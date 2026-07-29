//
//  Auralis
//
//  Created by Elsa on 2024/12/13.
//

import Foundation
import IOKit.pwr_mgt

enum DoubleClickPlayAction: Int, CaseIterable, Identifiable {
    case replacePlaylistWithSongList = 0
    case appendSongToPlaylist = 1

    var id: Int { rawValue }
}

enum AudioQuality: String, CaseIterable, Identifiable {
    case standard = "standard"
    case higher = "higher"
    case exhigh = "exhigh"
    case lossless = "lossless"
    case hires = "hires"
    case jymaster = "jymaster"

    var id: String { rawValue }
}

class AppSettings: ObservableObject {
    @Published var preventSleepWhenPlaying: Bool = false {
        didSet {
            UserDefaults.standard.set(preventSleepWhenPlaying, forKey: "preventSleepWhenPlaying")
            updateSleepAssertion()
        }
    }

    @Published var showTimestamp: Bool = false {
        didSet {
            UserDefaults.standard.set(showTimestamp, forKey: "showTimestamp")
        }
    }

    @Published var showRoma: Bool = false {
        didSet {
            UserDefaults.standard.set(showRoma, forKey: "showRoma")
        }
    }

    @Published var doubleClickPlayAction: DoubleClickPlayAction = .appendSongToPlaylist {
        didSet {
            UserDefaults.standard.set(doubleClickPlayAction.rawValue, forKey: "doubleClickPlayAction")
        }
    }

    @Published var audioQuality: AudioQuality = .jymaster {
        didSet {
            UserDefaults.standard.set(audioQuality.rawValue, forKey: "audioQuality")
        }
    }

    /// Maximum on-disk music cache size in GB. 0 means unlimited.
    @Published var maxCacheSizeGB: Int = 3 {
        didSet {
            UserDefaults.standard.set(maxCacheSizeGB, forKey: "maxCacheSizeGB")
            if !isInitializing {
                MusicCacheManager.shared.enforceLimit(limitGB: maxCacheSizeGB)
            }
        }
    }

    private var sleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var isPlayingMusic: Bool = false
    /// Guards against triggering `enforceLimit` while still inside `init`
    /// (where `@Published` didSet fires for the initial assignment).
    private var isInitializing: Bool = true

    static let shared = AppSettings()

    private init() {
        preventSleepWhenPlaying = UserDefaults.standard.bool(forKey: "preventSleepWhenPlaying")
        showTimestamp = UserDefaults.standard.bool(forKey: "showTimestamp")
        showRoma = UserDefaults.standard.bool(forKey: "showRoma")
        let rawValue =
            UserDefaults.standard.object(forKey: "doubleClickPlayAction") as? Int
            ?? DoubleClickPlayAction.appendSongToPlaylist.rawValue
        doubleClickPlayAction =
            DoubleClickPlayAction(rawValue: rawValue) ?? .appendSongToPlaylist
        if let rawQuality = UserDefaults.standard.string(forKey: "audioQuality"),
            let quality = AudioQuality(rawValue: rawQuality)
        {
            audioQuality = quality
        }
        maxCacheSizeGB =
            (UserDefaults.standard.object(forKey: "maxCacheSizeGB") as? Int) ?? 3
        setupPlaybackObserver()
        isInitializing = false
    }
    
    private func setupPlaybackObserver() {
        NotificationCenter.default.addObserver(
            forName: .playbackStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let isPlaying = notification.userInfo?["isPlaying"] as? Bool {
                self?.isPlayingMusic = isPlaying
                self?.updateSleepAssertion()
            }
        }
    }
    
    private func updateSleepAssertion() {
        if preventSleepWhenPlaying && isPlayingMusic {
            enableSleepAssertion()
        } else {
            disableSleepAssertion()
        }
    }
    
    private func enableSleepAssertion() {
        guard sleepAssertionID == IOPMAssertionID(0) else { return }
        
        let reason = "Preventing sleep while music is playing" as CFString
        
        // Use "PreventUserIdleDisplaySleep" instead of kIOPMAssertionTypeNoIdleSleep:
        // NoIdleSleep only prevents system idle sleep but still lets the display
        // sleep/dim, which is what users actually expect "prevent sleep" to stop.
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
        
        if result != kIOReturnSuccess {
            print("Failed to create sleep assertion: \(result)")
        } else {
            print("Sleep assertion enabled")
        }
    }
    
    private func disableSleepAssertion() {
        guard sleepAssertionID != IOPMAssertionID(0) else { return }
        
        let result = IOPMAssertionRelease(sleepAssertionID)
        if result != kIOReturnSuccess {
            print("Failed to release sleep assertion: \(result)")
        } else {
            print("Sleep assertion disabled")
        }
        sleepAssertionID = IOPMAssertionID(0)
    }
    
    deinit {
        disableSleepAssertion()
        NotificationCenter.default.removeObserver(self)
    }
}

extension Notification.Name {
    static let playbackStateChanged = Notification.Name("playbackStateChanged")
}
