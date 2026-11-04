/*
 * Atoll_Paco (fork personal de Atoll)
 * Copyright (C) 2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Foundation
import Security

/// Atoll_Paco: la app de escritorio de TIDAL le pasa a macOS una portada de
/// 150×150 px y en el notch se ve borrosa. Cuando la música viene de TIDAL (y
/// solo entonces), esto busca la canción en la API oficial de TIDAL
/// (openapi.tidal.com/v2) y baja la portada del álbum en alta resolución.
///
/// Necesita credenciales de una app registrada en developer.tidal.com, guardadas
/// en el Keychain (ver scripts/tidal-credentials.sh). Sin credenciales no hace nada.
actor TidalArtworkResolver {
    static let shared = TidalArtworkResolver()

    static let tidalBundleIdentifier = "com.tidal.desktop"

    /// Portadas con su lado mayor por debajo de esto se intentan mejorar.
    static let minimumAcceptablePixels = 500
    /// Se escoge el archivo más grande que no pase de esto (TIDAL tiene hasta 1280).
    private static let preferredMaxPixels = 1280

    static let keychainService = "com.pacocerv08.AtollPaco.tidal"
    private static let tokenURL = URL(string: "https://auth.tidal.com/v1/oauth2/token")!
    private static let apiBase = "https://openapi.tidal.com/v2"
    private static let cacheLimit = 60
    private static let maxCandidates = 3

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    private var token: String?
    private var tokenExpiry = Date.distantPast
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private var misses: Set<String> = []

    // MARK: - API pública

    /// `true` si la imagen se puede leer y su lado mayor mide menos de `minimumAcceptablePixels`.
    static func isLowResolution(_ data: Data) -> Bool {
        guard let rep = NSBitmapImageRep(data: data) else { return false }
        return max(rep.pixelsWide, rep.pixelsHigh) < minimumAcceptablePixels
    }

    /// Bytes de la portada en alta resolución, o `nil` si no hay credenciales o coincidencia.
    func artwork(title: String, artist: String, album: String) async -> Data? {
        let key = Self.normalize(title) + "|" + Self.normalize(artist) + "|" + Self.normalize(album)
        guard !Self.normalize(title).isEmpty, !Self.normalize(artist).isEmpty else { return nil }

        if let cached = cache[key] { return cached }
        if misses.contains(key) { return nil }

        guard let accessToken = await validToken() else { return nil }  // sin credenciales: no se marca como miss

        guard let url = await coverURL(title: title, artist: artist, album: album, token: accessToken),
              let data = await download(url),
              NSImage(data: data) != nil
        else {
            misses.insert(key)
            return nil
        }

        store(data, for: key)
        return data
    }

    // MARK: - Token (client credentials)

    private func validToken() async -> String? {
        if let token, tokenExpiry > Date().addingTimeInterval(60) { return token }

        guard let clientID = Self.keychainValue(account: "client-id"),
              let clientSecret = Self.keychainValue(account: "client-secret")
        else { return nil }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            Logger.log("TidalArtworkResolver: no se pudo obtener token de TIDAL", category: .warning)
            return nil
        }

        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        token = accessToken
        tokenExpiry = Date().addingTimeInterval(expiresIn)
        return accessToken
    }

    private static func keychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    // MARK: - Búsqueda en el catálogo

    private func coverURL(title: String, artist: String, album: String, token: String) async -> URL? {
        // 1) Buscar "título artista" y quedarse con los tracks cuyo título coincide.
        let query = "\(Self.canonicalTitle(title)) \(artist)"
        guard let search = await getJSON(
            path: "/searchResults",
            query: [
                URLQueryItem(name: "filter[query]", value: query),
                URLQueryItem(name: "countryCode", value: Self.countryCode),
                URLQueryItem(name: "include", value: "tracks")
            ],
            token: token
        ) else { return nil }

        let rankedIDs = Self.relationshipIDs(search["data"], "tracks")
        let includedTracks = Self.included(search, type: "tracks")
        let wantedTitle = Self.canonicalTitle(title)

        let candidates = rankedIDs.filter { id in
            guard let attributes = includedTracks[id]?["attributes"] as? [String: Any],
                  let trackTitle = attributes["title"] as? String
            else { return false }
            let got = Self.canonicalTitle(trackTitle)
            return got == wantedTitle || got.contains(wantedTitle) || wantedTitle.contains(got)
        }

        // 2) Para cada candidato, confirmar artista y sacar la portada del álbum.
        var best: (url: URL, score: Int)?
        for trackID in candidates.prefix(Self.maxCandidates) {
            // Primero con include anidado (track + artistas + álbum + portada en 1 request);
            // si el endpoint no lo acepta, sin la portada y se pide aparte.
            var maybeTrack = await getJSON(
                path: "/tracks/\(trackID)",
                query: [
                    URLQueryItem(name: "countryCode", value: Self.countryCode),
                    URLQueryItem(name: "include", value: "artists,albums.coverArt")
                ],
                token: token
            )
            if maybeTrack == nil {
                maybeTrack = await getJSON(
                    path: "/tracks/\(trackID)",
                    query: [
                        URLQueryItem(name: "countryCode", value: Self.countryCode),
                        URLQueryItem(name: "include", value: "artists,albums")
                    ],
                    token: token
                )
            }
            guard let track = maybeTrack else { continue }

            let artists = Self.included(track, type: "artists").values
                .compactMap { ($0["attributes"] as? [String: Any])?["name"] as? String }
            guard Self.artistMatches(wanted: artist, got: artists) else { continue }

            let albums = Self.included(track, type: "albums")
            var artworks = Self.included(track, type: "artworks")

            for albumID in Self.relationshipIDs(track["data"], "albums") {
                guard let albumResource = albums[albumID] else { continue }
                let albumTitle = (albumResource["attributes"] as? [String: Any])?["title"] as? String ?? ""

                var score = 10
                let wantedAlbum = Self.canonicalTitle(album)
                let gotAlbum = Self.canonicalTitle(albumTitle)
                if !wantedAlbum.isEmpty {
                    if gotAlbum == wantedAlbum { score += 5 }
                    else if gotAlbum.contains(wantedAlbum) || wantedAlbum.contains(gotAlbum) { score += 2 }
                }

                var artworkIDs = Self.relationshipIDs(albumResource, "coverArt")
                if artworkIDs.isEmpty || artworkIDs.allSatisfy({ artworks[$0] == nil }),
                   let cover = await getJSON(
                       path: "/albums/\(albumID)/relationships/coverArt",
                       query: [
                           URLQueryItem(name: "countryCode", value: Self.countryCode),
                           URLQueryItem(name: "include", value: "coverArt")
                       ],
                       token: token
                   ) {
                    artworks.merge(Self.included(cover, type: "artworks")) { current, _ in current }
                    let ids = (cover["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
                    if !ids.isEmpty { artworkIDs = ids }
                }

                for artworkID in artworkIDs {
                    guard let url = Self.bestFileURL(artworks[artworkID]) else { continue }
                    if best == nil || score > best!.score { best = (url, score) }
                }
            }

            if let best, best.score >= 15 { break }  // álbum exacto: no hace falta seguir
        }

        return best?.url
    }

    private func getJSON(path: String, query: [URLQueryItem], token: String) async -> [String: Any]? {
        guard var components = URLComponents(string: Self.apiBase + path) else { return nil }
        components.queryItems = query
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }

        if http.statusCode == 401 {
            self.token = nil  // se pide uno nuevo la próxima vez
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            Logger.log("TidalArtworkResolver: HTTP \(http.statusCode) en \(path)", category: .warning)
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }

    private func store(_ data: Data, for key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
            while cacheOrder.count > Self.cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[key] = data
    }

    // MARK: - JSON:API helpers

    /// IDs de una relación (`relationships.<name>.data[].id`), en orden.
    private static func relationshipIDs(_ resource: Any?, _ name: String) -> [String] {
        guard let resource = resource as? [String: Any],
              let relationships = resource["relationships"] as? [String: Any],
              let relationship = relationships[name] as? [String: Any]
        else { return [] }

        if let list = relationship["data"] as? [[String: Any]] {
            return list.compactMap { $0["id"] as? String }
        }
        if let single = relationship["data"] as? [String: Any], let id = single["id"] as? String {
            return [id]
        }
        return []
    }

    /// Recursos de `included` de un tipo, indexados por id.
    private static func included(_ document: [String: Any], type: String) -> [String: [String: Any]] {
        guard let included = document["included"] as? [[String: Any]] else { return [:] }
        var result: [String: [String: Any]] = [:]
        for resource in included where resource["type"] as? String == type {
            if let id = resource["id"] as? String { result[id] = resource }
        }
        return result
    }

    /// El archivo de imagen más grande que no pase de `preferredMaxPixels`.
    private static func bestFileURL(_ artwork: [String: Any]?) -> URL? {
        guard let attributes = artwork?["attributes"] as? [String: Any],
              let files = attributes["files"] as? [[String: Any]]
        else { return nil }

        let sized: [(url: URL, width: Int)] = files.compactMap { file in
            guard let href = file["href"] as? String, let url = URL(string: href) else { return nil }
            let width = ((file["meta"] as? [String: Any])?["width"] as? NSNumber)?.intValue ?? 0
            return (url, width)
        }

        let withinLimit = sized.filter { $0.width <= preferredMaxPixels }
        return (withinLimit.max { $0.width < $1.width } ?? sized.max { $0.width < $1.width })?.url
    }

    // MARK: - Coincidencia

    private static var countryCode: String {
        Locale.current.region?.identifier ?? "US"
    }

    private static func artistMatches(wanted: String, got: [String]) -> Bool {
        let wantedNorm = normalize(wanted)
        guard !wantedNorm.isEmpty else { return false }
        return got.map(normalize).contains { name in
            !name.isEmpty && (name == wantedNorm || wantedNorm.contains(name) || name.contains(wantedNorm))
        }
    }

    private static func canonicalTitle(_ value: String) -> String {
        var title = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        title = title.replacingOccurrences(
            of: #"\([^)]*\)|\[[^\]]*\]"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"\s-\s(?:\d{4}\s)?(?:remaster(?:ed)?|live|edit|mix|version|mono|stereo).*$"#,
            with: " ",
            options: .regularExpression
        )
        return normalize(title)
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
