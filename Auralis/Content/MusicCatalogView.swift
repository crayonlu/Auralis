//
//  MusicCatalogView.swift
//  Auralis
//
//  Artist, album, and saved-library surfaces.
//

import SwiftUI

struct CatalogArtistResultsView: View {
    let artists: [CloudMusicApi.CatalogArtist]
    let onSelect: (CloudMusicApi.CatalogArtist) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                ForEach(artists) { artist in
                    Button {
                        onSelect(artist)
                    } label: {
                        VStack(spacing: 12) {
                            AsyncImageWithCache(url: artist.artworkURL) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle()
                                    .fill(.quaternary)
                                    .overlay {
                                        Image(systemName: "music.mic")
                                            .font(.largeTitle)
                                            .foregroundStyle(.secondary)
                                    }
                            }
                            .frame(width: 132, height: 132)
                            .clipShape(Circle())

                            Text(artist.name)
                                .font(.headline)
                                .lineLimit(1)

                            if let musicSize = artist.musicSize {
                                Text(String(format: "%d %@", musicSize, LanguageManager.shared.string("catalog.songs")))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
            .padding(.bottom, 100)
        }
    }
}

struct CatalogAlbumResultsView: View {
    let albums: [CloudMusicApi.CatalogAlbum]
    let onSelect: (CloudMusicApi.CatalogAlbum) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                ForEach(albums) { album in
                    Button {
                        onSelect(album)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            AsyncImageWithCache(url: album.artworkURL) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(.quaternary)
                                    .overlay {
                                        Image(systemName: "square.stack")
                                            .font(.largeTitle)
                                            .foregroundStyle(.secondary)
                                    }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            Text(album.name)
                                .font(.headline)
                                .lineLimit(1)
                            Text(album.artist?.name ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
            .padding(.bottom, 100)
        }
    }
}

struct ArtistDetailView: View {
    let artistID: UInt64
    let onSelectAlbum: (CloudMusicApi.CatalogAlbum) -> Void

    @EnvironmentObject private var playlistStatus: PlaylistStatus

