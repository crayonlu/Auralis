//
//  Auralis
//
//  Created by crayonlu on 2024/5/18.
//

import Foundation
import SwiftUI

// MARK: - Daily Recommend Card

/// Styled to match `PlaylistCardView` so it can sit inline in the
/// recommended playlists row. The cover is an SF Symbol (day of month)
/// rendered on a placeholder tile.
struct DailyRecommendCardView: View {
    let item: CloudMusicApi.RecommandPlaylistItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))

                Image(systemName: item.picUrl)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundColor(.primary)
            }
            .frame(width: 140, height: 140)

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(.primary)
                .frame(width: 140, alignment: .leading)
        }
        .frame(width: 140)
    }
}

// MARK: - Navigation Path

enum ExploreNavigationPath: Hashable {
    case playlist(UInt64, String)  // id, name
    case searchResult([CloudMusicApi.Song])

    var name: String {
        switch self {
        case let .playlist(_, name):
            return name
        case .searchResult:
            return LanguageManager.shared.string("explore.search_results")
        }
    }

    var id: UInt64 {
        switch self {
        case let .playlist(id, _):
            return id
        case let .searchResult(songs):
            return songs.map { $0.id }.reduce(0, +)
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 0)
    }
}

// MARK: - Playlist Horizontal Card

struct PlaylistCardView: View {
    let item: CloudMusicApi.RecommandPlaylistItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImageWithCache(url: URL(string: item.picUrl.https)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
            }
            .frame(width: 140, height: 140)
            .cornerRadius(8)
            .clipped()

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(.primary)
                .frame(width: 140, alignment: .leading)
        }
        .frame(width: 140)
    }
}

// MARK: - Song Horizontal Card

struct SongCardView: View {
    let song: CloudMusicApi.Song

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImageWithCache(url: URL(string: song.al.picUrl.https)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
            }
            .frame(width: 100, height: 100)
            .cornerRadius(6)
            .clipped()

            Text(song.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundColor(.primary)
                .frame(width: 100, alignment: .leading)

            if let artist = song.ar.first?.name {
                Text(artist)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)
            }
        }
        .frame(width: 100)
    }
}

// MARK: - MV Card

struct MvCardView: View {
    let mv: CloudMusicApi.MVItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .center) {
                AsyncImageWithCache(url: URL(string: (mv.picUrl ?? "").https)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                }
                .frame(width: 200, height: 120)
                .cornerRadius(8)
                .clipped()

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.white)
                    .shadow(radius: 4)
            }

            Text(mv.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundColor(.primary)
                .frame(width: 200, alignment: .leading)

            if let artist = mv.artistName {
                Text(artist)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
                    .frame(width: 200, alignment: .leading)
            }
        }
        .frame(width: 200)
    }
}

// MARK: - Toplist Row

struct ToplistRowView: View {
    let toplist: CloudMusicApi.ToplistItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImageWithCache(url: URL(string: (toplist.coverImgUrl ?? "").https)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
            }
            .frame(width: 80, height: 80)
            .cornerRadius(6)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(toplist.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if let desc = toplist.description {
                    Text(desc)
                        .font(.caption2)
                        .lineLimit(2)
                        .foregroundColor(.secondary)
                }

                if let tracks = toplist.tracks {
                    ForEach(tracks.prefix(3), id: \.first) { track in
                        Text("\(track.songName) - \(track.artistName)")
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Explore View

struct ExploreView: View {
    // MARK: - State

    @State private var recommendPlaylists = [CloudMusicApi.RecommandPlaylistItem]()
    @State private var toplists = [CloudMusicApi.ToplistItem]()
    @State private var newSongs = [CloudMusicApi.Song]()
    @State private var mvs = [CloudMusicApi.MVItem]()

    @State var recommendResource: [CloudMusicApi.RecommandPlaylistItem] = {
        let currentDate = Date()
        let calendar = Calendar.current
        let day = calendar.component(.day, from: currentDate)
        let dialyRecommend = CloudMusicApi.RecommandPlaylistItem(
            creator: nil,
            picUrl: "\(day).square",
            userId: 0,
            id: CloudMusicApi.RecommandSongPlaylistId,
            name: LanguageManager.shared.string("explore.daily_recommend"),
            playcount: 0,
            trackCount: 0
        )
        return [dialyRecommend]
    }()

    @State private var searchText = ""
    @State private var searchSuggestions = [CloudMusicApi.Song]()
    @State private var task: Task<Void, Never>?
    @State private var isLoading = false
    @State private var activeNavigationPath: ExploreNavigationPath?

    private let isInitialized: Bool

    @EnvironmentObject var playlistStatus: PlaylistStatus
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject var playStatus: PlayStatus
    @EnvironmentObject var playingDetailModel: PlayingDetailModel
    @EnvironmentObject private var playerControlState: PlayerControlState

    init(isInitialized: Bool) {
        self.isInitialized = isInitialized
    }

    // MARK: - Navigation

    private func gotoPlaylist(id: UInt64, name: String) {
        activeNavigationPath = ExploreNavigationPath.playlist(id, name)
    }

    private func displaySearchResult(_ result: [CloudMusicApi.Song]) {
        activeNavigationPath = ExploreNavigationPath.searchResult(result)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            if let activePath = activeNavigationPath {
                // Navigation destination
                ZStack(alignment: .bottom) {
                    let metadata = switch activePath {
                    case let .playlist(id, name):
                        PlaylistMetadata.netease(id, name)
                    case let .searchResult(result):
                        PlaylistMetadata.songs(
                            result, activePath.id,
                            LanguageManager.shared.string("explore.search_results"))
                    }

                    PlayListView(playlistMetadata: metadata)
                        .environmentObject(userInfo)
                        .environmentObject(playlistStatus)
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button(action: {
                                    activeNavigationPath = nil
                                }) {
                                    Image(systemName: "chevron.left")
                                }
                                .help("Back")
                            }
                        }

                    PlayerControlView()
                        .environmentObject(userInfo)
                        .environmentObject(playlistStatus)
                        .environmentObject(playStatus)
                        .environmentObject(playingDetailModel)
                        .environmentObject(playerControlState)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                }
            } else {
                // Main explore content
                ZStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // Recommended Playlists (Daily Recommend pinned first)
                            if recommendResource.first != nil || !recommendPlaylists.isEmpty {
                                SectionHeader(title: LanguageManager.shared.string("explore.recommended_playlists"))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 12) {
                                        if let daily = recommendResource.first {
                                            DailyRecommendCardView(item: daily)
                                                .onTapGesture {
                                                    gotoPlaylist(id: daily.id, name: daily.name)
                                                }
                                        }
                                        ForEach(recommendPlaylists) { item in
                                            PlaylistCardView(item: item)
                                                .onTapGesture {
                                                    gotoPlaylist(id: item.id, name: item.name)
                                                }
                                        }
                                    }
                                    .padding(.horizontal, 0)
                                }
                                .frame(height: 190)
                            }

                            // 4. Top Charts
                            if !toplists.isEmpty {
                                SectionHeader(title: LanguageManager.shared.string("explore.top_charts"))
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(toplists.prefix(3)) { toplist in
                                        ToplistRowView(toplist: toplist)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                gotoPlaylist(id: toplist.id, name: toplist.name)
                                            }
                                        if toplist.id != toplists.prefix(3).last?.id {
                                            Divider()
                                        }
                                    }
                                }
                                .padding(.horizontal, 0)
                            }

