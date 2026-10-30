import CryptoKit
import Foundation
import Network
import Observation
import Security
import SwiftUI

// MARK: - Source model

/// Kinds of music servers. The rest of the app talks to `MusicSourceClient`,
/// so more server types can be added without touching the player or the library.
nonisolated enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case jellyfin
    /// Anything speaking the Subsonic API: Navidrome, Gonic, Airsonic, Ampache, Nextcloud Music, …
    case subsonic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .subsonic: "Subsonic"
        }
    }
    var symbol: String {
        switch self {
        case .jellyfin: "server.rack"
        case .subsonic: "music.note.house"
        }
    }
}

nonisolated struct SourceAccount: Codable, Identifiable, Hashable, Sendable {
    var id: String            // "jellyfin:<serverId>:<userId>"
    var kind: SourceKind
    var name: String          // server name
    var baseURL: String
    var userID: String
    var userName: String
    var serverID: String
    var lastSync: Date?
    var trackCount = 0
    var enabled = true
    /// Subsonic servers that can't do salted-token sign-in (e.g. LDAP-backed) get the password hex-encoded instead.
    var legacyAuth: Bool?
}

/// Decodes one saved account without failing the whole list when its kind is unknown.
nonisolated private struct LossyAccount: Decodable {
    let value: SourceAccount?
    init(from decoder: Decoder) throws {
        value = try? SourceAccount(from: decoder)
    }
}

nonisolated struct RemoteTrack: Sendable {
    var remoteID: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var albumID: String?
    var imageTag: String?
    var duration: Double
    var trackNumber: Int
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var composer: String?
    var isFavorite: Bool
    var playCount: Int
    var lastPlayed: Date?
    var addedAt: Date?
    var normalizationGain: Double?
    var hasLyrics: Bool?
}

nonisolated struct RemotePlaylist: Sendable {
    var remoteID: String
    var name: String
    var trackRemoteIDs: [String]
}

nonisolated struct RemoteLibrary: Sendable {
    var tracks: [RemoteTrack]
    var playlists: [RemotePlaylist]
}

nonisolated enum SourceError: LocalizedError {
    case badURL, unauthorized, server(Int), decoding, offline
    case api(Int, String?)
    var errorDescription: String? {
        switch self {
        case .api(let code, let message): message ?? "The server answered with error \(code)."
        case .badURL: "That doesn't look like a server address."
        case .unauthorized: "Wrong user name or password."
        case .server(let code): "The server answered with error \(code)."
        case .decoding: "The server sent something \(Brand.name) doesn't understand."
        case .offline: "You're offline."
        }
    }
}

/// What every streaming source has to provide.
nonisolated protocol MusicSourceClient: Sendable {
    var account: SourceAccount { get }
    func fetchLibrary(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> RemoteLibrary
    func audioRequest(remoteID: String, maxBitrate: Int?) -> URLRequest?
    func imageRequest(itemID: String, maxSide: Int) -> URLRequest?
    func lyrics(remoteID: String) async -> String?
    func setFavorite(remoteID: String, _ on: Bool) async throws
    func markPlayed(remoteID: String) async throws
    func reportPlayback(remoteID: String, started: Bool, positionSeconds: Double) async
    func instantMix(remoteID: String, limit: Int) async throws -> [String]
}

// MARK: - Keychain

nonisolated enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "\(Brand.name)", kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "\(Brand.name)",
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "\(Brand.name)", kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Network

@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private(set) var isOnline = true
    private(set) var isExpensive = false
    @ObservationIgnored var onReconnect: () -> Void = {}
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                guard let self else { return }
                let came = online && !self.isOnline
                self.isOnline = online
                self.isExpensive = expensive
                if came { self.onReconnect() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "music.network"))
    }
}

// MARK: - Jellyfin

