//
//  LibraryDisplaySettings.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation

import Foundation
import UIKit

// MARK: - LibraryDisplayType

@MainActor
public enum LibraryDisplayType: Int, CaseIterable, Sendable {
  case artists = 0
  case albums = 1
  case songs = 2
  case genres = 3
  case directories = 4
  case playlists = 5
  case podcasts = 6
  case downloads = 7
  case favoriteSongs = 8
  case favoriteAlbums = 9
  case favoriteArtists = 10
  // case recentSongs = 11 not used anymore
  case newestAlbums = 12
  case recentAlbums = 13
  case radios = 14
  case spotifyPlaylists = 15 // shown as "Deine Top-Mixes"
  case ownMixes = 16

  public static func createByDisplayName(name: String) -> LibraryDisplayType? {
    .allCases.first {
      $0.displayName == name
    }
  }

  public var displayName: String {
    switch self {
    case .artists:
      return "Artists"
    case .albums:
      return "Albums"
    case .songs:
      return "Songs"
    case .genres:
      return "Genres"
    case .directories:
      return "Directories"
    case .playlists:
      return "Playlists"
    case .podcasts:
      return "Podcasts"
    case .downloads:
      return "Downloads"
    case .favoriteSongs:
      return "Favorite Songs"
    case .favoriteAlbums:
      return "Favorite Albums"
    case .favoriteArtists:
      return "Favorite Artists"
    case .newestAlbums:
      return "Newest Albums"
    case .recentAlbums:
      return "Recently Played Albums"
    case .radios:
      return "Radios"
    case .spotifyPlaylists:
      return "Deine Top-Mixes"
    case .ownMixes:
      return "Deine Mixes"
    }
  }

  public var image: UIImage {
    switch self {
    case .artists:
      return UIImage.artist
    case .albums:
      return UIImage.album
    case .songs:
      return UIImage.musicalNotes
    case .genres:
      return UIImage.genre
    case .directories:
      return UIImage.folder
    case .playlists:
      return UIImage.playlist
    case .podcasts:
      return UIImage.podcast
    case .downloads:
      return UIImage.download
    case .favoriteSongs:
      return UIImage.heartFill
    case .favoriteAlbums:
      return UIImage.heartFill
    case .favoriteArtists:
      return UIImage.heartFill
    case .newestAlbums:
      return UIImage.albumNewest
    case .recentAlbums:
      return UIImage.albumRecent
    case .radios:
      return UIImage.radio
    case .spotifyPlaylists:
      return UIImage.topMixes
    case .ownMixes:
      return UIImage.ownMixes
    }
  }
}

// MARK: - LibraryDisplaySettings

public struct LibraryDisplaySettings: Sendable, Codable {
  /// all library types (in use and not used) in the order arranged by the user
  public private(set) var order: [LibraryDisplayType]
  private var inUseTypes: Set<LibraryDisplayType>

  public var inUse: [LibraryDisplayType] {
    order.filter { inUseTypes.contains($0) }
  }

  public var notUsed: [LibraryDisplayType] {
    order.filter { !inUseTypes.contains($0) }
  }

  private enum CodingKeys: String, CodingKey {
    case combined
    case order
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    // combined: [inUse, notUsed], the stored format before the order was persisted
    let encodedCombined = [inUse, notUsed].map { $0.map { $0.rawValue } }
    try container.encode(encodedCombined, forKey: .combined)
    try container.encode(order.map { $0.rawValue }, forKey: .order)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedCombined = try container.decode([[Int]].self, forKey: .combined)
    // not present in settings stored before the order was persisted
    let decodedOrder = try container.decodeIfPresent([Int].self, forKey: .order)

    let mapped: [[LibraryDisplayType]] = decodedCombined.map { group in
      group.compactMap { LibraryDisplayType(rawValue: $0) }
    }

    if mapped.count == 2 {
      var order = decodedOrder?.compactMap { LibraryDisplayType(rawValue: $0) } ?? mapped[0] +
        mapped[1]
      var inUse = Set(mapped[0])
      // FireSonic: "Spotify Playlists" was added later. Settings stored before that
      // don't know the type yet -> show it once, right after "Playlists".
      if !order.contains(.spotifyPlaylists) {
        let insertAt = (order.firstIndex(of: .playlists).map { $0 + 1 }) ?? order.count
        order.insert(.spotifyPlaylists, at: insertAt)
        inUse.insert(.spotifyPlaylists)
      }
      // FireSonic: "Deine Mixes" (Eigene-Mixe plugin) was added after that.
      if !order.contains(.ownMixes) {
        let insertAt = (order.firstIndex(of: .spotifyPlaylists).map { $0 + 1 }) ?? order.count
        order.insert(.ownMixes, at: insertAt)
        inUse.insert(.ownMixes)
      }
      self = LibraryDisplaySettings(order: order, inUse: inUse)
    } else if let first = mapped.first {
      // If only one group present, treat it as inUse and compute notUsed
      self = LibraryDisplaySettings(inUse: first)
    } else {
      // Fallback to defaults if decoding produced no valid entries
      self = LibraryDisplaySettings(inUse: [])
    }
  }

