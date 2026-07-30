//
//  Auralis
//
//  Created by Elsa on 2024/4/20.
//

import CryptoKit
import Foundation
import os

enum RequestError: Error {
    case error(Error)
    case noData
    case errorCode((Int, String))
    case Request(String)
    case unknown

    public var localizedDescription: String {
        switch self {
        case .error(let error):
            return error.localizedDescription
        case .noData:
            return "No data"
        case .errorCode((let code, let message)):
            return "\(code): \(message)"
        case .Request(let message):
            return message
        case .unknown:
            return "Unknown error"
        }
    }
}

struct ServerError: Decodable, Error {
    let code: Int
    let msg: String?
    let message: String?
}

enum IntOrString: Decodable, Hashable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        throw DecodingError.typeMismatch(
            IntOrString.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a String or an Int but found neither"))
    }

    var stringValue: String {
        switch self {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }
}

class SharedCacheManager {
    class CacheItem {
        let value: Any
        let expiryDate: Date?

        init(value: Any, ttl: TimeInterval) {
            self.value = value
            if ttl == -1 {
                self.expiryDate = nil
            } else {
                self.expiryDate = Date().addingTimeInterval(ttl)
            }
        }

        var isExpired: Bool {
            if let expiryDate = expiryDate {
                return Date() > expiryDate
            }
            return false
        }
    }

    private var cache: [String: CacheItem] = [:]
    private let cacheQueue = DispatchQueue(label: "SharedCacheManagerQueue")

    static let shared = SharedCacheManager()

    private init() {
        startPeriodicCleanup()
    }

    func md5(_ data: String) -> String {
        let md5Data = Insecure.MD5.hash(data: Data(data.utf8))
        return md5Data.map { String(format: "%02hhx", $0) }.joined()
    }

    func set(value: Any, for query: String, ttl: TimeInterval) {
        cacheQueue.async {
            self.cache[self.md5(query)] = CacheItem(value: value, ttl: ttl)
        }
    }

    func get(for query: String) -> Any? {
        var result: Any? = nil
        let query = md5(query)
        cacheQueue.sync {
            if let item = self.cache[query], !item.isExpired {
                result = item.value
            } else {
                self.cache.removeValue(forKey: query)
            }
        }
        return result
    }

    func clear() {
        cacheQueue.async {
            self.cache.removeAll()
        }
    }

    func invalidate(memberName: String, data: [String: Any]) {
        var data = data
        if let cookie = CloudMusicApi().getCookie() {
            data["cookie"] = cookie
        }
        guard
            let jsonData = try? JSONSerialization.data(
                withJSONObject: data, options: [.sortedKeys]
            ),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            return
        }

        let hashedKey = md5(memberName + jsonString)

        cacheQueue.async {
            self.cache.removeValue(forKey: hashedKey)
        }
    }

    private func startPeriodicCleanup() {
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.cleanupExpiredItems()
        }
    }

    private func cleanupExpiredItems() {
        cacheQueue.async {
            let now = Date()
            self.cache = self.cache.filter { key, item in
                if let expiryDate = item.expiryDate {
                    return expiryDate > now
                }
                return true
            }
        }
    }

    deinit {
        clear()
    }
}

class CloudMusicApi {
    struct Page<Item> {
        let items: [Item]
        let hasMore: Bool
    }

    let cacheTtl: TimeInterval  // 0 means no cache

    init(cacheTtl: TimeInterval = 0) {
        self.cacheTtl = cacheTtl
    }

    static let RecommandSongPlaylistId: UInt64 = 0

    private func transportError(from data: Data) -> RequestError? {
        // The C++ bridge answers {"code":502,"msg":...} (with no business fields)
        // whenever the underlying QNetworkReply fails — connection refused,
        // timeouts, the network not being ready right after the machine wakes,
        // etc. Any 502 here is a transport failure, so treat them all as errors
        // instead of letting them leak into per-endpoint decoders, where they
        // would otherwise surface as bogus "missing key" decoding alerts.
        guard let serverError = data.asType(ServerError.self, silent: true),
            serverError.code == 502
        else { return nil }
        let message = serverError.msg ?? serverError.message ?? ""
        return .errorCode((serverError.code, message))
    }

    /// Logs an unexpected (non-200 or undecodable) API response for diagnosis
    /// instead of showing the generic "decoding error" alert. Such responses are
    /// usually recoverable conditions — a transient network error, or an empty /
    /// non-JSON body — rather than bugs, so we keep them out of the user's face
    /// while preserving the raw payload in the logs (Console.app / Xcode console)
    /// for bug reports.
    private func logUnexpectedResponse(
        _ data: Data, member: String, code: Int? = nil
    ) {
        let logger = Logger(subsystem: "com.cyncyn.Auralis", category: "API")
        var body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        if body.count > 2000 {
            body = String(body.prefix(2000)) + "…<truncated>"
        }
        let reason = code.map { "code=\($0)" } ?? "undecodable"
        logger.error("[\(member)] unexpected response (\(reason)): \(body, privacy: .public)")
        #if DEBUG
            print("[\(member)] unexpected response (\(reason)): \(body)")
        #endif
    }

    struct Profile: Codable, Equatable {
        let avatarUrl: String
        let nickname: String
        let userId: UInt64
    }

    struct PlayListItem: Identifiable, Codable, Equatable, Hashable {
        let subscribed: Bool
        let coverImgUrl: String
        let name: String
        let id: UInt64
        let createTime: Int
        let userId: Int
        let privacy: Int
        let description: String?
        let creator: Profile
        let trackCount: UInt64?
        let cloudTrackCount: UInt64?

        static func == (lhs: CloudMusicApi.PlayListItem, rhs: CloudMusicApi.PlayListItem) -> Bool {
            return lhs.id == rhs.id
                && lhs.name == rhs.name
                && lhs.subscribed == rhs.subscribed
                && lhs.coverImgUrl == rhs.coverImgUrl
                && lhs.trackCount == rhs.trackCount
                && lhs.cloudTrackCount == rhs.cloudTrackCount
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    struct RecommandPlaylistItem: Codable, Identifiable, Equatable {
        static func == (
            lhs: CloudMusicApi.RecommandPlaylistItem, rhs: CloudMusicApi.RecommandPlaylistItem
        ) -> Bool {
            return lhs.id == rhs.id
        }

        let creator: Profile?
        let picUrl: String
        let userId: UInt64?
        let id: UInt64
        let name: String
        let playcount: UInt64?
        let trackCount: UInt64?
    }

    struct Quality: Codable {
        let br: UInt64
        let size: UInt64
    }

    struct Album: Codable {
        let id: UInt64
        let name: String?
        let pic: UInt64
        let picUrl: String
        let tns: [String]
    }

    struct Artist: Codable {
        let id: UInt64
        let name: String?

        let alias: [String]
        let tns: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case alias
            case tns
        }

        init(id: UInt64, name: String?, alias: [String] = [], tns: [String] = []) {
            self.id = id
            self.name = name
            self.alias = alias
            self.tns = tns
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UInt64.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            alias = try container.decodeIfPresent([String].self, forKey: .alias) ?? []
            tns = try container.decodeIfPresent([String].self, forKey: .tns) ?? []
        }
    }

    struct CloudMusic: Codable {
        let alb: String
        let ar: String
        let br: UInt64
        let fn: String
        let sn: String
        let uid: UInt64
    }

    struct CloudFile: Codable, Identifiable, Hashable, Equatable {
        static func == (lhs: CloudMusicApi.CloudFile, rhs: CloudMusicApi.CloudFile) -> Bool {
            return lhs.pcId == rhs.pcId
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(pcId)
        }

        let fileName: String
        let fileSize: Int64
        let matchType: String
        let pcId: UInt64
        let privateCloud: PrivateCloud
        let simpleSong: SimpleSong?

        var id: UInt64 { pcId }

        struct PrivateCloud: Codable {
            let songId: UInt64
        }

        struct SimpleSong: Codable {
            let id: UInt64?
            let name: String?
            let al: SimpleAlbum?
            let ar: [SimpleArtist]?

            struct SimpleAlbum: Codable {
                let id: UInt64?
                let name: String?
            }

            struct SimpleArtist: Codable {
                let name: String?
            }
        }

        func parseFileSize() -> String {
            let bytes = Double(fileSize)
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(bytes))
        }