nonisolated struct JellyfinClient: MusicSourceClient {
    let account: SourceAccount
    let token: String

    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }

    static func authHeader(token: String?) -> String {
        var h = #"MediaBrowser Client="\#(Brand.name)", Device="iPhone", DeviceId="\#(deviceID)", Version="1.0""#
        if let token { h += #", Token="\#(token)""# }
        return h
    }

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    // MARK: Login

    private struct PublicInfo: Decodable { let ServerName: String?; let Id: String?; let Version: String? }
    private struct AuthResult: Decodable {
        struct UserDTO: Decodable { let Id: String; let Name: String }
        let User: UserDTO
        let AccessToken: String
        let ServerId: String
    }

    @concurrent
    static func login(server raw: String, user: String, password: String) async throws -> (SourceAccount, String) {
        guard let base = normalize(raw) else { throw SourceError.badURL }
        var name = base.host() ?? "Jellyfin"
        if let (data, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("System/Info/Public")),
           let info = try? JSONDecoder().decode(PublicInfo.self, from: data), let n = info.ServerName { name = n }
        var req = URLRequest(url: base.appendingPathComponent("Users/AuthenticateByName"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader(token: nil), forHTTPHeaderField: "Authorization")
        req.setValue(authHeader(token: nil), forHTTPHeaderField: "X-Emby-Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["Username": user, "Pw": password])
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw SourceError.unauthorized }
        guard code == 200 else { throw SourceError.server(code) }
        guard let auth = try? JSONDecoder().decode(AuthResult.self, from: data) else { throw SourceError.decoding }
        let account = SourceAccount(id: "jellyfin:\(auth.ServerId):\(auth.User.Id)", kind: .jellyfin, name: name,
                                    baseURL: base.absoluteString, userID: auth.User.Id, userName: auth.User.Name, serverID: auth.ServerId)
        return (account, auth.AccessToken)
    }

    // MARK: Requests

    private var base: URL { URL(string: account.baseURL)! }

    private func request(_ path: String, query: [String: String] = [:], method: String = "GET") -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(Self.authHeader(token: token), forHTTPHeaderField: "Authorization")
        req.setValue(Self.authHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        req.timeoutInterval = 30
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw SourceError.unauthorized }
        guard (200..<300).contains(code) else { throw SourceError.server(code) }
        return data
    }

    // MARK: DTOs

    private struct ItemsResponse: Decodable { let Items: [Item]; let TotalRecordCount: Int? }
    private struct Item: Decodable {
        struct UserDataDTO: Decodable { let IsFavorite: Bool?; let PlayCount: Int?; let LastPlayedDate: String? }
        struct Person: Decodable { let Name: String?; let `Type`: String? }
        let Id: String
        let Name: String?
        let Album: String?
        let AlbumId: String?
        let AlbumArtist: String?
        let Artists: [String]?
        let RunTimeTicks: Int64?
        let IndexNumber: Int?
        let ParentIndexNumber: Int?
        let ProductionYear: Int?
        let Genres: [String]?
        let DateCreated: String?
        let UserData: UserDataDTO?
        let ImageTags: [String: String]?
        let AlbumPrimaryImageTag: String?
        let NormalizationGain: Double?
        let HasLyrics: Bool?
        let People: [Person]?
        let ChildCount: Int?
    }

    private static let isoFrac = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = try? isoFrac.parse(s) { return d }
        if let d = try? isoPlain.parse(s) { return d }
        // Jellyfin sends 7 fractional digits; trim to milliseconds.
        if let dot = s.firstIndex(of: "."), let z = s.lastIndex(where: { $0 == "Z" || $0 == "+" }), z > dot {
            let frac = s[s.index(after: dot)..<z].prefix(3)
            return try? isoFrac.parse(String(s[..<dot]) + "." + frac + String(s[z...]))
        }
        return nil
    }

    private func map(_ i: Item) -> RemoteTrack {
        let artist = i.Artists?.first ?? i.AlbumArtist ?? "Unknown Artist"
        return RemoteTrack(remoteID: i.Id,
                           title: i.Name ?? "Untitled",
                           artist: artist,
                           album: i.Album ?? "Unknown Album",
                           albumArtist: i.AlbumArtist,
                           albumID: i.AlbumId,
                           imageTag: i.AlbumPrimaryImageTag ?? i.ImageTags?["Primary"],
                           duration: Double(i.RunTimeTicks ?? 0) / 10_000_000,
                           trackNumber: i.IndexNumber ?? 0,
                           discNumber: i.ParentIndexNumber,
                           year: i.ProductionYear,
                           genre: i.Genres?.first,
                           composer: i.People?.first { $0.Type == "Composer" }?.Name,
                           isFavorite: i.UserData?.IsFavorite ?? false,
                           playCount: i.UserData?.PlayCount ?? 0,
                           lastPlayed: Self.date(i.UserData?.LastPlayedDate),
                           addedAt: Self.date(i.DateCreated),
                           normalizationGain: i.NormalizationGain,
                           hasLyrics: i.HasLyrics)
    }

    // MARK: MusicSourceClient

    @concurrent
    func fetchLibrary(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> RemoteLibrary {
        var tracks: [RemoteTrack] = []
        var start = 0
        let page = 500
        var total = Int.max
        while start < total {
            let req = request("Users/\(account.userID)/Items", query: [
                "Recursive": "true", "IncludeItemTypes": "Audio", "SortBy": "AlbumArtist,Album,ParentIndexNumber,IndexNumber",
                "Fields": "Genres,DateCreated,ProductionYear,People,ParentId", "EnableUserData": "true",
                "EnableImageTypes": "Primary", "ImageTypeLimit": "1",
                "StartIndex": "\(start)", "Limit": "\(page)"
            ])
            let data = try await send(req)
            guard let res = try? JSONDecoder().decode(ItemsResponse.self, from: data) else { throw SourceError.decoding }
            tracks += res.Items.map(map)
            total = res.TotalRecordCount ?? tracks.count
            start += page
            progress(min(start, total), total)
            if res.Items.isEmpty { break }
        }

        var playlists: [RemotePlaylist] = []
        let listReq = request("Users/\(account.userID)/Items", query: ["Recursive": "true", "IncludeItemTypes": "Playlist", "Fields": "ChildCount"])
        if let data = try? await send(listReq), let res = try? JSONDecoder().decode(ItemsResponse.self, from: data) {
            for p in res.Items {
                let itemsReq = request("Users/\(account.userID)/Items", query: ["ParentId": p.Id, "IncludeItemTypes": "Audio", "Recursive": "true"])
                guard let d = try? await send(itemsReq), let r = try? JSONDecoder().decode(ItemsResponse.self, from: d) else { continue }
                playlists.append(RemotePlaylist(remoteID: p.Id, name: p.Name ?? "Playlist", trackRemoteIDs: r.Items.map(\.Id)))
            }
        }
        return RemoteLibrary(tracks: tracks, playlists: playlists)
    }

    func audioRequest(remoteID: String, maxBitrate: Int?) -> URLRequest? {
        var q = ["UserId": account.userID, "DeviceId": Self.deviceID,
                 "Container": "mp3,aac,m4a|aac,m4b|aac,flac,alac,m4a|alac,wav,aiff,aif",
                 "TranscodingContainer": "mp3", "TranscodingProtocol": "http", "AudioCodec": "mp3"]
        q["MaxStreamingBitrate"] = "\(maxBitrate ?? 999_999_999)"
        // Also as a query item: the universal endpoint may redirect, and redirects can drop custom headers.
        q["api_key"] = token
        var req = request("Audio/\(remoteID)/universal", query: q)
        req.timeoutInterval = 60
        return req
    }

    func imageRequest(itemID: String, maxSide: Int) -> URLRequest? {
        request("Items/\(itemID)/Images/Primary", query: ["maxWidth": "\(maxSide)", "maxHeight": "\(maxSide)", "quality": "90", "api_key": token])
    }

    private struct LyricsDTO: Decodable {
        struct Line: Decodable { let Text: String?; let Start: Int64? }
        let Lyrics: [Line]?
    }

    @concurrent
    func lyrics(remoteID: String) async -> String? {
        guard let data = try? await send(request("Audio/\(remoteID)/Lyrics")),
              let dto = try? JSONDecoder().decode(LyricsDTO.self, from: data), let lines = dto.Lyrics, !lines.isEmpty else { return nil }
        let timed = lines.allSatisfy { $0.Start != nil }
        return lines.map { line in
            let text = line.Text ?? ""
            guard timed, let ticks = line.Start else { return text }
            let t = Double(ticks) / 10_000_000
            return String(format: "[%02d:%05.2f] ", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) + text
        }.joined(separator: "\n")
    }

    @concurrent
    func setFavorite(remoteID: String, _ on: Bool) async throws {
        let method = on ? "POST" : "DELETE"
        do { _ = try await send(request("UserFavoriteItems/\(remoteID)", query: ["userId": account.userID], method: method)) }
        catch { _ = try await send(request("Users/\(account.userID)/FavoriteItems/\(remoteID)", method: method)) }
    }

    @concurrent
    func markPlayed(remoteID: String) async throws {
        do { _ = try await send(request("UserPlayedItems/\(remoteID)", query: ["userId": account.userID], method: "POST")) }
        catch { _ = try await send(request("Users/\(account.userID)/PlayedItems/\(remoteID)", method: "POST")) }
    }

    @concurrent
    func reportPlayback(remoteID: String, started: Bool, positionSeconds: Double) async {
        var req = request(started ? "Sessions/Playing" : "Sessions/Playing/Stopped", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "ItemId": remoteID, "PositionTicks": Int64(positionSeconds * 10_000_000), "PlayMethod": "DirectPlay", "CanSeek": true
        ])
        _ = try? await send(req)
    }

    @concurrent
    func instantMix(remoteID: String, limit: Int) async throws -> [String] {
        let data = try await send(request("Items/\(remoteID)/InstantMix", query: ["UserId": account.userID, "Limit": "\(limit)"]))
        guard let res = try? JSONDecoder().decode(ItemsResponse.self, from: data) else { throw SourceError.decoding }
        return res.Items.map(\.Id)
    }
}

