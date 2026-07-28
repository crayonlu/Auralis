//
//  DiscoveryLibraryView.swift
//  Auralis
//
//  Native macOS surfaces for Personal FM, recent listening, and listening insights.
//

import AVFoundation
import SwiftUI

struct PodcastsView: View {
    @EnvironmentObject private var playlistStatus: PlaylistStatus

    @State private var recommended: [CloudMusicApi.PodcastRadio] = []
    @State private var subscribed: [CloudMusicApi.PodcastRadio] = []
    @State private var selectedRadio: CloudMusicApi.PodcastRadio?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var isLoadingMore = false
    @State private var hasMoreRecommended = true
    @State private var recommendedOffset = 0
    @State private var paginationFailed = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let selectedRadio {
                PodcastDetailView(radio: selectedRadio)
                    .environmentObject(playlistStatus)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                self.selectedRadio = nil
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                        }
                    }
            } else {
                podcastLibrary
            }
        }
    }

    private var podcastLibrary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("podcasts.title")
                        .font(.largeTitle.weight(.bold))
                    Text("podcasts.subtitle")
                        .foregroundStyle(.secondary)
                }

                if (isLoading || !hasLoaded) && recommended.isEmpty && subscribed.isEmpty {
                    InitialLoadingView()
                } else if let errorMessage, recommended.isEmpty && subscribed.isEmpty {
                    ContentUnavailableView(
                        "podcasts.load_failed",
                        systemImage: "mic.slash",
                        description: Text(errorMessage)
                    )
                } else if recommended.isEmpty && subscribed.isEmpty {
                    ContentUnavailableView(
                        "podcasts.empty",
                        systemImage: "mic"
                    )
                } else {
                    if !subscribed.isEmpty {
                        Text("podcasts.subscribed")
                            .font(.title2.weight(.semibold))
                        radioGrid(subscribed)
                    }

                    Text("podcasts.recommended")
                        .font(.title2.weight(.semibold))
                    radioGrid(recommended, loadsMore: true)
                    recommendationPaginationFooter
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 120)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func radioGrid(
        _ radios: [CloudMusicApi.PodcastRadio],
        loadsMore: Bool = false
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 18)], spacing: 22) {
            ForEach(Array(radios.enumerated()), id: \.element.id) { index, radio in
                Button {
                    selectedRadio = radio
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        AsyncImageWithCache(url: radio.artworkURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.quaternary)
                                .overlay {
                                    Image(systemName: "mic")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        Text(radio.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text(radio.copywriter ?? radio.category ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onAppear {
                    guard loadsMore, index >= max(radios.count - 4, 0) else { return }
                    Task { await loadMoreRecommended() }
                }
            }
        }
    }

    @ViewBuilder
    private var recommendationPaginationFooter: some View {
        if hasMoreRecommended {
            HStack {
                Spacer()
                if paginationFailed {
                    Button {
                        Task { await loadMoreRecommended() }
                    } label: {
                        Label("general.retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                } else if isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            .frame(height: paginationFailed || isLoadingMore ? 52 : 0)
        }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        paginationFailed = false
        recommendedOffset = 0
        hasMoreRecommended = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            async let recommendedTask = CloudMusicApi(cacheTtl: 300).recommended_podcasts()
            async let subscribedTask = CloudMusicApi(cacheTtl: 60).subscribed_podcasts()
            let result = try await (recommendedTask, subscribedTask)
            recommended = result.0
            subscribed = result.1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMoreRecommended() async {
        guard hasLoaded, hasMoreRecommended, !isLoadingMore else { return }
        isLoadingMore = true
        paginationFailed = false
        defer { isLoadingMore = false }

        do {
            let pageSize = 24
            let page = try await CloudMusicApi(cacheTtl: 5 * 60).popular_podcasts_page(
                limit: pageSize,
                offset: recommendedOffset
            )
            recommendedOffset += pageSize
            let existing = Set(recommended.map(\.id))
            recommended.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            hasMoreRecommended = page.hasMore
        } catch {
            paginationFailed = true
        }
    }
}

private struct PodcastDetailView: View {
    let radio: CloudMusicApi.PodcastRadio

    @EnvironmentObject private var playlistStatus: PlaylistStatus

    @State private var episodes: [CloudMusicApi.PodcastEpisode] = []
    @State private var isSubscribed: Bool
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var isLoadingMore = false
    @State private var hasMoreEpisodes = true
    @State private var episodeOffset = 0
    @State private var paginationFailed = false
    @State private var errorMessage: String?

    init(radio: CloudMusicApi.PodcastRadio) {
        self.radio = radio
        _isSubscribed = State(initialValue: radio.subed ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 26) {
                    AsyncImageWithCache(url: radio.artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                    }
                    .frame(width: 190, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 22, y: 10)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(radio.category ?? LanguageManager.shared.string("podcasts.title"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(radio.name)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .lineLimit(3)
                        if let copywriter = radio.copywriter {
                            Text(copywriter)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button {
                                Task { await playAll() }
                            } label: {
                                Label("podcasts.play_latest", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(episodes.isEmpty)

                            Button {
                                Task { await toggleSubscription() }
                            } label: {
                                Label(
                                    isSubscribed ? "podcasts.subscribed_state" : "podcasts.subscribe",
                                    systemImage: isSubscribed ? "checkmark.circle.fill" : "plus.circle"
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                }

                Text("podcasts.episodes")
                    .font(.title2.weight(.semibold))

                if (isLoading || !hasLoaded) && episodes.isEmpty {
                    InitialLoadingView(minHeight: 220)
                } else if let errorMessage, episodes.isEmpty {
                    ContentUnavailableView(
                        "podcasts.load_failed",
                        systemImage: "mic.slash",
                        description: Text(errorMessage)
                    )
                } else if episodes.isEmpty {
                    ContentUnavailableView(
                        "podcasts.episodes_empty",
                        systemImage: "waveform"
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                            Button {
                                Task { await play(episode, index: index) }
                            } label: {
                                HStack(spacing: 14) {
                                    AsyncImageWithCache(url: episode.artworkURL) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Rectangle().fill(.quaternary)
                                    }
                                    .frame(width: 64, height: 64)
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(episode.name)
                                            .fontWeight(.medium)
                                            .lineLimit(2)
                                        HStack(spacing: 10) {
                                            if let createTime = episode.createTime {
                                                Text(
                                                    Date(
                                                        timeIntervalSince1970:
                                                            Double(createTime) / 1000
                                                    ),
                                                    style: .date
                                                )
                                            }
                                            Text(formatDuration(episode.duration))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                guard index >= max(episodes.count - 4, 0) else { return }
                                Task { await loadMoreEpisodes() }
                            }
                        }

                        if hasMoreEpisodes {
                            HStack {
                                Spacer()
                                if paginationFailed {
                                    Button {
                                        Task { await loadMoreEpisodes() }
                                    } label: {
                                        Label("general.retry", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                } else if isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Spacer()
                            }
                            .frame(height: paginationFailed || isLoadingMore ? 56 : 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 120)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await load() }
        .alert(
            "alert.error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("alert.ok") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        paginationFailed = false
        episodeOffset = 0
        hasMoreEpisodes = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let pageSize = 30
            let page = try await CloudMusicApi(cacheTtl: 120).podcast_episodes_page(
                radioID: radio.id,
                limit: pageSize
            )
            episodes = page.items
            episodeOffset = pageSize
            hasMoreEpisodes = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMoreEpisodes() async {
        guard hasLoaded, hasMoreEpisodes, !isLoadingMore else { return }
        isLoadingMore = true
        paginationFailed = false
        defer { isLoadingMore = false }

        do {
            let pageSize = 30
            let page = try await CloudMusicApi(cacheTtl: 120).podcast_episodes_page(
                radioID: radio.id,
                limit: pageSize,
                offset: episodeOffset
            )
            episodeOffset += pageSize
            let existing = Set(episodes.map(\.id))
            episodes.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            hasMoreEpisodes = page.hasMore
        } catch {
            paginationFailed = true
        }
    }

    private func playlistItem(_ episode: CloudMusicApi.PodcastEpisode) -> PlaylistItem {
        PlaylistItem(
            id: episode.mainTrackId,
            url: nil,
            title: episode.name,
            artist: radio.name,
            albumId: radio.id,
            ext: nil,
            duration: CMTime(value: episode.duration, timescale: 1000),
            artworkUrl: episode.artworkURL,
            nsSong: nil,
            sourcePlaylist: nil
        )
    }

    @MainActor
    private func play(_ episode: CloudMusicApi.PodcastEpisode, index: Int) async {
        await playlistStatus.replacePlaylist(episodes.map(playlistItem), startIndex: index)
    }

    @MainActor
    private func playAll() async {
        await playlistStatus.replacePlaylist(episodes.map(playlistItem))
    }

    @MainActor
    private func toggleSubscription() async {
        do {
            try await CloudMusicApi(cacheTtl: 0).subscribe_podcast(
                id: radio.id,
                subscribe: !isSubscribed
            )
            withAnimation(.easeInOut(duration: 0.18)) {
                isSubscribed.toggle()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatDuration(_ milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

struct DailyRecommendationsView: View {
    @EnvironmentObject private var playlistStatus: PlaylistStatus

    @State private var entries: [CloudMusicApi.DailyRecommendationEntry] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("daily.title")
                            .font(.largeTitle.weight(.bold))
                        Text("daily.subtitle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await playAll() }
                    } label: {
                        Label("playlist.play_all", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(entries.isEmpty)
                }

                if (isLoading || !hasLoaded) && entries.isEmpty {
                    InitialLoadingView()
                } else if let errorMessage, entries.isEmpty {
                    ContentUnavailableView(
                        "daily.load_failed",
                        systemImage: "sparkles",
                        description: Text(errorMessage)
                    )
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "daily.empty",
                        systemImage: "sparkles"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 24, alignment: .leading)

                                AsyncImageWithCache(
                                    url: URL(string: entry.song.al.picUrl.https)
                                ) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(.quaternary)
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.song.name)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text(entry.song.ar.compactMap(\.name).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if let reason = entry.reason, !reason.isEmpty {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.thinMaterial, in: Capsule())
                                }

                                Button {
                                    Task { await play(entry) }
                                } label: {
                                    Image(systemName: "play.fill")
                                        .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)

                                Button(role: .destructive) {
                                    Task { await dislike(entry) }
                                } label: {
                                    Image(systemName: "hand.thumbsdown")
                                        .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                                .help("daily.not_interested")
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 120)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            entries = try await CloudMusicApi(cacheTtl: 60).recommend_song_entries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func play(_ entry: CloudMusicApi.DailyRecommendationEntry) async {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        await playlistStatus.replacePlaylist(entries.map { loadItem(song: $0.song) }, startIndex: index)
    }

    @MainActor
    private func playAll() async {
        await playlistStatus.replacePlaylist(entries.map { loadItem(song: $0.song) })
    }

    @MainActor
    private func dislike(_ entry: CloudMusicApi.DailyRecommendationEntry) async {
        do {
            try await CloudMusicApi(cacheTtl: 0).dislike_recommended_song(id: entry.id)
            withAnimation(.easeInOut(duration: 0.2)) {
                entries.removeAll { $0.id == entry.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DiscoveryArtwork: View {
    let url: URL?
    let cornerRadius: CGFloat
    let fallbackSymbol: String

    var body: some View {
        AsyncImageWithCache(url: url) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: fallbackSymbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct RecentArtwork: View {
    let urlStrings: [String]?

    private var urls: [URL] {
        (urlStrings ?? [])
            .compactMap { URL(string: $0.https) }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                Group {
                    switch urls.count {
                    case 0:
                        DiscoveryArtwork(
                            url: nil,
                            cornerRadius: 0,
                            fallbackSymbol: "clock.arrow.circlepath"
                        )
                    case 1:
                        artwork(at: 0)
                    case 2:
                        HStack(spacing: 2) {
                            artwork(at: 0)
                            artwork(at: 1)
                        }
                    default:
                        HStack(spacing: 2) {
                            artwork(at: 0)

                            VStack(spacing: 2) {
                                artwork(at: 1)
                                artwork(at: 2)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func artwork(at index: Int) -> some View {
        DiscoveryArtwork(
            url: urls[index],
            cornerRadius: 0,
            fallbackSymbol: "clock.arrow.circlepath"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PersonalFMView: View {
    @EnvironmentObject private var playlistStatus: PlaylistStatus
    @EnvironmentObject private var userInfo: UserInfo

    @State private var tracks: [CloudMusicApi.PersonalFMTrack] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var activeTrackID: UInt64?

    private var currentTrack: CloudMusicApi.PersonalFMTrack? {
        if let activeTrackID {
            return tracks.first { $0.id == activeTrackID } ?? tracks.first
        }
        return tracks.first
    }

    private var upcomingTracks: [CloudMusicApi.PersonalFMTrack] {
        guard let currentTrack else { return tracks }
        return tracks.filter { $0.id != currentTrack.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if let track = currentTrack {
                    hero(track)

                    if !upcomingTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("personal_fm.up_next")
                                .font(.title3.weight(.semibold))

                            LazyVStack(spacing: 8) {
                                ForEach(upcomingTracks) { item in
                                    trackRow(item)
                                }
                            }
                        }
                    }
                } else if isLoading || !hasLoaded {
                    InitialLoadingView()
                } else if let errorMessage {
                    ContentUnavailableView(
                        "personal_fm.load_failed",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text(errorMessage)
                    )
                } else {
                    ContentUnavailableView(
                        "personal_fm.empty",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 120)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .task {
            await loadMoreIfNeeded(force: true)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("personal_fm.title")
                    .font(.largeTitle.weight(.bold))
                Text("personal_fm.subtitle")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await loadMoreIfNeeded(force: true) }
            } label: {
                Label("general.refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
    }

    private func hero(_ track: CloudMusicApi.PersonalFMTrack) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 30) {
                heroArtwork(track, size: 238)
                heroMetadata(track)
            }

            VStack(alignment: .leading, spacing: 24) {
                heroArtwork(track, size: 218)
                heroMetadata(track)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.06))
        }
    }

    private func heroArtwork(
        _ track: CloudMusicApi.PersonalFMTrack,
        size: CGFloat
    ) -> some View {
        DiscoveryArtwork(
            url: URL(string: track.song.al.picUrl.https),
            cornerRadius: 18,
            fallbackSymbol: "music.note"
        )
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
    }

    private func heroMetadata(_ track: CloudMusicApi.PersonalFMTrack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = track.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }

            Text(track.song.name)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .lineLimit(2)

            Text(track.song.ar.compactMap(\.name).joined(separator: ", "))
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !track.song.albumName.isEmpty {
                Text(track.song.albumName)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await play(track) }
                } label: {
                    Label("personal_fm.play", systemImage: "play.fill")
                        .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    Task { await toggleLike(track.song) }
                } label: {
                    Image(
                        systemName: userInfo.likelist.contains(track.id)
                            ? "heart.fill" : "heart"
                    )
                    .foregroundStyle(userInfo.likelist.contains(track.id) ? .red : .primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("personal_fm.favorite")

                Button {
                    Task { await dislike(track) }
                } label: {
                    Image(systemName: "hand.thumbsdown")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("personal_fm.dislike")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trackRow(_ track: CloudMusicApi.PersonalFMTrack) -> some View {
        Button {
            Task { await play(track) }
        } label: {
            HStack(spacing: 14) {
                DiscoveryArtwork(
                    url: URL(string: track.song.al.picUrl.https),
                    cornerRadius: 10,
                    fallbackSymbol: "music.note"
                )
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.song.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(track.song.ar.compactMap(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer()

                if let reason = track.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .trailing)
                }

                Image(systemName: "play.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            activeTrackID == track.id
                ? Color.accentColor.opacity(0.12)
                : Color.secondary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    @MainActor
    private func loadMoreIfNeeded(force: Bool = false) async {
        guard !isLoading else { return }
        if force {
            tracks = []
        } else if tracks.count >= 6 {
            return
        }

        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            let incoming = try await CloudMusicApi(cacheTtl: 0).personal_fm()
            let known = Set(tracks.map(\.id))
            let newTracks = incoming.filter { !known.contains($0.id) }
            tracks.append(contentsOf: newTracks)
            if activeTrackID != nil, !newTracks.isEmpty {
                await playlistStatus.addItemsToPlaylist(
                    newTracks.map { loadItem(song: $0.song) },
                    continuePlaying: true
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func play(_ track: CloudMusicApi.PersonalFMTrack) async {
        activeTrackID = track.id
        let items = tracks.map { loadItem(song: $0.song) }
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        await playlistStatus.replacePlaylist(items, startIndex: index)
        await loadMoreIfNeeded()
    }

    @MainActor
    private func toggleLike(_ song: CloudMusicApi.Song) async {
        let wasLiked = userInfo.likelist.contains(song.id)
        do {
            try await CloudMusicApi(cacheTtl: 0).like(id: song.id, like: !wasLiked)
            if wasLiked {
                userInfo.likelist.remove(song.id)
            } else {
                userInfo.likelist.insert(song.id)
            }
            saveEncodableState(forKey: "likelist", data: userInfo.likelist)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func dislike(_ track: CloudMusicApi.PersonalFMTrack) async {
        do {
            try await CloudMusicApi(cacheTtl: 0).trash_fm_song(id: track.id)
            tracks.removeAll { $0.id == track.id }
            if activeTrackID == track.id {
                activeTrackID = tracks.first?.id
                if let next = tracks.first {
                    await play(next)
                }
            }
            await loadMoreIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ListeningHistoryView: View {
    private enum Section: String, CaseIterable {
        case recent
        case insights
    }

    @EnvironmentObject private var playlistStatus: PlaylistStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: Section = .recent
    @State private var recentResources: [CloudMusicApi.RecentListenResource] = []
    @State private var summary: CloudMusicApi.ListenSummary?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("listening.title")
                        .font(.largeTitle.weight(.bold))

                    Picker("listening.title", selection: $selection) {
                        Text("listening.recent").tag(Section.recent)
                        Text("listening.insights").tag(Section.insights)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300, alignment: .leading)
                }

                if (isLoading || !hasLoaded) && recentResources.isEmpty && summary == nil {
                    InitialLoadingView()
                } else if let errorMessage, recentResources.isEmpty && summary == nil {
                    ContentUnavailableView(
                        "listening.load_failed",
                        systemImage: "clock.badge.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else {
                    Group {
                        switch selection {
                        case .recent:
                            recentContent
                        case .insights:
                            insightsContent
                        }
                    }
                    .id(selection)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
                    )
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 120)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await load() }
        .refreshable { await load() }
        .animation(
            reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 1),
            value: selection
        )
    }

    @ViewBuilder
    private var recentContent: some View {
        if recentResources.isEmpty {
            ContentUnavailableView(
                "listening.recent_empty",
                systemImage: "clock.arrow.circlepath"
            )
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 240), spacing: 18, alignment: .top)
                ],
                spacing: 18
            ) {
                ForEach(recentResources) { resource in
                    Button {
                        open(resource)
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            RecentArtwork(urlStrings: resource.coverUrlList)
                                .frame(maxWidth: .infinity)

                            Text(resource.title)
                                .font(.headline)
                                .lineLimit(2)
                                .frame(minHeight: 40, alignment: .topLeading)

                            Label(
                                resource.tag ?? resource.resourceType,
                                systemImage: resource.resourceType == "list"
                                    ? "music.note.list" : "clock"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .padding(16)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(resource.resourceType != "list")
                }
            }
        }
    }

    @ViewBuilder
    private var insightsContent: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: 16)],
                    spacing: 16
                ) {
                    insightCard(
                        title: "listening.total_time",
                        value: formatDuration(summary.totalDuration),
                        icon: "waveform.path"
                    )
                    insightCard(
                        title: "listening.today_tracks",
                        value: "\(summary.todaySongs.count)",
                        icon: "music.note.list"
                    )
                }

                if !summary.todaySongs.isEmpty {
                    Text("listening.today")
                        .font(.title3.weight(.semibold))

                    LazyVStack(spacing: 8) {
                        ForEach(summary.todaySongs) { item in
                            Button {
                                Task { await play(item) }
                            } label: {
                                HStack(spacing: 14) {
                                    DiscoveryArtwork(
                                        url: URL(string: item.picUrl?.https ?? ""),
                                        cornerRadius: 10,
                                        fallbackSymbol: "music.note"
                                    )
                                    .frame(width: 52, height: 52)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.songName)
                                            .fontWeight(.medium)
                                            .lineLimit(1)
                                        Text(item.artistName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .layoutPriority(1)

                                    Spacer()
                                    Image(systemName: "play.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30, height: 30)
                                        .background(
                                            Color.secondary.opacity(0.08),
                                            in: Circle()
                                        )
                                }
                                .padding(.vertical, 10)
                                .padding(.leading, 10)
                                .padding(.trailing, 20)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                Color.secondary.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "listening.insights_empty",
                systemImage: "chart.bar"
            )
        }
    }

    private func insightCard(title: LocalizedStringKey, value: String, icon: String) -> some View {
        HStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial, in: Circle())

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

            Spacer(minLength: 18)

            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.trailing)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            async let resources = CloudMusicApi(cacheTtl: 30).recent_listen_list()
            async let listenSummary = CloudMusicApi(cacheTtl: 30).listen_summary()
            let values = try await (resources, listenSummary)
            recentResources = values.0
            summary = values.1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ resource: CloudMusicApi.RecentListenResource) {
        guard resource.resourceType == "list" else { return }
        NotificationCenter.default.post(
            name: .navigateToPlaylist,
            object: nil,
            userInfo: [
                "playlistId": resource.resourceId,
                "playlistName": resource.title,
            ]
        )
    }

    @MainActor
    private func play(_ item: CloudMusicApi.TodayListenSong) async {
        guard
            let song = await CloudMusicApi(cacheTtl: 60).song_detail(ids: [item.songId])?.first
        else { return }
        let _ = await playlistStatus.addItemAndSeekTo(loadItem(song: song), shouldPlay: true)
    }

    private func formatDuration(_ seconds: Int64) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