        var isMatched: Bool {
            return matchType == "matched"
        }
    }

    struct CloudFilesResponse: Codable {
        let code: Int
        let count: Int
        let data: [CloudFile]
    }

    enum Fee: Int, Codable {
        case free = 0  // 免费或无版权
        case vip = 1  // VIP 歌曲
        case album = 4  // 购买专辑
        case trial = 8  // 非会员可免费播放低音质，会员可播放高音质及下载
    }

    struct Song: Codable, Identifiable, Hashable, Equatable {
        static func == (lhs: CloudMusicApi.Song, rhs: CloudMusicApi.Song) -> Bool {
            return lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        let name: String
        let id: UInt64

        let al: Album
        let ar: [Artist]

        let alia: [String]
        let tns: [String]?

        let fee: Fee
        let originCoverType: Int?

        let mv: UInt64  // MV id

        let dt: Int64  // 歌曲时长

        let hr: Quality?  // Hi-Res 质量文件信息
        let sq: Quality?  // 无损质量文件信息
        let h: Quality?  // 高质量文件信息
        let m: Quality?  // 中等质量文件信息
        let l: Quality?  // 低质量文件信息

        let publishTime: Int64  // 毫秒为单位的 Unix 时间戳

        let pc: CloudMusic?

        func parseDuration() -> (minute: Int64, second: Int64) {
            let second = dt / 1000
            let minute = second / 60
            return (minute, second % 60)
        }

        func getHighestQuality() -> Quality? {
            return hr ?? sq ?? h ?? m ?? l
        }

        var albumName: String {
            al.name ?? ""
        }
    }

    struct Privilege: Decodable {
        let downloadMaxBrLevel: String
        let downloadMaxbr: UInt64
        let fee: Int
        let id: UInt64
        let maxBrLevel: String
        let maxbr: UInt64
        let playMaxBrLevel: String
        let playMaxbr: UInt64
    }

    struct SongData: Decodable {
        let br: UInt64
        // Podcast URLs can be returned as a regular MP3 while these
        // quality-related fields are explicitly null.
        let encodeType: String?
        let id: UInt64
        let level: String?
        let size: UInt64
        let time: Int64
        let type: String?
        // NetEase returns null when a song is unavailable in the current
        // region/account, even though the rest of the SongData object exists.
        let url: String?
    }

    struct PersonalFMTrack: Identifiable, Hashable {
        let song: Song
        let reason: String?

        var id: UInt64 { song.id }
    }

    struct DailyRecommendationEntry: Identifiable, Hashable {
        let song: Song
        let reason: String?

        var id: UInt64 { song.id }
    }

    struct RecentListenResource: Decodable, Identifiable, Hashable {
        let resourceId: UInt64
        let resourceType: String
        let title: String
        let tag: String?
        let coverUrlList: [String]?
        let playOrUpdateTime: Int64?
        let landingUrl: String?

        var id: String { "\(resourceType)-\(resourceId)" }
        var coverURL: URL? {
            guard let value = coverUrlList?.first else { return nil }
            return URL(string: value.https)
        }
    }

    struct TodayListenSong: Decodable, Identifiable, Hashable {
        struct Artist: Decodable, Hashable {
            let artistId: UInt64
            let artistName: String
        }

        let songId: UInt64
        let songName: String
        let aliasName: String?
        let artists: [Artist]
        let picUrl: String?
        let lastPlayTime: Int64?
        let redStar: Bool?

        var id: UInt64 { songId }
        var artistName: String { artists.map(\.artistName).joined(separator: ", ") }
    }

    struct ListenSummary: Hashable {
        let totalDuration: Int64
        let todaySongs: [TodayListenSong]
    }

    struct CatalogArtist: Decodable, Identifiable, Hashable {
        let id: UInt64
        let name: String
        let avatarURLString: String?
        let coverURLString: String?
        let briefDescription: String?
        let albumSize: Int?
        let musicSize: Int?
        let mvSize: Int?
        let followed: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case avatar
            case img1v1Url
            case cover
            case picUrl
            case briefDesc
            case albumSize
            case musicSize
            case mvSize
            case followed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UInt64.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            avatarURLString =
                try container.decodeIfPresent(String.self, forKey: .avatar)
                ?? container.decodeIfPresent(String.self, forKey: .img1v1Url)
            coverURLString =
                try container.decodeIfPresent(String.self, forKey: .cover)
                ?? container.decodeIfPresent(String.self, forKey: .picUrl)
            briefDescription = try container.decodeIfPresent(String.self, forKey: .briefDesc)
            albumSize = try container.decodeIfPresent(Int.self, forKey: .albumSize)
            musicSize = try container.decodeIfPresent(Int.self, forKey: .musicSize)
            mvSize = try container.decodeIfPresent(Int.self, forKey: .mvSize)
            followed = try container.decodeIfPresent(Bool.self, forKey: .followed)
        }

        var artworkURL: URL? {
            guard let value = coverURLString ?? avatarURLString else { return nil }
            return URL(string: value.https)
        }
    }

    struct CatalogAlbum: Decodable, Identifiable, Hashable {
        struct Artist: Decodable, Hashable {
            let id: UInt64
            let name: String
        }

        let id: UInt64
        let name: String
        let picUrl: String?
        let publishTime: Int64?
        let size: Int?
        let description: String?
        let company: String?
        let artist: Artist?
        let isSub: Bool?

        var artworkURL: URL? {
            guard let picUrl else { return nil }
            return URL(string: picUrl.https)
        }
    }

    struct AlbumDetail: Hashable {
        let album: CatalogAlbum
        let songs: [Song]
    }

    struct PodcastRadio: Decodable, Identifiable, Hashable {
        let id: UInt64
        let name: String
        let picUrl: String?
        let category: String?
        let copywriter: String?
        let programCount: Int?
        let playCount: Int64?
        let subCount: Int?
        let subed: Bool?

        var artworkURL: URL? {
            guard let picUrl else { return nil }
            return URL(string: picUrl.https)
        }
    }

    struct PodcastEpisode: Decodable, Identifiable, Hashable {
        let id: UInt64
        let mainTrackId: UInt64
        let name: String
        let description: String?
        let duration: Int64
        let coverUrl: String?
        let createTime: Int64?
        let listenerCount: Int64?
        let likedCount: Int?
        let radio: PodcastRadio?

        var artworkURL: URL? {
            guard let coverUrl else { return radio?.artworkURL }
            return URL(string: coverUrl.https)
        }
    }

    // MARK: - Explore Models
    struct BannerItem: Codable, Identifiable {
        let targetId: UInt64
        let targetType: Int
        let imageUrl: String
        let typeTitle: String?

        var id: UInt64 { targetId }
    }

    struct ToplistItem: Codable, Identifiable {
        let id: UInt64
        let name: String
        let coverImgUrl: String?
        let description: String?
        let updateFrequency: String?
        let tracks: [ToplistTrack]?

        struct ToplistTrack: Codable {
            let first: String?
            let second: String?

            var artistName: String { first ?? "" }
            var songName: String { second ?? "" }
        }
    }

    struct MVItem: Codable, Identifiable {
        let id: UInt64
        let name: String
        let picUrl: String?
        let artistName: String?
        let playCount: Int?
        let duration: Int?
        let copywriter: String?
    }

    struct MVUrlData: Codable {
        let url: String?
        let r: Int?
        let size: Double?
    }

    struct MVDetail: Codable {
        let id: UInt64
        let name: String
        let artistName: String?
        let artistId: UInt64?
        let cover: String?
        let playCount: Int?
        let duration: Int?
        let desc: String?
        let briefDesc: String?
        let publishTime: String?
        let commentCount: Int?
        let shareCount: Int?
        let subCount: Int?
    }

    struct DragonBallItem: Codable, Identifiable {
        let id: Int
        let name: String
        let iconUrl: String
    }

    // MARK: - Comments

    enum CommentResourceType: Int, Codable {
        case music = 0
        case mv = 1
        case playlist = 2
        case album = 3
        case dj = 4
        case video = 5
        case event = 6
        case radio = 7
    }

    struct CommentUser: Decodable, Hashable {
        let userId: UInt64
        let nickname: String
        let avatarUrl: String?
    }

    struct CommentIPLocation: Decodable, Hashable {
        let location: String?
    }