  public func isVisible(libraryType: LibraryDisplayType) -> Bool {
    inUseTypes.contains(libraryType)
  }

  /// The types not in use follow the ones in use, sorted by their raw value.
  public init(inUse: [LibraryDisplayType]) {
    let notUsed = Set(LibraryDisplayType.allCases).subtracting(Set(inUse))
      .sorted(by: { $0.rawValue < $1.rawValue })
    self.init(order: inUse + notUsed, inUse: Set(inUse))
  }

  /// Keeps the order arranged by the user; types missing in `order` (e.g. new ones) are appended.
  public init(order: [LibraryDisplayType], inUse: Set<LibraryDisplayType>) {
    self.order = order.completingOrder(with: LibraryDisplayType.allCases)
    self.inUseTypes = inUse
  }

  public static var defaultSettings: LibraryDisplaySettings {
    LibraryDisplaySettings(
      inUse: [
        .artists,
        .albums,
        .newestAlbums,
        .recentAlbums,
        .songs,
        .favoriteSongs,
        .directories,
        .playlists,
        .spotifyPlaylists,
        .ownMixes,
        .podcasts,
        .radios,
      ]
    )
  }

  public static var addToPlaylistSettings: LibraryDisplaySettings {
    LibraryDisplaySettings(
      inUse: [
        .genres,
        .artists,
        .favoriteArtists,
        .albums,
        .favoriteAlbums,
        .newestAlbums,
        .recentAlbums,
        .songs,
        .favoriteSongs,
        .directories,
        .playlists,
      ]
    )
  }
}

// MARK: - PlaylistCategory

/// FireSonic: playlists created by the Navidrome plugins are marked in their comment.
/// - "[spotify-mix:<id>]" → Spotify mix (Spotify Playlist Import plugin, type "Mix") → "Deine Top-Mixes"
/// - "[mix:<key>]" → mix of the "Eigene Mixe" plugin → "Deine Mixes"
/// Every other playlist (also normal Spotify imports) stays under "Playlists".
public enum PlaylistCategory: String, Sendable, Codable {
  case topMix
  case ownMix

  public static func detect(comment: String?) -> PlaylistCategory? {
    guard let comment, !comment.isEmpty else { return nil }
    if comment.contains("[spotify-mix:") { return .topMix }
    if comment.hasPrefix("[mix:") || comment.contains("\n[mix:") { return .ownMix }
    return nil
  }
}

// MARK: - PlaylistCategoryFilter

public enum PlaylistCategoryFilter: Sendable, Equatable {
  case all
  /// normal playlists: neither top mixes nor own mixes
  case regular
  case only(PlaylistCategory)
}

// MARK: - PlaylistCategoryRegistry

/// Remembers the category and the server cover id of every playlist. Both are read from
/// the getPlaylists response (attributes "comment" and "coverArt") during the playlist sync.
/// Stored in UserDefaults, so the Core Data model stays untouched.
public enum PlaylistCategoryRegistry {
  private static let categoryKey = "firesonic.playlistCategories"
  private static let coverKey = "firesonic.playlistCoverArt"
  private static let legacyKey = "firesonic.spotifyPlaylistIds"
  public static let changedNotification = Notification
    .Name(rawValue: "de.jannes.firesonic.playlistCategoriesChanged")

  public static var categories: [String: PlaylistCategory] {
    let raw = UserDefaults.standard.dictionary(forKey: categoryKey) as? [String: String] ?? [:]
    return raw.compactMapValues { PlaylistCategory(rawValue: $0) }
  }

  public static var coverArtIds: [String: String] {
    UserDefaults.standard.dictionary(forKey: coverKey) as? [String: String] ?? [:]
  }

  public static func category(ofPlaylistId id: String) -> PlaylistCategory? {
    categories[id]
  }

  public static func coverArtId(ofPlaylistId id: String) -> String? {
    coverArtIds[id]
  }

  public static func ids(of category: PlaylistCategory) -> [String] {
    categories.filter { $0.value == category }.map { $0.key }
  }

  /// Replaces the stored data with the result of the latest playlist sync.
  public static func replace(categories newCategories: [String: PlaylistCategory], covers: [String: String]) {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: legacyKey)
    let changedCovers = covers != coverArtIds
    let changedCategories = newCategories != categories
    guard changedCovers || changedCategories else { return }
    defaults.set(newCategories.mapValues { $0.rawValue }, forKey: categoryKey)
    defaults.set(covers, forKey: coverKey)
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: changedNotification, object: nil)
    }
  }

  public static func predicate(for filter: PlaylistCategoryFilter) -> NSPredicate? {
    switch filter {
    case .all:
      return nil
    case .regular:
      return NSPredicate(format: "NOT (%K IN %@)", "id", Array(categories.keys))
    case let .only(category):
      return NSPredicate(format: "%K IN %@", "id", ids(of: category))
    }
  }
}

// MARK: - Blackbox: Rückblicke (Navidrome-Plugin "Rückblick")