    @State private var artist: CloudMusicApi.CatalogArtist?
    @State private var songs: [CloudMusicApi.Song] = []
    @State private var albums: [CloudMusicApi.CatalogAlbum] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var loadingArtistID: UInt64?
    @State private var isFollowed = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let artist {
                    header(artist)

                    if !songs.isEmpty {
                        sectionTitle("catalog.popular_songs")
                        VStack(spacing: 2) {
                            ForEach(Array(songs.prefix(20).enumerated()), id: \.element.id) { index, song in
                                CatalogSongRow(song: song, index: index + 1) {
                                    Task { await play(song, within: songs) }
                                }
                            }
                        }
                    }

                    if !albums.isEmpty {
                        sectionTitle("catalog.albums")
                        CatalogAlbumResultsView(albums: albums, onSelect: onSelectAlbum)
                            .frame(minHeight: 240)
                    }
                } else if isLoading || !hasLoaded {
                    InitialLoadingView(minHeight: 360)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "catalog.load_failed",
                        systemImage: "music.mic",
                        description: Text(errorMessage)
                    )
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 120)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: artistID) { await load() }
    }

    private func header(_ artist: CloudMusicApi.CatalogArtist) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            AsyncImageWithCache(url: artist.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 190, height: 190)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.2), radius: 22, y: 10)

            VStack(alignment: .leading, spacing: 10) {
                Text("catalog.artist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(artist.name)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))

                HStack(spacing: 14) {
                    if let musicSize = artist.musicSize {
                        Label("\(musicSize)", systemImage: "music.note")
                    }
                    if let albumSize = artist.albumSize {
                        Label("\(albumSize)", systemImage: "square.stack")
                    }
                    if let mvSize = artist.mvSize {
                        Label("\(mvSize)", systemImage: "play.rectangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button {
                        Task { await playAll() }
                    } label: {
                        Label("playlist.play_all", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(songs.isEmpty)

                    Button {
                        Task { await toggleFollow() }
                    } label: {
                        Label(
                            isFollowed ? "catalog.following" : "catalog.follow",
                            systemImage: isFollowed ? "star.fill" : "star"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.top, 4)
            }
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.title2.weight(.semibold))
    }

    @MainActor
    private func load() async {
        let requestedID = artistID
        loadingArtistID = requestedID
        isLoading = true
        hasLoaded = false
        errorMessage = nil
        artist = nil
        songs = []
        albums = []
        defer {
            if loadingArtistID == requestedID {
                isLoading = false
                hasLoaded = true
            }
        }

        do {
            async let detail = CloudMusicApi(cacheTtl: 300).artist_detail(id: requestedID)
            async let topSongs = CloudMusicApi(cacheTtl: 300).artist_top_songs(id: requestedID)
            async let artistAlbums = CloudMusicApi(cacheTtl: 300).artist_albums(id: requestedID)
            let result = try await (detail, topSongs, artistAlbums)
            guard loadingArtistID == requestedID, !Task.isCancelled else { return }
            artist = result.0
            songs = result.1
            albums = result.2
            isFollowed = result.0.followed ?? false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func play(_ song: CloudMusicApi.Song, within songs: [CloudMusicApi.Song]) async {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        await playlistStatus.replacePlaylist(songs.map(loadItem), startIndex: index)
    }

    @MainActor
    private func playAll() async {
        await playlistStatus.replacePlaylist(songs.map(loadItem))
    }

    @MainActor
    private func toggleFollow() async {
        do {
            try await CloudMusicApi(cacheTtl: 0).subscribe_artist(
                id: artistID,
                subscribe: !isFollowed
            )
            withAnimation(.easeInOut(duration: 0.18)) {
                isFollowed.toggle()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AlbumDetailView: View {
    let albumID: UInt64

    @EnvironmentObject private var playlistStatus: PlaylistStatus

    @State private var detail: CloudMusicApi.AlbumDetail?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var loadingAlbumID: UInt64?
    @State private var isSubscribed = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let detail {
                    header(detail.album)

                    VStack(spacing: 2) {
                        ForEach(Array(detail.songs.enumerated()), id: \.element.id) { index, song in
                            CatalogSongRow(song: song, index: index + 1) {
                                Task { await play(song, within: detail.songs) }
                            }
                        }
                    }

                    if let description = detail.album.description, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    }
                } else if isLoading || !hasLoaded {
                    InitialLoadingView(minHeight: 360)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "catalog.load_failed",
                        systemImage: "square.stack",
                        description: Text(errorMessage)
                    )
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 120)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: albumID) { await load() }
    }

    private func header(_ album: CloudMusicApi.CatalogAlbum) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            AsyncImageWithCache(url: album.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 18).fill(.quaternary)
            }
            .frame(width: 210, height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 22, y: 10)

            VStack(alignment: .leading, spacing: 10) {
                Text("catalog.album")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(album.name)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .lineLimit(2)
                Text(album.artist?.name ?? "")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                if let publishTime = album.publishTime {
                    Text(Date(timeIntervalSince1970: Double(publishTime) / 1000), style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Button {
                        Task { await playAll() }
                    } label: {
                        Label("playlist.play_all", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(detail?.songs.isEmpty != false)

                    Button {
                        Task { await toggleSubscription() }
                    } label: {
                        Label(
                            isSubscribed ? "catalog.saved" : "catalog.save_album",
                            systemImage: isSubscribed ? "checkmark.circle.fill" : "plus.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.top, 4)
            }
        }
    }

    @MainActor
    private func load() async {
        let requestedID = albumID
        loadingAlbumID = requestedID
        isLoading = true
        hasLoaded = false
        errorMessage = nil
        detail = nil
        defer {
            if loadingAlbumID == requestedID {
                isLoading = false
                hasLoaded = true
            }
        }
        do {
            let result = try await CloudMusicApi(cacheTtl: 300).album_detail(id: requestedID)
            guard loadingAlbumID == requestedID, !Task.isCancelled else { return }
            detail = result
            isSubscribed = detail?.album.isSub ?? false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func play(_ song: CloudMusicApi.Song, within songs: [CloudMusicApi.Song]) async {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        await playlistStatus.replacePlaylist(songs.map(loadItem), startIndex: index)
    }

    @MainActor
    private func playAll() async {
        guard let songs = detail?.songs else { return }
        await playlistStatus.replacePlaylist(songs.map(loadItem))
    }

    @MainActor
    private func toggleSubscription() async {
        do {
            try await CloudMusicApi(cacheTtl: 0).subscribe_album(
                id: albumID,
                subscribe: !isSubscribed
            )
            withAnimation(.easeInOut(duration: 0.18)) {
                isSubscribed.toggle()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CatalogSongRow: View {
    let song: CloudMusicApi.Song
    let index: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .trailing)

                AsyncImageWithCache(url: URL(string: song.al.picUrl.https)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(song.ar.compactMap(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                let duration = song.parseDuration()
                Text(String(format: "%d:%02d", duration.minute, duration.second))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SavedMusicLibraryView: View {
    private enum Selection: Hashable {
        case artist(UInt64)
        case album(UInt64)
    }

    @EnvironmentObject private var playlistStatus: PlaylistStatus

    @State private var artists: [CloudMusicApi.CatalogArtist] = []
    @State private var albums: [CloudMusicApi.CatalogAlbum] = []
    @State private var selection: Selection?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            switch selection {
            case .artist(let id):
                ArtistDetailView(artistID: id) { album in
                    selection = .album(album.id)
                }
                .environmentObject(playlistStatus)
                .toolbar { backToolbar }
            case .album(let id):
                AlbumDetailView(albumID: id)
                    .environmentObject(playlistStatus)
                    .toolbar { backToolbar }
            case nil:
                library
            }
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("library.title")
                    .font(.largeTitle.weight(.bold))

                if (isLoading || !hasLoaded) && artists.isEmpty && albums.isEmpty {
                    InitialLoadingView()
                } else if let errorMessage, artists.isEmpty && albums.isEmpty {
                    ContentUnavailableView(
                        "library.load_failed",
                        systemImage: "books.vertical",
                        description: Text(errorMessage)
                    )
                } else if artists.isEmpty && albums.isEmpty {
                    ContentUnavailableView(
                        "library.empty",
                        systemImage: "books.vertical"
                    )
                } else {
                    if !artists.isEmpty {
                        Text("library.artists").font(.title2.weight(.semibold))
                        CatalogArtistResultsView(artists: artists) { artist in
                            selection = .artist(artist.id)
                        }
                        .frame(minHeight: 220)
                    }

                    if !albums.isEmpty {
                        Text("library.albums").font(.title2.weight(.semibold))
                        CatalogAlbumResultsView(albums: albums) { album in
                            selection = .album(album.id)
                        }
                        .frame(minHeight: 240)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 120)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ToolbarContentBuilder
    private var backToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                selection = nil
            } label: {
                Image(systemName: "chevron.left")
            }
        }
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
            async let savedArtists = CloudMusicApi(cacheTtl: 60).subscribed_artists()
            async let savedAlbums = CloudMusicApi(cacheTtl: 60).subscribed_albums()
            let result = try await (savedArtists, savedAlbums)
            artists = result.0
            albums = result.1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