// MARK: - Subsonic (Navidrome, Gonic, Airsonic, Ampache, Nextcloud Music, …)

nonisolated struct SubsonicClient: MusicSourceClient {
    let account: SourceAccount
    let password: String

    static let apiVersion = "1.16.1"

    /// Accepts "host:port", a full URL, or a URL someone copied with "/rest" at the end.
    static func normalize(_ raw: String) -> URL? {
        guard var s = JellyfinClient.normalize(raw)?.absoluteString else { return nil }
        if s.lowercased().hasSuffix("/rest") { s.removeLast(5) }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    private static func authQuery(user: String, password: String, legacy: Bool) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "u", value: user), URLQueryItem(name: "v", value: apiVersion),
                 URLQueryItem(name: "c", value: "\(Brand.name)"), URLQueryItem(name: "f", value: "json")]
        if legacy {
            q.append(URLQueryItem(name: "p", value: "enc:" + hex(Data(password.utf8))))
        } else {
            let salt = hex((0..<8).map { _ in UInt8.random(in: 0...255) })
            q.append(URLQueryItem(name: "t", value: hex(Insecure.MD5.hash(data: Data((password + salt).utf8)))))
            q.append(URLQueryItem(name: "s", value: salt))
        }
        return q
    }

    // MARK: Requests

    private func request(_ endpoint: String, _ params: [String: String] = [:]) -> URLRequest? {
        guard var comps = URLComponents(string: account.baseURL + "/rest/" + endpoint + ".view") else { return nil }
        comps.queryItems = Self.authQuery(user: account.userName, password: password, legacy: account.legacyAuth == true)
            + params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" isn't escaped by URLComponents but most servers read it as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        return req
    }

    /// Subsonic answers 200 even for errors; the real status sits inside the JSON envelope.
    private func call<T: Decodable>(_ endpoint: String, _ params: [String: String] = [:], as type: T.Type) async throws -> T {
        guard let req = request(endpoint, params) else { throw SourceError.badURL }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw SourceError.unauthorized }
        guard (200..<300).contains(code) else { throw SourceError.server(code) }
        guard let status = try? JSONDecoder().decode(Envelope<Status>.self, from: data).response else { throw SourceError.decoding }
        if status.status != "ok" {
            let err = status.error
            switch err?.code {
            case 40, 44: throw SourceError.unauthorized
            case 70: throw SourceError.server(404)
            default: throw SourceError.api(err?.code ?? 0, err?.message)
            }
        }
        guard let body = try? JSONDecoder().decode(Envelope<T>.self, from: data).response else { throw SourceError.decoding }
        return body
    }

    // MARK: DTOs

    private struct Envelope<T: Decodable>: Decodable {
        let response: T
        enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
    }
    private struct Status: Decodable {
        struct APIError: Decodable { let code: Int; let message: String? }
        let status: String
        let error: APIError?
        let type: String?
    }
    /// Some servers send ids as numbers, most as strings.
    private struct ID: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s } else { value = String(try c.decode(Int.self)) }
        }
    }
    private struct Song: Decodable {
        struct ReplayGain: Decodable { let trackGain: Double? }
        let id: ID
        let title: String?
        let album: String?
        let artist: String?
        let albumId: ID?
        let coverArt: ID?
        let duration: Int?
        let track: Int?
        let discNumber: Int?
        let year: Int?
        let genre: String?
        let starred: String?
        let playCount: Int?
        let played: String?
        let created: String?
        let displayAlbumArtist: String?
        let displayComposer: String?
        let replayGain: ReplayGain?
        let isVideo: Bool?
    }
    private struct Search: Decodable {
        struct Result: Decodable { let song: [Song]? }
        let searchResult3: Result?
    }
    private struct AlbumList: Decodable {
        struct Album: Decodable { let id: ID }
        struct List: Decodable { let album: [Album]? }
        let albumList2: List?
    }
    private struct AlbumDetail: Decodable {
        struct Album: Decodable { let song: [Song]? }
        let album: Album?
    }
    private struct Playlists: Decodable {
        struct Item: Decodable { let id: ID; let name: String? }
        struct List: Decodable { let playlist: [Item]? }
        let playlists: List?
    }
    private struct PlaylistDetail: Decodable {
        struct Item: Decodable { let entry: [Song]? }
        let playlist: Item?
    }
    private struct Similar: Decodable {
        struct List: Decodable { let song: [Song]? }
        let similarSongs: List?
    }
    private struct ScanStatus: Decodable {
        struct Item: Decodable { let count: Int? }
        let scanStatus: Item?
    }
    private struct Lyrics: Decodable {
        struct Line: Decodable { let start: Int?; let value: String? }
        struct Structured: Decodable { let synced: Bool?; let line: [Line]? }
        struct List: Decodable { let structuredLyrics: [Structured]? }
        let lyricsList: List?
    }
    private struct Empty: Decodable {}

    private static let isoFrac = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return (try? isoFrac.parse(s)) ?? (try? isoPlain.parse(s))
    }

    private func map(_ s: Song) -> RemoteTrack {
        RemoteTrack(remoteID: s.id.value,
                    title: s.title ?? "Untitled",
                    artist: s.artist ?? s.displayAlbumArtist ?? "Unknown Artist",
                    album: s.album ?? "Unknown Album",
                    albumArtist: s.displayAlbumArtist,
                    // Art is fetched by this id, so prefer the cover id; servers usually share it across an album.
                    albumID: s.coverArt?.value ?? s.albumId?.value,
                    imageTag: s.coverArt?.value,
                    duration: Double(s.duration ?? 0),
                    trackNumber: s.track ?? 0,
                    discNumber: s.discNumber,
                    year: s.year,
                    genre: s.genre,
                    composer: s.displayComposer.flatMap { $0.isEmpty ? nil : $0 },
                    isFavorite: s.starred != nil,
                    playCount: s.playCount ?? 0,
                    lastPlayed: Self.date(s.played),
                    addedAt: Self.date(s.created),
                    normalizationGain: s.replayGain?.trackGain,
                    hasLyrics: nil)
    }

    // MARK: Login

    @concurrent
    static func login(server raw: String, user: String, password: String) async throws -> SourceAccount {
        guard let base = normalize(raw) else { throw SourceError.badURL }
        let host = base.host() ?? base.absoluteString
        var account = SourceAccount(id: "subsonic:\(base.absoluteString):\(user)", kind: .subsonic, name: host,
                                    baseURL: base.absoluteString, userID: user, userName: user, serverID: base.absoluteString)
        var status: Status
        do {
            status = try await SubsonicClient(account: account, password: password).call("ping", as: Status.self)
        } catch SourceError.api(let code, _) where code == 41 || code == 42 {
            account.legacyAuth = true
            status = try await SubsonicClient(account: account, password: password).call("ping", as: Status.self)
        }
        if let type = status.type, !type.isEmpty { account.name = "\(type.prefix(1).uppercased() + type.dropFirst()) · \(host)" }
        return account
    }

    // MARK: MusicSourceClient

    @concurrent
    func fetchLibrary(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> RemoteLibrary {
        var songs: [Song] = []
        do {
            songs = try await allSongsBySearch(progress: progress)
        } catch SourceError.unauthorized {
            throw SourceError.unauthorized
        } catch {
            songs = []
        }
        // Servers that don't list everything for an empty search get walked album by album.
        if songs.isEmpty { songs = try await allSongsByAlbum(progress: progress) }

        var seen = Set<String>()
        let tracks = songs.filter { $0.isVideo != true && seen.insert($0.id.value).inserted }.map(map)

        var playlists: [RemotePlaylist] = []
        if let list = try? await call("getPlaylists", as: Playlists.self).playlists?.playlist {
            for p in list {
                guard let detail = try? await call("getPlaylist", ["id": p.id.value], as: PlaylistDetail.self) else { continue }
                playlists.append(RemotePlaylist(remoteID: p.id.value, name: p.name ?? "Playlist",
                                                trackRemoteIDs: (detail.playlist?.entry ?? []).map(\.id.value)))
            }
        }
        return RemoteLibrary(tracks: tracks, playlists: playlists)
    }

    /// Navidrome, Gonic and most OpenSubsonic servers return every song for an empty `search3` query.
    private func allSongsBySearch(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Song] {
        let known = try? await call("getScanStatus", as: ScanStatus.self).scanStatus?.count
        var songs: [Song] = []
        let page = 500
        while true {
            let batch = try await call("search3", ["query": "", "songCount": "\(page)", "songOffset": "\(songs.count)",
                                                   "artistCount": "0", "albumCount": "0"], as: Search.self).searchResult3?.song ?? []
            songs += batch
            let more = batch.count == page
            progress(songs.count, max(known ?? 0, more ? songs.count + page : songs.count))
            if !more { break }
        }
        return songs
    }

    private func allSongsByAlbum(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Song] {
        var albumIDs: [String] = []
        let page = 500
        while true {
            let batch = try await call("getAlbumList2", ["type": "alphabeticalByName", "size": "\(page)", "offset": "\(albumIDs.count)"],
                                       as: AlbumList.self).albumList2?.album ?? []
            albumIDs += batch.map(\.id.value)
            if batch.count < page { break }
        }
        var results = [[Song]](repeating: [], count: albumIDs.count)
        var done = 0
        try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
            var next = 0
            func add() {
                guard next < albumIDs.count else { return }
                let i = next, id = albumIDs[i]
                next += 1
                group.addTask { (i, (try? await call("getAlbum", ["id": id], as: AlbumDetail.self).album?.song) ?? []) }
            }
            for _ in 0..<8 { add() }
            while let (i, songs) = try await group.next() {
                results[i] = songs
                done += 1
                progress(done, albumIDs.count)
                add()
            }
        }
        return results.flatMap { $0 }
    }

    func audioRequest(remoteID: String, maxBitrate: Int?) -> URLRequest? {
        var p = ["id": remoteID, "estimateContentLength": "true"]
        if let maxBitrate {
            p["maxBitRate"] = "\(maxBitrate / 1000)"
            p["format"] = "mp3"
        } else {
            p["format"] = "raw"
        }
        var req = request("stream", p)
        req?.timeoutInterval = 60
        return req
    }

    func imageRequest(itemID: String, maxSide: Int) -> URLRequest? {
        request("getCoverArt", ["id": itemID, "size": "\(maxSide)"])
    }

    /// OpenSubsonic `songLyrics` extension; older servers simply don't have it.
    @concurrent
    func lyrics(remoteID: String) async -> String? {
        guard let list = try? await call("getLyricsBySongId", ["id": remoteID], as: Lyrics.self).lyricsList?.structuredLyrics,
              let best = list.first(where: { $0.synced == true }) ?? list.first, let lines = best.line, !lines.isEmpty else { return nil }
        let timed = best.synced == true && lines.allSatisfy { $0.start != nil }
        return lines.map { line in
            let text = line.value ?? ""
            guard timed, let ms = line.start else { return text }
            let t = Double(ms) / 1000
            return String(format: "[%02d:%05.2f] ", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) + text
        }.joined(separator: "\n")
    }

    @concurrent
    func setFavorite(remoteID: String, _ on: Bool) async throws {
        _ = try await call(on ? "star" : "unstar", ["id": remoteID], as: Empty.self)
    }

    @concurrent
    func markPlayed(remoteID: String) async throws {
        _ = try await call("scrobble", ["id": remoteID, "submission": "true"], as: Empty.self)
    }

    /// Shows up as "now playing" on the server; the finished play is sent by `markPlayed`.
    @concurrent
    func reportPlayback(remoteID: String, started: Bool, positionSeconds: Double) async {
        guard started else { return }
        _ = try? await call("scrobble", ["id": remoteID, "submission": "false"], as: Empty.self)
    }

    @concurrent
    func instantMix(remoteID: String, limit: Int) async throws -> [String] {
        let songs = try await call("getSimilarSongs", ["id": remoteID, "count": "\(limit)"], as: Similar.self).similarSongs?.song ?? []
        return songs.map(\.id.value)
    }
}