/// Data written by the Rückblick plugin into the second line of the playlist comment,
/// right after the marker "[recap:<month|year>:<id>]".
public struct RecapData: Codable, Sendable, Hashable {
  public struct Item: Codable, Sendable, Hashable {
    public let n: String
    public let s: String?
    public let p: Int?
    public let m: Int?
    public let a: String?

    public var name: String { n }
    public var sub: String? { s }
    public var plays: Int { p ?? 0 }
    public var minutes: Int { m ?? 0 }
    /// cover art id for getCoverArt (media file of a representative song)
    public var coverArtId: String? { a.map { "mf-\($0)" } }
    public var songId: String? { a }
  }

  public let v: Int?
  public let k: String
  public let l: String
  public let id: String
  public let fin: Bool?
  public let min: Int
  public let pl: Int
  public let pm: Int?
  public let plb: String?
  public let ds: Int?
  public let da: Int?
  public let na: Int?
  public let ts: [Item]?
  public let ta: [Item]?
  public let tal: [Item]?
  public let tg: [Item]?
  public let bm: String?
  public let bw: String?
  public let ph: Int?
  public let dp: String?
  public let st: Int?
  public let td: String?
  public let tdm: Int?
  public let fs: Item?
  public let tyn: String?
  public let tyd: String?

  public var isYear: Bool { k == "year" }
  public var label: String { l }
  public var periodId: String { id }
  public var minutes: Int { min }
  public var plays: Int { pl }
  public var topSongs: [Item] { ts ?? [] }
  public var topArtists: [Item] { ta ?? [] }
  public var topAlbums: [Item] { tal ?? [] }
  public var topGenres: [Item] { tg ?? [] }

  public static func parse(comment: String?) -> RecapData? {
    guard let comment, let range = comment.range(of: "[recap:") else { return nil }
    let rest = comment[range.lowerBound...]
    let lines = rest.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
    guard lines.count >= 2 else { return nil }
    let json = lines[1].trimmingCharacters(in: .whitespaces)
    guard json.hasPrefix("{"), let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(RecapData.self, from: data)
  }
}

public enum RecapRegistry {
  private static let dataKey = "blackbox.recaps"
  private static let seenKey = "blackbox.recapsSeen"
  public static let changedNotification = Notification
    .Name(rawValue: "de.jannes.blackbox.recapsChanged")

  /// playlist id -> recap data
  public static var recaps: [String: RecapData] {
    guard let data = UserDefaults.standard.data(forKey: dataKey),
          let decoded = try? JSONDecoder().decode([String: RecapData].self, from: data)
    else { return [:] }
    return decoded
  }

  public static func replace(_ new: [String: RecapData]) {
    guard new != recaps else { return }
    if let data = try? JSONEncoder().encode(new) {
      UserDefaults.standard.set(data, forKey: dataKey)
    }
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: changedNotification, object: nil)
    }
  }

  /// newest first, years before months of the same period
  public static var sortedPlaylistIds: [(playlistId: String, data: RecapData)] {
    recaps.map { (playlistId: $0.key, data: $0.value) }
      .sorted { $0.data.periodId > $1.data.periodId }
  }

  private static func seenKeyFor(_ data: RecapData) -> String { "\(data.k):\(data.id)" }

  public static func isSeen(_ data: RecapData) -> Bool {
    (UserDefaults.standard.stringArray(forKey: seenKey) ?? []).contains(seenKeyFor(data))
  }

  public static func markSeen(_ data: RecapData) {
    var seen = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
    guard !seen.contains(seenKeyFor(data)) else { return }
    seen.append(seenKeyFor(data))
    UserDefaults.standard.set(seen, forKey: seenKey)
    NotificationCenter.default.post(name: changedNotification, object: nil)
  }
}

// MARK: - Blackbox: Darstellung

public enum BlackboxAppearance {
  private static let titleKey = "blackbox.homeTitle"
  private static let accentKey = "blackbox.accentRGBA"
  public static let changedNotification = Notification
    .Name(rawValue: "de.jannes.blackbox.appearanceChanged")

  public static var homeTitle: String {
    get {
      let t = UserDefaults.standard.string(forKey: titleKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return t.isEmpty ? "Home" : t
    }
    set {
      UserDefaults.standard.set(newValue, forKey: titleKey)
      NotificationCenter.default.post(name: changedNotification, object: nil)
    }
  }

  /// custom accent color; nil = color of the theme preference
  public static var customAccent: UIColor? {
    get {
      guard let c = UserDefaults.standard.array(forKey: accentKey) as? [Double], c.count == 4
      else { return nil }
      return UIColor(red: c[0], green: c[1], blue: c[2], alpha: c[3])
    }
    set {
      if let newValue {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        newValue.getRed(&r, green: &g, blue: &b, alpha: &a)
        UserDefaults.standard.set([Double(r), Double(g), Double(b), Double(a)], forKey: accentKey)
      } else {
        UserDefaults.standard.removeObject(forKey: accentKey)
      }
      NotificationCenter.default.post(name: changedNotification, object: nil)
    }
  }
}