    struct CommentBeReplied: Decodable, Hashable {
        let beRepliedCommentId: UInt64?
        let content: String?
        let richContent: String?
        let status: Int?
        let user: CommentUser?
    }

    struct CommentShowFloorComment: Decodable, Hashable {
        let replyCount: Int?
        let showReplyCount: Bool?
    }

    struct Comment: Decodable, Identifiable, Hashable {
        let commentId: UInt64
        let content: String
        let richContent: String?
        let time: Int64?
        let timeStr: String?
        let likedCount: Int?
        let liked: Bool?
        let ipLocation: CommentIPLocation?
        let user: CommentUser
        let beReplied: [CommentBeReplied]?
        let showFloorComment: CommentShowFloorComment?

        var id: UInt64 { commentId }
    }

    struct CommentsPage: Decodable, Hashable {
        let code: Int
        let total: Int?
        let more: Bool?
        let moreHot: Bool?
        let hotComments: [Comment]?
        let comments: [Comment]?
        let topComments: [Comment]?
    }

    enum CommentNewSortType: Int, Codable {
        case recommend = 1
        case hot = 2
        case time = 3
    }

    struct CommentNewPage: Decodable, Hashable {
        struct DataPayload: Decodable, Hashable {
            let comments: [Comment]?
            let hasMore: Bool?
            let cursor: IntOrString?
            let totalCount: Int?
            let sortType: Int?
            let commentsTitle: String?
        }

        let code: Int
        let message: String?
        let data: DataPayload?
    }

    struct FloorCommentsPage: Decodable, Hashable {
        struct DataPayload: Decodable, Hashable {
            let ownerComment: Comment?
            let bestComments: [Comment]?
            let comments: [Comment]?
            let hasMore: Bool?
            let time: Int64?
            let totalCount: Int?
            let currentComment: Comment?
        }

        let code: Int
        let message: String?
        let data: DataPayload?
    }

    private struct ApiResponse<T: Decodable>: Decodable {
        let code: Int
        let data: T
    }