// MARK: - Pending changes made offline

nonisolated struct SyncOp: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case favorite, unfavorite, played }
    var kind: Kind
    var sourceID: String
    var remoteID: String
    var date = Date()
}

// MARK: - Manager

@Observable
final class SourceManager {
    private(set) var accounts: [SourceAccount] = [] { didSet { save() } }
    private(set) var syncing: Set<String> = []
    private(set) var lastError: [String: String] = [:]
    private(set) var pending: [SyncOp] = [] { didSet { savePending() } }

    var autoSync: Bool { didSet { UserDefaults.standard.set(autoSync, forKey: "autoSync") } }
    /// kbit/s; 0 = original quality.
    var streamBitrate: Int { didSet { UserDefaults.standard.set(streamBitrate, forKey: "streamBitrate") } }
    var downloadBitrate: Int { didSet { UserDefaults.standard.set(downloadBitrate, forKey: "downloadBitrate") } }
    var cellularBitrate: Int { didSet { UserDefaults.standard.set(cellularBitrate, forKey: "cellularBitrate") } }
    var skipLocalDuplicates: Bool { didSet { UserDefaults.standard.set(skipLocalDuplicates, forKey: "skipLocalDupes") } }

    @ObservationIgnored let library: LibraryStore
    private static var fileURL: URL { Paths.support.appendingPathComponent("sources.json") }
    private static var pendingURL: URL { Paths.support.appendingPathComponent("pending-sync.json") }