                            // 5. New Songs
                            if !newSongs.isEmpty {
                                SectionHeader(title: LanguageManager.shared.string("explore.new_songs"))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 12) {
                                        ForEach(newSongs, id: \.self) { song in
                                            SongCardView(song: song)
                                        }
                                    }
                                    .padding(.horizontal, 0)
                                }
                                .frame(height: 150)
                            }

                            // 6. Recommended MVs
                            if !mvs.isEmpty {
                                SectionHeader(title: LanguageManager.shared.string("explore.recommended_mvs"))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 12) {
                                        ForEach(mvs) { mv in
                                            MvCardView(mv: mv)
                                        }
                                    }
                                    .padding(.horizontal, 0)
                                }
                                .frame(height: 180)
                            }

                            // Bottom padding for player bar
                            Color.clear.frame(height: 80)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }

                    if isLoading {
                        LoadingIndicatorView()
                    }
                }
                .searchable(
                    text: $searchText,
                    suggestions: {
                        ForEach(searchSuggestions, id: \.self) { suggestion in
                            Text(
                                suggestion.name + " - "
                                    + (suggestion.albumName.isEmpty
                                        ? LanguageManager.shared.string("general.unknown_album")
                                        : suggestion.albumName)
                            )
                            .lineLimit(1)
                            .searchCompletion(
                                "##%%ID" + String(suggestion.id))
                        }
                    }
                )
                .onSubmit(of: .search) {
                    Task {
                        isLoading = true
                        defer { isLoading = false }

                        if searchText.starts(with: "##%%ID") {
                            let data = searchText.dropFirst(6)
                            let id = UInt64(data) ?? 0

                            if let res = await CloudMusicApi(cacheTtl: 5 * 60).song_detail(ids: [id]) {
                                displaySearchResult(res)
                            }

                            defer { searchText = "" }
                            return
                        }

                        if let res = await CloudMusicApi(cacheTtl: 5 * 60).search(keyword: searchText) {
                            let res = res.map { $0.convertToSong() }
                            displaySearchResult(res)
                        }
                    }
                }
                .onChange(of: searchText) { _, text in
                    task?.cancel()

                    guard !searchText.isEmpty else {
                        return
                    }

                    task = Task {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(0.3 * 1_000_000_000))
                        } catch {
                            return
                        }

                        if let res = await CloudMusicApi(cacheTtl: 1 * 60).search_suggest(
                            keyword: text)
                        {
                            DispatchQueue.main.async {
                                self.searchSuggestions = res.map { $0.convertToSong() }
                            }
                        }
                    }
                }
            }
        }
        .task(id: isInitialized) {
            guard isInitialized else { return }

            // Load explore data in parallel
            async let playlistsTask = CloudMusicApi(cacheTtl: 5 * 60).personalized()
            async let toplistsTask = CloudMusicApi(cacheTtl: 5 * 60).toplist_detail()
            async let newsongsTask = CloudMusicApi(cacheTtl: 5 * 60).personalized_newsong()
            async let mvsTask = CloudMusicApi(cacheTtl: 5 * 60).personalized_mv()

            // Daily recommend (only if logged in)
            if userInfo.profile != nil {
                if let res = await CloudMusicApi(cacheTtl: 5 * 60).recommend_resource() {
                    recommendResource.append(contentsOf: res)
                }
            }

            if let res = await playlistsTask {
                recommendPlaylists = res
            }
            if let res = await toplistsTask {
                toplists = res
            }
            if let res = await newsongsTask {
                newSongs = res
            }
            if let res = await mvsTask {
                mvs = res
            }
        }
    }
}