    private func doRequest(
        memberName: String, data: [String: Any]
    ) async throws -> Data {
        var data = data
        if let cookie = getCookie() {
            data["cookie"] = cookie
        }
        setenv("QT_ENABLE_REGEXP_JIT", "0", 1)  // Disable Qt's JIT in regex matching
        setenv("QT_LOGGING_RULES", "*.debug=false", 1)  // Reduce log
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let jsonData = try JSONSerialization.data(
                    withJSONObject: data, options: [.sortedKeys])

                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

                let cacheKey = memberName + jsonString
                if cacheTtl != 0 {
                    if let cachedData = SharedCacheManager.shared.get(for: cacheKey) as? Data {
                        if transportError(from: cachedData) != nil {
                            SharedCacheManager.shared.invalidate(memberName: memberName, data: data)
                        } else {
                            SharedCacheManager.shared.set(
                                value: cachedData, for: cacheKey, ttl: cacheTtl)
                            continuation.resume(returning: cachedData)
                            return
                        }
                    }
                }

                memberName.withCString { memberNameCString in
                    let memberNamePtr = UnsafeMutablePointer(mutating: memberNameCString)
                    jsonString.withCString { jsonString in
                        let jsonString = UnsafeMutablePointer(mutating: jsonString)
                        let jsonResultCString = invoke(memberNamePtr, jsonString)
                        if let cString = jsonResultCString {
                            let jsonResult = String(cString: cString)

                            if let jsonData = jsonResult.data(using: .utf8) {
                                if let error = transportError(from: jsonData) {
                                    continuation.resume(throwing: error)
                                    return
                                }
                                SharedCacheManager.shared.set(
                                    value: jsonData, for: cacheKey, ttl: cacheTtl)
                                continuation.resume(returning: jsonData)
                                return
                            }
                            continuation.resume(
                                throwing: RequestError.Request("No data: \(jsonResult)"))
                            return
                        }
                        continuation.resume(throwing: RequestError.Request("invoke() returns nil"))
                        return
                    }
                }
            } catch let error where error is ServerError {
                guard let err = error as? ServerError else { return }

                var msg = err.msg ?? err.message ?? ""

                if err.code == -462 {
                    msg = "绑定手机号或短信验证成功后，可进行下一步操作哦~🙃"
                }

                continuation.resume(throwing: RequestError.errorCode((err.code, msg)))
            } catch let error {
                continuation.resume(throwing: RequestError.error(error))
            }
        }
    }

    func login_qr_key(max_retries: UInt = 3) async throws -> String {
        struct Result: Decodable {
            let code: Int
            let unikey: String
        }

        if let res = try? await doRequest(
            memberName: "login_qr_key",
            data: [:]
        ).asType(ApiResponse<Result>.self) {
            return res.data.unikey
        }

        throw RequestError.noData
    }

    func login_qr_create(key: String) async throws -> String {
        struct Result: Decodable {
            let qrurl: String
        }

        let p = [
            "key": key
        ]

        if let res = try? await doRequest(
            memberName: "login_qr_create",
            data: p
        ).asType(ApiResponse<Result>.self) {
            return res.data.qrurl
        }
        throw RequestError.noData
    }

    static let SaveCookieName: String = "NeteaseApiCookie"

    func setCookie(_ cookie: String) {
        UserDefaults.standard.set(cookie, forKey: CloudMusicApi.SaveCookieName)
    }

    func getCookie() -> String? {
        return UserDefaults.standard.string(forKey: CloudMusicApi.SaveCookieName)
    }

    func login_refresh() async throws {
        guard
            (try? await doRequest(
                memberName: "login_refresh",
                data: [:])) != nil
        else {
            return
        }
    }

    func login_qr_check(key: String) async throws -> (
        code: Int, message: String, cookie: String?, redirectUrl: String?
    ) {
        struct Result: Decodable {
            let code: Int
            let message: String?
            let cookie: String?
            let redirectUrl: String?
        }
        let p = [
            "key": key
        ]
        guard
            let ret = try? await doRequest(
                memberName: "login_qr_check", data: p
            )
        else {
            return (0, "No data", nil, nil)
        }

        if let jsonString = String(data: ret, encoding: .utf8) {
            print(jsonString)
        }

        guard let parsedResult = ret.asType(Result.self) else {
            return (0, "Parse failed", nil, nil)
        }

        if parsedResult.code == 803, let cookie = parsedResult.cookie {
            setCookie(cookie)
        }

        return (
            parsedResult.code, parsedResult.message ?? "No message", parsedResult.cookie,
            parsedResult.redirectUrl
        )
    }

    func login_status() async -> Profile? {
        struct Data: Decodable {
            let profile: Profile?
        }
        struct Result: Decodable {
            // Optional: a transient network failure can yield a body without a
            // `data` key, which we treat as "no status" rather than a decode error.
            let data: Data?
            let code: Int?
        }
        guard let ret = try? await doRequest(memberName: "login_status", data: [:]) else {
            return nil
        }
        guard let parsed = ret.asType(Result.self, silent: true) else {
            logUnexpectedResponse(ret, member: "login_status")
            return nil
        }
        if let code = parsed.code, code != 200 {
            logUnexpectedResponse(ret, member: "login_status", code: code)
            return nil
        }
        return parsed.data?.profile
    }

    func history_recommend_songs() async {
        guard let ret = try? await doRequest(memberName: "history_recommend_songs", data: [:])
        else { return }

        print(ret.asAny() ?? "No data")
    }

    func user_playlist(
        uid: UInt64, limit: Int = 30, offset: Int = 0, includeVideo: Bool = true
    )
        async throws
        -> [CloudMusicApi.PlayListItem]?
    {
        guard
            let ret = try? await doRequest(
                memberName: "user_playlist",
                data: [
                    "uid": uid,
                    "limit": limit,
                    "offset": offset,
                    "includeVideo": includeVideo,
                ])
        else { return nil }

        struct Result: Decodable {
            // `playlist`/`more` are optional: on a transient network failure (e.g.
            // right after the machine wakes, when the periodic refresh fires before
            // the network is ready) the C++ bridge can answer with a body that
            // carries no `playlist` key. That is a recoverable condition, not a
            // decoding bug, so we decode silently and treat it as "no data".
            let playlist: [PlayListItem]?
            let more: Bool?
            let code: Int?
        }

        // TODO: Fix more = true
        guard let parsed = ret.asType(Result.self, silent: true) else {
            logUnexpectedResponse(ret, member: "user_playlist")
            return nil
        }

        if let code = parsed.code, code != 200 {
            logUnexpectedResponse(ret, member: "user_playlist", code: code)
            return nil
        }

        return parsed.playlist
    }

    func login_cellphone(phone: String, countrycode: Int = 86, password: String) async
        -> String?
    {
        guard
            let ret = try? await doRequest(
                memberName: "login_cellphone",
                data: [
                    "phone": phone,
                    "countrycode": countrycode,
                    "password": password,
                ])
        else {
            print("login_cellphone failed")
            return "Request failed"
        }

        print(ret.asAny() ?? "No data")
        struct Data: Decodable {
            let blockText: String?
        }

        struct Result: Decodable {
            let message: String?
            let cookie: String?
            let data: Data?
        }

        if let parsed = ret.asType(Result.self) {
            if let cookie = parsed.cookie {
                setCookie(cookie)
                return nil
            }
            if let data = parsed.data, let blockText = data.blockText {
                return blockText
            }
        }
        return "Parse failed"
    }

    func logout() async {
        guard (try? await doRequest(memberName: "logout", data: [:])) != nil else { return }
        setCookie("dummy saved cookie")
    }

    func user_account() async {
        guard (try? await doRequest(memberName: "user_account", data: [:])) != nil else { return }
    }

    func user_subcount() async {
        guard let ret = try? await doRequest(memberName: "user_subcount", data: [:]) else { return }

        print(ret)
    }

    func user_cloud(limit: Int = 30, offset: Int = 0) async -> [CloudFile]? {
        guard
            let res = try? await doRequest(
                memberName: "user_cloud",
                data: [
                    "limit": limit,
                    "offset": offset,
                ])
        else {
            print("user_cloud failed")
            return nil
        }

        if let parsed = res.asType(CloudFilesResponse.self) {
            return parsed.data
        }
        return nil
    }

    func playlist_detail(id: UInt64) async -> (tracks: [Song], trackIds: [UInt64])? {
        if id == CloudMusicApi.RecommandSongPlaylistId {
            return await recommend_songs().map { ($0, $0.map { $0.id }) }
        }
        guard
            let ret: Data = try? await doRequest(
                memberName: "playlist_detail",
                data: [
                    "id": id
                ])
        else {
            return nil
        }

        struct Track: Decodable {
            let id: UInt64
        }

        struct Playlist: Decodable {
            let trackIds: [Track]
            let tracks: [Song]
        }

        struct Result: Decodable {
            let code: Int
            let playlist: Playlist
        }

        if let parsed = ret.asType(Result.self) {
            return (parsed.playlist.tracks, parsed.playlist.trackIds.map { $0.id })
        }
        print("playlist_detail failed")
        return nil
    }

    func song_detail(ids: [UInt64]) async -> [Song]? {
        guard
            let ret = try? await doRequest(
                memberName: "song_detail",
                data: [
                    "ids": ids.map { String($0) }.joined(separator: ",")
                ])
        else { return nil }

        struct Result: Decodable {
            let songs: [Song]
        }

        if let parsed = ret.asType(Result.self) {
            return parsed.songs
        }
        print("song_detail failed")
        return nil
    }

    func song_url_v1(id: [UInt64], level: String = "jymaster") async -> [SongData]? {
        guard
            let ret = try? await doRequest(
                memberName: "song_url_v1",
                data: [
                    "id": id.map { String($0) }.joined(separator: ","),
                    "level": level,
                ])
        else { return nil }

        struct Result: Decodable {
            let code: Int?
            let data: [SongData]?
        }

        // Decode silently: a transient transport failure can leave an empty or
        // non-standard body here; treat it as "no data" instead of a decoding bug.
        guard let parsed = ret.asType(Result.self, silent: true) else {
            logUnexpectedResponse(ret, member: "song_url_v1")
            return nil
        }
        if let code = parsed.code, code != 200 {
            logUnexpectedResponse(ret, member: "song_url_v1", code: code)
            return nil
        }
        return parsed.data
    }

    func song_download_url(id: UInt64, br: UInt64 = 999000) async -> SongData? {
        guard
            let ret = try? await doRequest(
                memberName: "song_download_url",
                data: [
                    "id": id,
                    "br": br,
                ])
        else { return nil }

        struct Result: Decodable {
            let code: Int
            let data: SongData
        }

        if let parsed = ret.asType(Result.self) {
            return parsed.data
        }
        print("song_download_url failed")
        return nil
    }

    func playlist_track_all(id: UInt64, limit: UInt64?, offset: UInt64?) async -> [Song]? {
        var p: [String: UInt64] = [
            "id": id
        ]
        if let limit = limit {
            p["limit"] = limit
        }
        if let offset = offset {
            p["offset"] = offset
        }
        guard
            let ret = try? await doRequest(
                memberName: "playlist_track_all", data: p)
        else { return nil }

        struct Result: Decodable {
            let code: Int
            let songs: [Song]
        }

        if let parsed = ret.asType(Result.self) {
            return parsed.songs
        }
        print("playlist_track_all failed")
        return nil
    }

    func comment_music(
        id: UInt64,
        limit: Int = 20,
        offset: Int = 0,
        before: Int64? = nil
    ) async throws -> CommentsPage {
        var p: [String: Any] = [
            "id": id,
            "limit": limit,
            "offset": offset,
        ]
        if let before {
            p["before"] = before
        }
        let ret = try await doRequest(memberName: "comment_music", data: p)
        guard let parsed = ret.asType(CommentsPage.self, silent: true) else {
            throw RequestError.noData
        }
        return parsed
    }

    func comment_playlist(
        id: UInt64,
        limit: Int = 20,
        offset: Int = 0,
        before: Int64? = nil
    ) async throws -> CommentsPage {
        var p: [String: Any] = [
            "id": id,
            "limit": limit,
            "offset": offset,
        ]
        if let before {
            p["before"] = before
        }
        let ret = try await doRequest(memberName: "comment_playlist", data: p)
        guard let parsed = ret.asType(CommentsPage.self, silent: true) else {
            throw RequestError.noData
        }
        return parsed
    }

    func comment_new(
        type: CommentResourceType,
        id: UInt64,
        pageNo: Int = 1,
        pageSize: Int = 20,
        sortType: CommentNewSortType = .hot,
        cursor: Int64? = nil
    ) async throws -> CommentNewPage.DataPayload {
        var p: [String: Any] = [
            "type": type.rawValue,
            "id": id,
            "pageNo": pageNo,
            "pageSize": pageSize,
            "sortType": sortType.rawValue,
        ]
        if let cursor {
            p["cursor"] = cursor
        }
        let ret = try await doRequest(memberName: "comment_new", data: p)
        guard let parsed = ret.asType(CommentNewPage.self, silent: true), let data = parsed.data else {
            throw RequestError.noData
        }
        return data
    }

    func comment_floor(
        parentCommentId: UInt64,
        id: UInt64,
        type: CommentResourceType,
        limit: Int = 20,
        time: Int64? = nil
    ) async throws -> FloorCommentsPage.DataPayload {
        var p: [String: Any] = [
            "parentCommentId": parentCommentId,
            "id": id,
            "type": type.rawValue,
            "limit": limit,
        ]
        if let time {
            p["time"] = time
        }
        let ret = try await doRequest(memberName: "comment_floor", data: p)
        guard let parsed = ret.asType(FloorCommentsPage.self, silent: true), let data = parsed.data else {
            throw RequestError.noData
        }
        return data
    }

    private var seq: Int {
        var ret_seq = UserDefaults.standard.integer(forKey: "scrobble_seq")
        if ret_seq == 0 {
            ret_seq = Int.random(in: 1000..<3000)
        }
        ret_seq += 1
        UserDefaults.standard.set(ret_seq, forKey: "scrobble_seq")
        return ret_seq
    }

    private var mspm: String {
        let ret =
            UserDefaults.standard.string(forKey: "mspm")
            ?? {
                var ret: String
                if getenv("MSPM") != nil {
                    ret = String(cString: getenv("MSPM"))
                } else {
                    ret = {
                        let characters = "0123456789abcdef"
                        var result = ""

                        let length = 24

                        for _ in 0..<length {
                            let randomIndex = Int(arc4random_uniform(UInt32(characters.count)))
                            let randomCharacter = characters[
                                characters.index(characters.startIndex, offsetBy: randomIndex)]
                            result.append(randomCharacter)
                        }

                        return result
                    }()
                }

                UserDefaults.standard.set(ret, forKey: "mspm")
                return ret
            }()

        return ret
    }

    func scrobble(song: Song, playedTime: Int? = nil) async {
        guard
            (try? await doRequest(
                memberName: "scrobble",
                data: [
                    "id": song.id,
                    "sourceid": song.al.id,
                    "time": playedTime ?? Int(song.dt / 1000),
                ]
            )) != nil
        else {
            print("scrobble failed")
            return
        }
    }

    func scrobble_legacy(id: UInt64, sourceid: UInt64, time: Int64) async {
        guard
            let res = try? await doRequest(
                memberName: "scrobble",
                data: [
                    "id": id,
                    "sourceid": sourceid,
                    "time": time,
                ])
        else {
            print("scrobble failed")
            return
        }

        struct Result: Decodable {
            let code: Int
            let data: String
        }

        if let parsed = res.asType(Result.self),
            parsed.code == 200
        {
            print("scrobble success")
        } else {
            print("scrobble failed")
            print(res.asAny() ?? "")
        }
    }

    func cloud(filePath: URL, songName: String?, artist: String?, album: String?) async throws
        -> UInt64?
    {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath.path) else {
            throw RequestError.Request("cloud failed to read file")
        }


        let filename = filePath.lastPathComponent

        let p =
            [
                "dataInPath": true,
                "songFile": [
                    "path": filePath.path,
                    "name": filename,
                ],
                "songName": songName ?? filename,
                "artist": artist ?? "未知专辑",
                "album": album ?? "未知艺术家",
            ] as [String: Any]

        guard
            let res = try? await doRequest(
                memberName: "cloud", data: p)
        else {
            throw RequestError.Request("Make request failed")
        }

        struct PrivateCloud: Decodable {
            let songId: UInt64
        }

        struct Result3: Decodable {
            let code: Int
            let privateCloud: PrivateCloud?
        }

        struct Result: Decodable {
            let res3: Result3
        }

        if let parsed = res.asType(Result.self, silent: true) {
            if let songId = parsed.res3.privateCloud?.songId {
                return songId
            }
            throw RequestError.errorCode((parsed.res3.code, "/api/cloud/pub/v2 Failed"))
        }

        struct ErrorResult: Decodable {
            let code: Int
            let msg: String
        }

        if let parsed = res.asType(ErrorResult.self, silent: true) {
            throw RequestError.errorCode((parsed.code, "cloud failed: \(parsed.msg)"))
        }

        throw RequestError.Request("\(res.asAny() ?? "Unknown error")")
    }

    func cloud_match(userId: UInt64, songId: UInt64, adjustSongId: UInt64) async throws {
        guard
            let res = try? await doRequest(
                memberName: "cloud_match",
                data: [
                    "uid": userId,
                    "sid": songId,
                    "asid": adjustSongId,
                ])
        else {
            throw RequestError.Request("cloud_match failed to make request")
        }

        struct Result: Decodable {
            let code: Int
            let message: IntOrString?
        }

        if let parsed = res.asType(Result.self, silent: true) {
            if parsed.code == 200 {
                return
            }

            throw RequestError.errorCode(
                (parsed.code, "cloud_match failed: \(parsed.message?.stringValue ?? "Unknown error")"))
        }

        throw RequestError.Request(
            "cloud_match failed: \(res.asAny() ?? "Unknown error")"
        )
    }

    /// Similar songs based on a given song ID (simi_song).
    /// Only requires a song ID - no playlist context needed.
    func simi_song(id: UInt64, limit: Int = 50) async -> [Song]? {
        let logger = Logger(subsystem: "com.cyncyn.Auralis", category: "API")
        logger.info("simi_song: id=\(id)")

        guard
            let res = try? await doRequest(
                memberName: "simi_song",
                data: ["id": id, "limit": limit, "offset": 0]
            )
        else {
            logger.error("simi_song: doRequest failed")
            return nil
        }

        // simi_song returns old-format songs (album/artists/duration/mvid)
        // which need conversion to the Song struct (al/ar/dt/mv).
        struct SimiArtist: Decodable {
            let id: UInt64
            let name: String?
            let alias: [String]?
        }
        struct SimiAlbum: Decodable {
            let id: UInt64
            let name: String?
            let pic: UInt64?
            let picUrl: String?
            let alias: [String]?
            let publishTime: Int64?
        }
        struct SimiSong: Decodable {
            let id: UInt64
            let name: String
            let duration: Int64
            let mvid: UInt64
            let fee: Fee
            let alias: [String]?
            let album: SimiAlbum
            let artists: [SimiArtist]
            let publishTime: Int64?

            func toSong() -> Song {
                return Song(
                    name: name,
                    id: id,
                    al: Album(
                        id: album.id,
                        name: album.name,
                        pic: album.pic ?? 0,
                        picUrl: album.picUrl ?? "",
                        tns: album.alias ?? []
                    ),
                    ar: artists.map {
                        Artist(id: $0.id, name: $0.name, alias: $0.alias ?? [], tns: [])
                    },
                    alia: alias ?? [],
                    tns: nil,
                    fee: fee,
                    originCoverType: nil,
                    mv: mvid,
                    dt: duration,
                    hr: nil, sq: nil, h: nil, m: nil, l: nil,
                    publishTime: publishTime ?? album.publishTime ?? 0,
                    pc: nil
                )
            }
        }
        struct Response: Decodable {
            let code: Int
            let songs: [SimiSong]?
        }

        if let parsed = res.asType(Response.self, silent: true) {
            logger.info("simi_song: code=\(parsed.code), songs=\(parsed.songs?.count ?? 0)")
            return parsed.songs?.map { $0.toSong() }
        } else {
            logger.error("simi_song: decoding failed")
            return nil
        }
    }

    func likelist(userId: UInt64) async -> [UInt64]? {        guard
            let res = try? await doRequest(
                memberName: "likelist",
                data: [
                    "uid": userId
                ])
        else {
            print("likelist failed")
            return nil
        }

        struct Result: Decodable {
            let ids: [UInt64]
        }

        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.ids
        }
        return nil
    }

    func like(id: UInt64, like: Bool) async throws {
        guard
            let res = try? await doRequest(
                memberName: "like",
                data: [
                    "id": id,
                    "like": like ? "true" : "false",
                ])
        else {
            print("like failed")
            return
        }

        struct Result: Decodable {
            let code: Int
        }
        if let parsed = res.asType(Result.self, silent: true) {
            if parsed.code != 200 {
                throw RequestError.errorCode((parsed.code, LanguageManager.shared.string("api.fav_failed")))
            }
        }
    }

    func recommend_resource() async -> [RecommandPlaylistItem]? {
        guard
            let res = try? await doRequest(
                memberName: "recommend_resource",
                data: [:])
        else {
            print("recommend_resource failed")
            return nil
        }

        struct Result: Decodable {
            let recommend: [RecommandPlaylistItem]
        }

        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.recommend
        }
        return nil
    }

    func recommend_songs() async -> [Song]? {
        try? await recommend_song_entries().map(\.song)
    }

    func recommend_song_entries() async throws -> [DailyRecommendationEntry] {
        guard
            let res = try? await doRequest(
                memberName: "recommend_songs",
                data: [:])
        else {
            throw RequestError.noData
        }

        struct Reason: Decodable {
            let songId: UInt64
            let reason: String?
        }

        struct Payload: Decodable {
            let dailySongs: [Song]
            let recommendReasons: [Reason]?
        }

        struct Result: Decodable {
            let code: Int
            let data: Payload
        }

        guard let parsed = res.asType(Result.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        let reasons = Dictionary(
            uniqueKeysWithValues: (parsed.data.recommendReasons ?? []).map {
                ($0.songId, $0.reason)
            }
        )
        return parsed.data.dailySongs.map {
            DailyRecommendationEntry(song: $0, reason: reasons[$0.id] ?? nil)
        }
    }

    func personal_fm() async throws -> [PersonalFMTrack] {
        struct LegacyArtist: Decodable {
            let id: UInt64
            let name: String?
            let alias: [String]?
        }

        struct LegacyAlbum: Decodable {
            let id: UInt64
            let name: String?
            let pic: UInt64?
            let picUrl: String?
            let alias: [String]?
            let publishTime: Int64?
        }

        struct LegacySong: Decodable {
            let id: UInt64
            let name: String
            let duration: Int64
            let mvid: UInt64?
            let fee: Fee
            let alias: [String]?
            let album: LegacyAlbum
            let artists: [LegacyArtist]
            let publishTime: Int64?
            let reason: String?

            func toTrack() -> PersonalFMTrack {
                let song = Song(
                    name: name,
                    id: id,
                    al: Album(
                        id: album.id,
                        name: album.name,
                        pic: album.pic ?? 0,
                        picUrl: album.picUrl ?? "",
                        tns: album.alias ?? []
                    ),
                    ar: artists.map {
                        Artist(id: $0.id, name: $0.name, alias: $0.alias ?? [], tns: [])
                    },
                    alia: alias ?? [],
                    tns: nil,
                    fee: fee,
                    originCoverType: nil,
                    mv: mvid ?? 0,
                    dt: duration,
                    hr: nil,
                    sq: nil,
                    h: nil,
                    m: nil,
                    l: nil,
                    publishTime: publishTime ?? album.publishTime ?? 0,
                    pc: nil
                )
                return PersonalFMTrack(song: song, reason: reason)
            }
        }

        struct Response: Decodable {
            let code: Int
            let data: [LegacySong]
        }

        let response = try await doRequest(memberName: "personal_fm", data: [:])
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.data.map { $0.toTrack() }
    }

    func trash_fm_song(id: UInt64, playedTime: Int = 25) async throws {
        struct Response: Decodable {
            let code: Int
        }

        let response = try await doRequest(
            memberName: "fm_trash",
            data: ["id": id, "time": playedTime]
        )
        guard let parsed = response.asType(Response.self, silent: true), parsed.code == 200 else {
            throw RequestError.noData
        }
    }

    func dislike_recommended_song(id: UInt64) async throws {
        struct Response: Decodable {
            let code: Int
        }

        let response = try await doRequest(
            memberName: "recommend_songs_dislike",
            data: ["id": id]
        )
        guard let parsed = response.asType(Response.self, silent: true), parsed.code == 200 else {
            throw RequestError.noData
        }
    }

    func recent_listen_list() async throws -> [RecentListenResource] {
        struct Payload: Decodable {
            let resources: [RecentListenResource]?
        }
        struct Response: Decodable {
            let code: Int
            let data: Payload?
        }

        let response = try await doRequest(memberName: "recent_listen_list", data: [:])
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.data?.resources ?? []
    }

    func listen_summary() async throws -> ListenSummary {
        struct TotalPayload: Decodable {
            let totalDuration: Int64
        }
        struct TotalResponse: Decodable {
            let code: Int
            let data: TotalPayload?
        }
        struct TodayPayload: Decodable {
            let songDTOs: [TodayListenSong]?
        }
        struct TodayResponse: Decodable {
            let code: Int
            let data: TodayPayload?
        }

        async let totalData = doRequest(memberName: "listen_data_total", data: [:])
        async let todayData = doRequest(memberName: "listen_data_today_song", data: [:])
        let (totalResponse, todayResponse) = try await (totalData, todayData)

        guard
            let total = totalResponse.asType(TotalResponse.self, source: #function),
            let today = todayResponse.asType(TodayResponse.self, source: #function),
            total.code == 200,
            today.code == 200
        else {
            throw RequestError.noData
        }

        return ListenSummary(
            totalDuration: total.data?.totalDuration ?? 0,
            todaySongs: today.data?.songDTOs ?? []
        )
    }

    func search_artists(
        keyword: String,
        limit: Int = 30,
        offset: Int = 0
    ) async throws -> [CatalogArtist] {
        struct Payload: Decodable {
            let artists: [CatalogArtist]?
        }
        struct Response: Decodable {
            let code: Int
            let result: Payload?
        }

        let response = try await doRequest(
            memberName: "search",
            data: [
                "keywords": keyword,
                "type": SearchType.artist.rawValue,
                "limit": limit,
                "offset": offset,
            ]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.result?.artists ?? []
    }

    func search_albums(
        keyword: String,
        limit: Int = 30,
        offset: Int = 0
    ) async throws -> [CatalogAlbum] {
        struct Payload: Decodable {
            let albums: [CatalogAlbum]?
        }
        struct Response: Decodable {
            let code: Int
            let result: Payload?
        }

        let response = try await doRequest(
            memberName: "search",
            data: [
                "keywords": keyword,
                "type": SearchType.album.rawValue,
                "limit": limit,
                "offset": offset,
            ]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.result?.albums ?? []
    }

    func artist_detail(id: UInt64) async throws -> CatalogArtist {
        struct Payload: Decodable {
            let artist: CatalogArtist
        }
        struct Response: Decodable {
            let code: Int
            let data: Payload
        }

        let response = try await doRequest(memberName: "artist_detail", data: ["id": id])
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.data.artist
    }

    func artist_top_songs(id: UInt64) async throws -> [Song] {
        struct SongID: Decodable {
            let id: UInt64
        }
        struct Response: Decodable {
            let code: Int
            let songs: [SongID]
        }

        let response = try await doRequest(memberName: "artist_top_song", data: ["id": id])
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return await song_detail(ids: parsed.songs.map(\.id)) ?? []
    }

    func artist_albums(
        id: UInt64,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> [CatalogAlbum] {
        struct Response: Decodable {
            let code: Int
            let hotAlbums: [CatalogAlbum]
        }

        let response = try await doRequest(
            memberName: "artist_album",
            data: ["id": id, "limit": limit, "offset": offset]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.hotAlbums
    }

    func album_detail(id: UInt64) async throws -> AlbumDetail {
        struct SongID: Decodable {
            let id: UInt64
        }
        struct Response: Decodable {
            let code: Int
            let album: CatalogAlbum
            let songs: [SongID]
        }

        let response = try await doRequest(memberName: "album", data: ["id": id])
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        let songs = await song_detail(ids: parsed.songs.map(\.id)) ?? []
        return AlbumDetail(album: parsed.album, songs: songs)
    }

    func subscribe_artist(id: UInt64, subscribe: Bool) async throws {
        try await performCatalogMutation(
            memberName: "artist_sub",
            data: ["id": id, "t": subscribe ? 1 : 2]
        )
    }

    func subscribe_album(id: UInt64, subscribe: Bool) async throws {
        try await performCatalogMutation(
            memberName: "album_sub",
            data: ["id": id, "t": subscribe ? 1 : 2]
        )
    }

    func subscribed_artists(limit: Int = 100, offset: Int = 0) async throws -> [CatalogArtist] {
        struct Response: Decodable {
            let code: Int
            let data: [CatalogArtist]
        }

        let response = try await doRequest(
            memberName: "artist_sublist",
            data: ["limit": limit, "offset": offset]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.data
    }

    func subscribed_albums(limit: Int = 100, offset: Int = 0) async throws -> [CatalogAlbum] {
        struct Response: Decodable {
            let code: Int
            let data: [CatalogAlbum]
        }

        let response = try await doRequest(
            memberName: "album_sublist",
            data: ["limit": limit, "offset": offset]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.data
    }

    private func performCatalogMutation(
        memberName: String,
        data: [String: Any]
    ) async throws {
        struct Response: Decodable {
            let code: Int
            let message: String?
        }

        let response = try await doRequest(memberName: memberName, data: data)
        guard let parsed = response.asType(Response.self, silent: true), parsed.code == 200 else {
            throw RequestError.noData
        }
    }

    func recommended_podcasts() async throws -> [PodcastRadio] {
        struct Response: Decodable {
            let code: Int
            let djRadios: [PodcastRadio]
        }

        let response = try await doRequest(memberName: "dj_recommend", data: [:])
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.djRadios
    }

    func popular_podcasts_page(
        limit: Int = 30,
        offset: Int = 0
    ) async throws -> Page<PodcastRadio> {
        struct Response: Decodable {
            let code: Int
            let hasMore: Bool?
            let djRadios: [PodcastRadio]
        }

        let response = try await doRequest(
            memberName: "dj_hot",
            data: ["limit": limit, "offset": offset]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return Page(
            items: parsed.djRadios,
            hasMore: parsed.hasMore ?? (parsed.djRadios.count == limit)
        )
    }

    func subscribed_podcasts(limit: Int = 100, offset: Int = 0) async throws -> [PodcastRadio] {
        struct Response: Decodable {
            let code: Int
            let djRadios: [PodcastRadio]
        }

        let response = try await doRequest(
            memberName: "dj_sublist",
            data: ["limit": limit, "offset": offset]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return parsed.djRadios
    }

    func podcast_episodes(
        radioID: UInt64,
        limit: Int = 50,
        offset: Int = 0,
        ascending: Bool = false
    ) async throws -> [PodcastEpisode] {
        try await podcast_episodes_page(
            radioID: radioID,
            limit: limit,
            offset: offset,
            ascending: ascending
        ).items
    }

    func podcast_episodes_page(
        radioID: UInt64,
        limit: Int = 30,
        offset: Int = 0,
        ascending: Bool = false
    ) async throws -> Page<PodcastEpisode> {
        struct Response: Decodable {
            let code: Int
            let programs: [PodcastEpisode]
            let more: Bool?
        }

        let response = try await doRequest(
            memberName: "dj_program",
            data: [
                "rid": radioID,
                "limit": limit,
                "offset": offset,
                "asc": ascending,
            ]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return Page(
            items: parsed.programs,
            hasMore: parsed.more ?? (parsed.programs.count == limit)
        )
    }

    func subscribe_podcast(id: UInt64, subscribe: Bool) async throws {
        try await performCatalogMutation(
            memberName: "dj_sub",
            data: ["rid": id, "t": subscribe ? 1 : 2]
        )
    }

    func intelligence_list(id: UInt64, pid: UInt64) async -> [Song]? {
        let logger = Logger(subsystem: "com.cyncyn.Auralis", category: "API")
        logger.info("intelligence_list: id=\(id), pid=\(pid)")

        guard
            let res = try? await doRequest(
                memberName: "playmode_intelligence_list",
                data: ["id": id, "sid": id, "pid": pid, "type": "fromPlayOne"]
            )
        else {
            logger.error("intelligence_list: doRequest failed")
            return nil
        }

        // The API wraps each song inside a "songInfo" object.
        struct IntelligenceItem: Decodable {
            let songInfo: Song
        }
        struct Response: Decodable {
            let code: Int
            let data: [IntelligenceItem]?
        }

        if let parsed = res.asType(Response.self, silent: true) {
            logger.info("intelligence_list: code=\(parsed.code), songs=\(parsed.data?.count ?? 0)")
            if let items = parsed.data {
                return items.map { $0.songInfo }
            }
            return nil
        } else {
            logger.error("intelligence_list: decoding failed, raw response length=\(res.count)")
            // Print raw response for debugging
            if let raw = String(data: res, encoding: .utf8) {
                logger.error("intelligence_list: raw response prefix=\(raw.prefix(500))")
            }
            return nil
        }
    }

    enum SearchType: Int {
        case singleSong = 1
        case album = 10
        case artist = 100
        case playlist = 1000
        case user = 1002
        case mv = 1004
        case lyric = 1006
        case radio = 1009
        case video = 1014
    }

    struct SearchResult {
        struct Artist: Decodable {
            let img1v1: UInt64
            let img1v1Url: String
            let name: String
            let id: UInt64

            func convertToArtist() -> CloudMusicApi.Artist {
                return CloudMusicApi.Artist(id: id, name: name, alias: [], tns: [])
            }
        }
        struct Album: Decodable {
            let picId: UInt64
            let id: UInt64
            let name: String

            let artist: Artist
            let publishTime: Int64

            func convertToAlbum() -> CloudMusicApi.Album {
                return CloudMusicApi.Album(
                    id: id, name: name, pic: picId, picUrl: "", tns: [])
            }
        }

        struct Song: Decodable {
            let album: Album
            let alias: [String]
            let artists: [Artist]
            let duration: Int64
            let id: UInt64
            let fee: Fee
            let name: String
            let mvid: UInt64
            let transNames: [String]?

            func convertToSong() -> CloudMusicApi.Song {
                return CloudMusicApi.Song(
                    name: name,
                    id: id,
                    al: album.convertToAlbum(),
                    ar: artists.map { $0.convertToArtist() },
                    alia: alias,
                    tns: nil,
                    fee: fee,
                    originCoverType: 0,
                    mv: mvid,
                    dt: duration,
                    hr: nil, sq: nil, h: nil, m: nil, l: nil,
                    publishTime: album.publishTime,
                    pc: nil
                )
            }
        }
    }

    func search_suggest(keyword: String) async -> [SearchResult.Song]? {
        guard
            let res = try? await doRequest(
                memberName: "search_suggest",
                data: [
                    "keywords": keyword
                ])
        else {
            print("search_suggest failed")
            return nil
        }

        struct SuggestResult: Decodable {
            let songs: [SearchResult.Song]?
        }

        struct Result: Decodable {
            let code: Int
            let result: SuggestResult?
        }
        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.result?.songs ?? []
        }
        print("search_suggest failed to parse response: \(res.asJSONString())")
        return nil
    }

    func search(
        keyword: String, type: SearchType = .singleSong, limit: Int = 30, offset: Int = 0
    ) async
        -> [SearchResult.Song]?
    {
        guard
            let res = try? await doRequest(
                memberName: "search",
                data: [
                    "keywords": keyword,
                    "type": type.rawValue,
                    "limit": limit,
                    "offset": offset,
                ])
        else {
            print("search failed")
            return nil
        }

        struct Result2: Decodable {
            let hasMore: Bool
            let songCount: Int
            let songs: [SearchResult.Song]
        }

        struct Result: Decodable {
            let result: Result2
        }

        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.result.songs
        }
        return nil
    }

    enum PlaylistTracksOp: String {
        case add = "add"
        case del = "del"
    }

    func playlist_tracks(op: PlaylistTracksOp, playlistId: UInt64, trackIds: [UInt64])
        async throws
    {
        guard
            let res = try? await doRequest(
                memberName: "playlist_tracks",
                data: [
                    "op": op.rawValue,
                    "pid": playlistId,
                    "tracks": trackIds.map { String($0) }.joined(separator: ","),
                ])
        else {
            print("playlist_tracks failed")
            return
        }

        struct ErrorResult: Decodable {
            let code: Int
            let message: String?
        }

        if let error = res.asType(ErrorResult.self, silent: true) {
            throw RequestError.errorCode((error.code, error.message ?? "Unknown error"))
        }
    }

    func create_playlist(name: String, isPrivate: Bool = false) async throws {
        try await performPlaylistMutation(
            memberName: "playlist_create",
            data: [
                "name": name,
                "privacy": isPrivate ? 10 : 0,
            ]
        )
    }

    func rename_playlist(id: UInt64, name: String) async throws {
        try await performPlaylistMutation(
            memberName: "playlist_name_update",
            data: ["id": id, "name": name]
        )
    }

    func update_playlist_description(id: UInt64, description: String) async throws {
        try await performPlaylistMutation(
            memberName: "playlist_desc_update",
            data: ["id": id, "desc": description]
        )
    }

    func delete_playlist(id: UInt64) async throws {
        try await performPlaylistMutation(
            memberName: "playlist_delete",
            data: ["id": id]
        )
    }

    func subscribe_playlist(id: UInt64, subscribe: Bool) async throws {
        try await performPlaylistMutation(
            memberName: "playlist_subscribe",
            data: ["id": id, "t": subscribe ? 1 : 2]
        )
    }

    private func performPlaylistMutation(
        memberName: String,
        data: [String: Any]
    ) async throws {
        struct Response: Decodable {
            let code: Int
            let message: String?
            let msg: String?
        }

        let response = try await doRequest(memberName: memberName, data: data)
        guard let parsed = response.asType(Response.self, silent: true) else {
            throw RequestError.noData
        }
        guard parsed.code == 200 else {
            throw RequestError.errorCode((parsed.code, parsed.message ?? parsed.msg ?? "Request failed"))
        }
    }

    struct LyricLine: Decodable, Hashable {
        let time: Float64
        let lyric: String
        let tlyric: String?
        let romalrc: String?
    }

    struct LyricNew: Decodable {

        struct RawLyricLine: Decodable, Hashable {
            let time: Float64
            let text: String
        }
        struct Lyric: Decodable {
            let lyric: String
            let version: Int

            func parse() -> [RawLyricLine] {
                return lyric.split(separator: "\n").map { (line: Substring) in
                    if !line.starts(with: "[") {
                        return RawLyricLine(time: -1, text: String(line))
                    }

                    let parts = line.split(separator: "]")
                    let time = parts[0].dropFirst().split(separator: ":")
                    let text = parts.count < 2 ? "" : parts[1]
                    if time.count < 2 {
                        return RawLyricLine(time: 0, text: String(text))
                    }
                    let minute = Int(String(time[0])) ?? 0
                    let second = Float64(time[1]) ?? 0
                    return RawLyricLine(time: Float64(minute * 60) + second, text: String(text))
                }
                .filter {
                    line in
                    return !line.text.isEmpty
                }
            }
        }

        func merge() -> [LyricLine] {
            let lrc = self.lrc?.parse() ?? []
            let tlyric = self.tlyric?.parse() ?? []
            let romalrc = self.romalrc?.parse() ?? []

            var result: [LyricLine] = []
            var lrcIndex = 0
            var tlyricIndex = 0
            var romalrcIndex = 0

            while lrcIndex < lrc.count || tlyricIndex < tlyric.count || romalrcIndex < romalrc.count
            {
                let lrcTime = lrcIndex < lrc.count ? lrc[lrcIndex].time : 1e9
                let tlyricTime = tlyricIndex < tlyric.count ? tlyric[tlyricIndex].time : 1e9
                let romalrcTime = romalrcIndex < romalrc.count ? romalrc[romalrcIndex].time : 1e9

                let time: Float64 = min(lrcTime, tlyricTime, romalrcTime)

                var lyricStr: String?
                var tlyricStr: String?
                var romalrcStr: String?

                if lrcIndex < lrc.count, lrc[lrcIndex].time == time {
                    lyricStr = lrc[lrcIndex].text
                    lrcIndex += 1
                }
                if tlyricIndex < tlyric.count, tlyric[tlyricIndex].time == time {
                    tlyricStr = tlyric[tlyricIndex].text
                    tlyricIndex += 1
                }
                if romalrcIndex < romalrc.count, romalrc[romalrcIndex].time == time {
                    romalrcStr = romalrc[romalrcIndex].text
                    romalrcIndex += 1
                }

                if time >= 0 && lyricStr != nil && lyricStr != "" {
                    result.append(
                        LyricLine(
                            time: time,
                            lyric: (lyricStr ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            tlyric: tlyricStr?.trimmingCharacters(in: .whitespacesAndNewlines),
                            romalrc: romalrcStr?.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
            }
            return result
        }

        // let klyric: LyricNew.Lyric
        let lrc: LyricNew.Lyric?
        let tlyric: LyricNew.Lyric?
        let romalrc: LyricNew.Lyric?
    }

    func lyric_new(id: UInt64) async -> LyricNew? {
        guard
            let res = try? await doRequest(
                memberName: "lyric_new",
                data: [
                    "id": id
                ])
        else {
            print("lyric_new failed")
            return nil
        }

        if let parsed = res.asType(LyricNew.self) {
            return parsed
        }
        print("lyric_new failed")

        return nil
    }

    // MARK: - Explore API

    func banner() async -> [BannerItem]? {
        guard let res = try? await doRequest(memberName: "banner", data: [:]) else { return nil }
        struct Result: Decodable {
            let banners: [BannerItem]
        }
        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.banners
        }
        return nil
    }

    func personalized(limit: Int = 30) async -> [RecommandPlaylistItem]? {
        guard
            let res = try? await doRequest(
                memberName: "personalized",
                data: ["limit": limit]
            )
        else { return nil }
        struct Result: Decodable {
            let result: [RecommandPlaylistItem]
        }
        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.result
        }
        return nil
    }

    func recommended_playlists_page(
        limit: Int = 30,
        offset: Int = 0
    ) async throws -> Page<RecommandPlaylistItem> {
        struct Playlist: Decodable {
            let coverImgUrl: String
            let userId: UInt64?
            let id: UInt64
            let name: String
            let playCount: UInt64?
            let trackCount: UInt64?
        }
        struct Response: Decodable {
            let code: Int
            let more: Bool?
            let playlists: [Playlist]
        }

        let response = try await doRequest(
            memberName: "top_playlist",
            data: [
                "cat": "全部",
                "order": "hot",
                "limit": limit,
                "offset": offset,
            ]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return Page(
            items: parsed.playlists.map {
                RecommandPlaylistItem(
                    creator: nil,
                    picUrl: $0.coverImgUrl,
                    userId: $0.userId,
                    id: $0.id,
                    name: $0.name,
                    playcount: $0.playCount,
                    trackCount: $0.trackCount
                )
            },
            hasMore: parsed.more ?? (parsed.playlists.count == limit)
        )
    }

    func personalized_newsong() async -> [Song]? {
        guard let res = try? await doRequest(memberName: "personalized_newsong", data: [:]) else { return nil }
        struct NewSongItem: Decodable {
            let song: Song
        }
        struct Result: Decodable {
            let result: [NewSongItem]
        }
        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.result.map { $0.song }
        }
        return nil
    }

    func toplist_detail() async -> [ToplistItem]? {
        guard let res = try? await doRequest(memberName: "toplist_detail", data: [:]) else { return nil }
        struct Result: Decodable {
            let list: [ToplistItem]
        }
        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.list
        }
        return nil
    }

    func personalized_mv() async -> [MVItem]? {
        guard let res = try? await doRequest(memberName: "personalized_mv", data: [:]) else { return nil }
        struct Result: Decodable {
            let result: [MVItem]
        }
        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.result
        }
        return nil
    }

    func recommended_mvs_page(
        limit: Int = 30,
        offset: Int = 0
    ) async throws -> Page<MVItem> {
        struct Item: Decodable {
            let id: UInt64
            let name: String
            let cover: String?
            let artistName: String?
            let playCount: Int?
            let duration: Int?
            let briefDesc: String?
        }
        struct Response: Decodable {
            let code: Int
            let hasMore: Bool?
            let data: [Item]
        }

        let response = try await doRequest(
            memberName: "mv_all",
            data: [
                "area": "全部",
                "type": "全部",
                "order": "上升最快",
                "limit": limit,
                "offset": offset,
            ]
        )
        guard let parsed = response.asType(Response.self, source: #function), parsed.code == 200 else {
            throw RequestError.noData
        }
        return Page(
            items: parsed.data.map {
                MVItem(
                    id: $0.id,
                    name: $0.name,
                    picUrl: $0.cover,
                    artistName: $0.artistName,
                    playCount: $0.playCount,
                    duration: $0.duration,
                    copywriter: $0.briefDesc
                )
            },
            hasMore: parsed.hasMore ?? (parsed.data.count == limit)
        )
    }

    func mv_url(id: UInt64, r: Int = 1080) async -> MVUrlData? {
        guard
            let res = try? await doRequest(
                memberName: "mv_url",
                data: [
                    "id": id,
                    "r": r,
                ])
        else { return nil }

        struct Response: Decodable {
            let code: Int
            let data: MVUrlData
        }

        if let parsed = res.asType(Response.self, silent: true) {
            return parsed.data
        }
        return nil
    }

    func mv_detail(mvid: UInt64) async -> MVDetail? {
        guard
            let res = try? await doRequest(
                memberName: "mv_detail",
                data: [
                    "mvid": mvid,
                ])
        else { return nil }

        struct Response: Decodable {
            let code: Int
            let data: MVDetail
        }

        if let parsed = res.asType(Response.self, silent: true) {
            return parsed.data
        }
        return nil
    }

    func homepage_dragon_ball() async -> [DragonBallItem]? {
        guard let res = try? await doRequest(memberName: "homepage_dragon_ball", data: [:]) else { return nil }
        struct Result: Decodable {
            let data: [DragonBallItem]
        }
        if let parsed = res.asType(Result.self, silent: true) {
            return parsed.data
        }
        return nil
    }
}