    init(library: LibraryStore) {
        self.library = library
        let d = UserDefaults.standard
        autoSync = d.object(forKey: "autoSync") as? Bool ?? true
        streamBitrate = d.object(forKey: "streamBitrate") as? Int ?? 320
        downloadBitrate = d.object(forKey: "downloadBitrate") as? Int ?? 0
        cellularBitrate = d.object(forKey: "cellularBitrate") as? Int ?? 192
        skipLocalDuplicates = d.object(forKey: "skipLocalDupes") as? Bool ?? true
        if let data = try? Data(contentsOf: Self.fileURL), let wrapped = try? JSONDecoder().decode([LossyAccount].self, from: data) {
            // Accounts of a source kind that no longer exists (e.g. removed services) are dropped instead of breaking every account.
            let list: [SourceAccount] = wrapped.compactMap { $0.value }
            accounts = list
            if list.count != wrapped.count { dropStaleSources(keeping: Set(list.map { $0.id })) }
        }
        if let data = try? Data(contentsOf: Self.pendingURL), let ops = try? JSONDecoder().decode([SyncOp].self, from: data) { pending = ops }
        NetworkMonitor.shared.onReconnect = { [weak self] in Task { await self?.flushPending() } }
    }

    /// Removes songs and playlists that belonged to a removed service (its saved accounts can no longer be read).
    private func dropStaleSources(keeping valid: Set<String>) {
        let prefix: String = "octave:"
        var stale: Set<UUID> = []
        for t in library.tracks {
            guard let s = t.sourceID else { continue }
            if s.hasPrefix(prefix) && !valid.contains(s) { stale.insert(t.id) }
        }
        if !stale.isEmpty { library.delete(stale) }
        library.playlists.removeAll { p in
            guard let s = p.sourceID else { return false }
            return s.hasPrefix(prefix) && !valid.contains(s)
        }
    }

    var hasSources: Bool { !accounts.isEmpty }

    func client(for sourceID: String?) -> (any MusicSourceClient)? {
        guard let sourceID, let acc = accounts.first(where: { $0.id == sourceID }), acc.enabled,
              let token = Keychain.get("token:\(acc.id)") else { return nil }
        switch acc.kind {
        case .jellyfin: return JellyfinClient(account: acc, token: token)
        case .subsonic: return SubsonicClient(account: acc, password: token)
        }
    }

    func account(_ id: String?) -> SourceAccount? { accounts.first { $0.id == id } }

    // MARK: Accounts

    func addJellyfin(server: String, user: String, password: String) async throws {
        let (account, token) = try await JellyfinClient.login(server: server, user: user, password: password)
        Keychain.set(token, for: "token:\(account.id)")
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        await sync(account.id)
    }

    /// Subsonic signs every request with the password, so the Keychain keeps the password instead of a token.
    func addSubsonic(server: String, user: String, password: String) async throws {
        let account = try await SubsonicClient.login(server: server, user: user, password: password)
        Keychain.set(password, for: "token:\(account.id)")
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        await sync(account.id)
    }

    func remove(_ id: String) {
        Keychain.remove("token:\(id)")
        accounts.removeAll { $0.id == id }
        let ids = Set(library.tracks.filter { $0.sourceID == id }.map(\.id))
        library.delete(ids)
        library.playlists.removeAll { $0.sourceID == id }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].enabled = on
    }

    // MARK: Sync

    func syncAll() async {
        for acc in accounts where acc.enabled { await sync(acc.id) }
    }

    func sync(_ id: String) async {
        guard !syncing.contains(id), let client = client(for: id) else { return }
        guard NetworkMonitor.shared.isOnline else { lastError[id] = SourceError.offline.localizedDescription; return }
        syncing.insert(id)
        defer { syncing.remove(id) }
        lastError[id] = nil
        let name = client.account.name
        library.importStatus = ImportStatus(title: "Syncing \(name)", done: 0, total: 0)
        do {
            let remote = try await client.fetchLibrary { done, total in
                Task { @MainActor [weak self] in
                    self?.library.importStatus?.done = done
                    self?.library.importStatus?.total = total
                }
            }
            apply(remote, for: id)
            if let i = accounts.firstIndex(where: { $0.id == id }) {
                accounts[i].lastSync = Date()
                accounts[i].trackCount = library.tracks.filter { $0.sourceID == id }.count
            }
            await flushPending()
        } catch {
            lastError[id] = error.localizedDescription
        }
        library.finishStatus()
        Task { await ArtworkFetcher.shared.fetchMissing(library: library, sources: self) }
    }

    /// Upserts remote songs by their server id, keeps local play counts, removes what's gone from the server.
    private func apply(_ remote: RemoteLibrary, for sourceID: String) {
        let existing = library.tracks.filter { $0.sourceID == sourceID }
        var byRemote: [String: Track] = [:]
        for t in existing { if let r = t.remoteID { byRemote[r] = t } }

        func norm(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber } }
        var localKeys: [String: [Double]] = [:]
        if skipLocalDuplicates {
            for t in library.tracks where !t.isRemote { localKeys["\(norm(t.title))|\(norm(t.artist))", default: []].append(t.duration) }
        }

        var result: [Track] = []
        var seen = Set<String>()
        for r in remote.tracks {
            seen.insert(r.remoteID)
            if byRemote[r.remoteID] == nil, let durations = localKeys["\(norm(r.title))|\(norm(r.artist))"],
               durations.contains(where: { abs($0 - r.duration) < 3 }) { continue }
            var t = byRemote[r.remoteID] ?? Track(title: r.title, artist: r.artist, album: r.album, duration: r.duration, path: "")
            if t.metadataLocked != true {
                t.title = r.title; t.artist = r.artist; t.album = r.album
                t.trackNumber = r.trackNumber; t.discNumber = r.discNumber
                t.albumArtist = r.albumArtist; t.year = r.year; t.genre = r.genre; t.composer = r.composer
            }
            if r.duration > 0 { t.duration = r.duration }
            t.sourceID = sourceID
            t.remoteID = r.remoteID
            t.remoteAlbumID = r.albumID
            if t.remoteImageTag != r.imageTag { t.remoteImageTag = r.imageTag; if byRemote[r.remoteID] != nil { t.hasArtwork = t.hasArtwork && r.imageTag != nil } }
            t.isFavorite = r.isFavorite || pending.contains { $0.remoteID == r.remoteID && $0.kind == .favorite }
            if pending.contains(where: { $0.remoteID == r.remoteID && $0.kind == .unfavorite }) { t.isFavorite = false }
            t.playCount = max(t.playCount ?? 0, r.playCount)
            if let lp = r.lastPlayed, lp > (t.lastPlayed ?? .distantPast) { t.lastPlayed = lp }
            if byRemote[r.remoteID] == nil, let added = r.addedAt { t.addedAt = added }
            if let g = r.normalizationGain { t.replayGain = g }
            result.append(t)
        }
        let gone = Set(existing.filter { clientKindAllowsRemoval(sourceID) && !seen.contains($0.remoteID ?? "") }.map(\.id))
        if !gone.isEmpty { library.delete(gone) }
        library.upsert(result)

        // Playlists from the server become (read-only mirrored) Music playlists.
        let idByRemote = Dictionary(result.compactMap { t in t.remoteID.map { ($0, t.id) } }, uniquingKeysWith: { a, _ in a })
        var lists = library.playlists
        for rp in remote.playlists {
            let ids = rp.trackRemoteIDs.compactMap { idByRemote[$0] }
            if let i = lists.firstIndex(where: { $0.sourceID == sourceID && $0.remoteID == rp.remoteID }) {
                lists[i].name = rp.name
                lists[i].trackIDs = ids
            } else {
                lists.append(Playlist(name: rp.name, trackIDs: ids, sourceID: sourceID, remoteID: rp.remoteID))
            }
        }
        let remoteIDs = Set(remote.playlists.map(\.remoteID))
        lists.removeAll { $0.sourceID == sourceID && !remoteIDs.contains($0.remoteID ?? "") }
        library.playlists = lists
    }

    private func clientKindAllowsRemoval(_ sourceID: String) -> Bool {
        true
    }

    // MARK: Favorites / plays (queued while offline)

    func favoriteChanged(_ track: Track) {
        guard track.isRemote, let r = track.remoteID, let s = track.sourceID, account(s) != nil else { return }
        pending.removeAll { $0.remoteID == r && ($0.kind == .favorite || $0.kind == .unfavorite) }
        pending.append(SyncOp(kind: track.isFavorite ? .favorite : .unfavorite, sourceID: s, remoteID: r))
        Task { await flushPending() }
    }

    func played(_ track: Track) {
        guard track.isRemote, let r = track.remoteID, let s = track.sourceID, account(s) != nil else { return }
        pending.append(SyncOp(kind: .played, sourceID: s, remoteID: r))
        Task { await flushPending() }
    }

    func flushPending() async {
        guard NetworkMonitor.shared.isOnline, !pending.isEmpty else { return }
        for op in pending {
            guard let client = client(for: op.sourceID) else { continue }
            do {
                switch op.kind {
                case .favorite: try await client.setFavorite(remoteID: op.remoteID, true)
                case .unfavorite: try await client.setFavorite(remoteID: op.remoteID, false)
                case .played: try await client.markPlayed(remoteID: op.remoteID)
                }
                pending.removeAll { $0 == op }
            } catch {
                if case SourceError.server(let code) = error, code == 404 { pending.removeAll { $0 == op } }
            }
        }
    }

    func bitrate(forDownload: Bool) -> Int? {
        let kbps = forDownload ? downloadBitrate : (NetworkMonitor.shared.isExpensive ? cellularBitrate : streamBitrate)
        return kbps == 0 ? nil : kbps * 1000
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
    private func savePending() {
        if let data = try? JSONEncoder().encode(pending) { try? data.write(to: Self.pendingURL, options: .atomic) }
    }
}

// MARK: - Artwork for streaming songs

@MainActor
final class ArtworkFetcher {
    static let shared = ArtworkFetcher()
    private var running = false
    private var runningModules = false
    /// Covers that failed this session; not asked for again until the next launch.
    private var failed = Set<String>()

    /// Cover links from modules: one download per distinct image, linked for every song that uses it.
    func fetchModuleCovers(library: LibraryStore) async {
        guard !runningModules, NetworkMonitor.shared.isOnline else { return }
        runningModules = true
        defer { runningModules = false }
        let missing = library.allTracks.filter { !$0.hasArtwork && $0.artworkURL != nil }
        for (link, tracks) in Dictionary(grouping: missing, by: { $0.artworkURL ?? "" }) where !failed.contains(link) {
            guard let url = URL(string: link), let first = tracks.first,
                  let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else { failed.insert(link); continue }
            let ok = await Task.detached { ArtworkWriter.writeJPEG(from: data, for: first.id, maxPixel: 700) }.value
            guard ok else { continue }
            for t in tracks where t.id != first.id {
                try? FileManager.default.removeItem(at: Paths.artworkURL(for: t.id))
                try? FileManager.default.copyItem(at: Paths.artworkURL(for: first.id), to: Paths.artworkURL(for: t.id))
            }
            library.updateMany(Set(tracks.map(\.id))) { $0.hasArtwork = true; $0.artSource = .server; $0.artVersion = ($0.artVersion ?? 0) + 1 }
            for t in tracks { ArtworkCache.evict(t.id) }
        }
    }

    /// Downloads album art once per album and hard-links it for every song of that album (no extra space).
    func fetchMissing(library: LibraryStore, sources: SourceManager) async {
        guard !running, NetworkMonitor.shared.isOnline else { return }
        running = true
        defer { running = false }
        let missing = library.tracks.filter { $0.isRemote && !$0.hasArtwork && $0.remoteImageTag != nil }
        let groups = Dictionary(grouping: missing) { $0.remoteAlbumID ?? $0.remoteID ?? "" }
        var done: [Track] = []
        for (albumID, tracks) in groups {
            let key = "\(tracks.first?.sourceID ?? "")|\(albumID)"
            guard !failed.contains(key) else { continue }
            guard let first = tracks.first, let client = sources.client(for: first.sourceID),
                  let req = client.imageRequest(itemID: albumID.isEmpty ? (first.remoteID ?? "") : albumID, maxSide: 700),
                  let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { failed.insert(key); continue }
            let ok = await Task.detached { ArtworkWriter.writeJPEG(from: data, for: first.id, maxPixel: 700) }.value
            guard ok else { continue }
            for t in tracks {
                if t.id != first.id {
                    try? FileManager.default.removeItem(at: Paths.artworkURL(for: t.id))
                    if (try? FileManager.default.linkItem(at: Paths.artworkURL(for: first.id), to: Paths.artworkURL(for: t.id))) == nil {
                        try? FileManager.default.copyItem(at: Paths.artworkURL(for: first.id), to: Paths.artworkURL(for: t.id))
                    }
                }
                    done.append(t)
            }
            if done.count > 200 { mark(done); done.removeAll() }
        }
        if !done.isEmpty { mark(done) }

        func mark(_ list: [Track]) {
            library.updateMany(Set(list.map(\.id))) { $0.hasArtwork = true; $0.artSource = .server; $0.artVersion = ($0.artVersion ?? 0) + 1 }
            for t in list { ArtworkCache.evict(t.id) }
        }
    }
}
