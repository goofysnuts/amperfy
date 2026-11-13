//
//  HomeManager.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 29.12.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

import AmperfyKit
import AVFoundation
import CoreData
import OSLog
import UIKit

// MARK: - HomeItem

struct HomeItem: Hashable, @unchecked Sendable {
  /// Stable per section and entity: the diffable data source only sees real changes,
  /// so unchanged covers are not recreated (flicker) when a section is rebuilt.
  /// The section is part of the identity as an entity can show up in several sections.
  let id: String
  var playableContainable: PlayableContainable
  /// Not part of the identity: a changed value only makes the cell reconfigure (no flicker),
  /// e.g. when a playlist cover gets created after the item was first shown.
  let artworkFingerprint: [NSManagedObjectID]
  /// FireSonic: server cover of a playlist (changes when the cover is replaced in Navidrome)
  let serverCoverId: String?

  init(section: HomeSection, playableContainable: PlayableContainable) {
    if let playlist = playableContainable as? Playlist {
      self.artworkFingerprint = playlist.managedObject.artworkItems.map(\.objectID)
      self.serverCoverId = PlaylistCategoryRegistry.coverArtId(ofPlaylistId: playlist.id)
    } else {
      self.artworkFingerprint = []
      self.serverCoverId = nil
    }
    let identifier = playableContainable.containerIdentifier
    self
      .id =
      "\(section)|\(identifier.type.map { "\($0)" } ?? "")|\(identifier.objectID ?? playableContainable.id)"
    self.playableContainable = playableContainable
  }

  static func == (lhs: HomeItem, rhs: HomeItem) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// MARK: - HomeManager

@MainActor
class HomeManager: NSObject {
  public static let sectionMaxItemCount = 20

  public var orderedVisibleSections: [HomeSection]
  public var data: [HomeSection: [HomeItem]] = [:]
  public var applySnapshotCB: VoidFunctionCallback?

  private let account: Account
  private let storage: PersistentStorage
  private let getMeta: (_ accountInfo: AccountInfo) -> MetaManager
  private let eventLogger: EventLogger

  var isOfflineMode: Bool {
    storage.settings.user.isOfflineMode
  }

  private var albumsRecentlyPlayedFetchController: AlbumFetchedResultsController?
  private var albumsNewestFetchController: AlbumFetchedResultsController?
  private var playlistsLastTimePlayedFetchController: PlaylistFetchedResultsController?
  private var podcastEpisodesFetchedController: PodcastEpisodesReleaseDateFetchedResultsController?
  private var podcastsFetchedController: PodcastFetchedResultsController?
  private var radiosFetchedController: RadiosFetchedResultsController?
  // FireSonic
  private var topMixesFetchController: PlaylistFetchedResultsController?
  private var ownMixesFetchController: PlaylistFetchedResultsController?
  private var quickPlaylistsFetchController: PlaylistFetchedResultsController?
  private var quickAlbumsFetchController: AlbumFetchedResultsController?
  public static let quickAccessItemCount = 8

  init(
    account: Account,
    storage: PersistentStorage,
    getMeta: @escaping (_ accountInfo: AccountInfo) -> MetaManager,
    eventLogger: EventLogger
  ) {
    self.account = account
    self.storage = storage
    self.getMeta = getMeta
    self.eventLogger = eventLogger
    self.orderedVisibleSections = storage.settings.accounts
      .getSetting(account.info).read.homeSections
    super.init()
    migrateFireSonicSections()
    migrateBlackboxSections()
    migrateGenresSection()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playlistCategoriesChanged),
      name: PlaylistCategoryRegistry.changedNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(recapsChanged),
      name: RecapRegistry.changedNotification,
      object: nil
    )
  }

  /// Blackbox: "Deine Rückblicke" at the top, "Song des Tages" after the quick access grid
  private func migrateBlackboxSections() {
    let flagKey = "blackbox.homeSectionsMigrated.v2.\(account.info.ident)"
    guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
    UserDefaults.standard.set(true, forKey: flagKey)
    let settings = storage.settings.accounts.getSetting(account.info).read
    var visible = settings.homeSections
    var order = settings.homeSectionOrder.filter { $0 != .recaps && $0 != .songOfTheDay }
    if !visible.contains(.recaps) { visible.insert(.recaps, at: 0) }
    if !visible.contains(.songOfTheDay) {
      let idx = (visible.firstIndex(of: .quickAccess).map { $0 + 1 }) ?? min(1, visible.count)
      visible.insert(.songOfTheDay, at: idx)
    }
    order.insert(.recaps, at: 0)
    let orderIdx = (order.firstIndex(of: .quickAccess).map { $0 + 1 }) ?? min(1, order.count)
    order.insert(.songOfTheDay, at: orderIdx)
    storage.settings.accounts.updateSetting(account.info) { accountSettings in
      accountSettings.homeSections = visible
      accountSettings.homeSectionOrder = order
    }
    orderedVisibleSections = visible
  }

  /// Blackbox: Genres (mit Covern) auf Home einmalig einblenden
  private func migrateGenresSection() {
    let flagKey = "blackbox.homeSectionsMigrated.genres.\(account.info.ident)"
    guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
    UserDefaults.standard.set(true, forKey: flagKey)
    let settings = storage.settings.accounts.getSetting(account.info).read
    guard !settings.homeSections.contains(.randomGenres) else { return }
    var visible = settings.homeSections
    let idx = (visible.firstIndex(of: .randomAlbums).map { $0 + 1 }) ?? visible.count
    visible.insert(.randomGenres, at: idx)
    var order = settings.homeSectionOrder.filter { $0 != .randomGenres }
    order.insert(.randomGenres, at: (order.firstIndex(of: .randomAlbums).map { $0 + 1 }) ?? order.count)
    storage.settings.accounts.updateSetting(account.info) { accountSettings in
      accountSettings.homeSections = visible
      accountSettings.homeSectionOrder = order
    }
    orderedVisibleSections = visible
  }

  /// Reloads the visible sections after they were edited in the settings
  func reloadSectionsFromSettings() {
    orderedVisibleSections = storage.settings.accounts.getSetting(account.info).read.homeSections
    createFetchController()
    updateFromRemote()
    applySnapshotCB?()
  }

  @objc
  private func recapsChanged() {
    updateRecaps()
  }

  /// true while a recap was not opened yet -> large cards at the top
  var hasUnseenRecap: Bool {
    (data[.recaps] ?? []).contains { item in
      guard let playlist = item.playableContainable as? Playlist,
            let recap = RecapRegistry.recaps[playlist.id] else { return false }
      return !RecapRegistry.isSeen(recap)
    }
  }

  func updateRecaps() {
    guard orderedVisibleSections.contains(.recaps) else { return }
    data[.recaps] = RecapRegistry.sortedPlaylistIds.prefix(6).compactMap { entry in
      storage.main.library.getPlaylist(for: account, id: entry.playlistId)
    }.map { HomeItem(section: .recaps, playableContainable: $0) }
    applySnapshotCB?()
  }

  func updateSongOfTheDay(forceNew: Bool = false) {
    guard orderedVisibleSections.contains(.songOfTheDay) else { return }
    let key = "blackbox.songOfTheDay.\(account.info.ident)"
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    var song: Song?
    if !forceNew, let stored = UserDefaults.standard.string(forKey: key) {
      let parts = stored.split(separator: "|", maxSplits: 1).map(String.init)
      if parts.count == 2, parts[0] == today {
        song = storage.main.library.getSong(for: account, id: parts[1])
      }
    }
    if song == nil {
      song = storage.main.library.getRandomSongs(for: account, count: 1, onlyCached: isOfflineMode)
        .first
      if let song {
        UserDefaults.standard.set("\(today)|\(song.id)", forKey: key)
      }
    }
    data[.songOfTheDay] = song.map { [HomeItem(section: .songOfTheDay, playableContainable: $0)] } ?? []
    applySnapshotCB?()
  }

  /// FireSonic: shows the new sections once for settings stored before they existed
  private func migrateFireSonicSections() {
    let flagKey = "firesonic.homeSectionsMigrated.v1.\(account.info.ident)"
    guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
    UserDefaults.standard.set(true, forKey: flagKey)
    let settings = storage.settings.accounts.getSetting(account.info).read
    let missing = HomeSection.fireSonicSections.filter { !settings.homeSections.contains($0) }
    guard !missing.isEmpty else { return }
    let visible = missing + settings.homeSections
    let order = HomeSection.fireSonicSections + settings.homeSectionOrder
      .filter { !HomeSection.fireSonicSections.contains($0) }
    storage.settings.accounts.updateSetting(account.info) { accountSettings in
      accountSettings.homeSections = visible
      accountSettings.homeSectionOrder = order
    }
    orderedVisibleSections = visible
  }

  @objc
  private func playlistCategoriesChanged() {
    createFireSonicFetchControllers()
  }

  private func createMixFetchController(
    category: PlaylistCategory
  ) -> PlaylistFetchedResultsController {
    let controller = PlaylistFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .name,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.sectionMaxItemCount,
      categoryFilter: .only(category)
    )
    controller.delegate = self
    controller.search(searchText: "", playlistSearchCategory: isOfflineMode ? .cached : .all)
    return controller
  }

  private func createFireSonicFetchControllers() {
    if orderedVisibleSections.contains(.topMixes) {
      topMixesFetchController?.delegate = nil
      topMixesFetchController = createMixFetchController(category: .topMix)
      updateTopMixes()
    } else {
      topMixesFetchController?.delegate = nil
      topMixesFetchController = nil
    }
    if orderedVisibleSections.contains(.ownMixes) {
      ownMixesFetchController?.delegate = nil
      ownMixesFetchController = createMixFetchController(category: .ownMix)
      updateOwnMixes()
    } else {
      ownMixesFetchController?.delegate = nil
      ownMixesFetchController = nil
    }
    if orderedVisibleSections.contains(.quickAccess) {
      quickPlaylistsFetchController?.delegate = nil
      quickPlaylistsFetchController = PlaylistFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .lastPlayed,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.quickAccessItemCount
      )
      quickPlaylistsFetchController?.delegate = self
      quickPlaylistsFetchController?.search(
        searchText: "",
        playlistSearchCategory: isOfflineMode ? .cached : .all
      )
      if quickAlbumsFetchController == nil {
        quickAlbumsFetchController = AlbumFetchedResultsController(
          coreDataCompanion: storage.main, account: account,
          sortType: .recent,
          isGroupedInAlphabeticSections: false,
          fetchLimit: Self.quickAccessItemCount
        )
        quickAlbumsFetchController?.delegate = self
      }
      quickAlbumsFetchController?.search(
        searchText: "",
        onlyCached: isOfflineMode,
        displayFilter: .recent
      )
      updateQuickAccess()
    } else {
      quickPlaylistsFetchController?.delegate = nil
      quickPlaylistsFetchController = nil
      quickAlbumsFetchController?.delegate = nil
      quickAlbumsFetchController = nil
    }
  }

  private func playlists(of controller: PlaylistFetchedResultsController?) -> [Playlist] {
    guard let playlists = controller?.fetchedObjects as? [PlaylistMO] else { return [] }
    return playlists.map { Playlist(library: storage.main.library, managedObject: $0) }
  }

  func updateTopMixes() {
    data[.topMixes] = playlists(of: topMixesFetchController).prefix(Self.sectionMaxItemCount)
      .map { HomeItem(section: .topMixes, playableContainable: $0) }
    applySnapshotCB?()
  }

  func updateOwnMixes() {
    data[.ownMixes] = playlists(of: ownMixesFetchController).prefix(Self.sectionMaxItemCount)
      .map { HomeItem(section: .ownMixes, playableContainable: $0) }
    applySnapshotCB?()
  }

  /// Spotify-like grid at the top: last played playlists and mixes, filled up with recently
  /// played albums. Always an even number of tiles (two columns).
  func updateQuickAccess() {
    var containers: [PlayableContainable] = playlists(of: quickPlaylistsFetchController)
      .filter { $0.lastTimePlayed != nil }
    if containers.count < Self.quickAccessItemCount {
      // mixes are refreshed regularly by the plugins -> good candidates even if never played
      let mixIds = Set(containers.map(\.id))
      let mixes = (playlists(of: topMixesFetchController) + playlists(of: ownMixesFetchController))
        .filter { !mixIds.contains($0.id) }
      containers += mixes.prefix(max(0, Self.quickAccessItemCount / 2 - containers.count))
        .map { $0 as PlayableContainable }
    }
    if containers.count < Self.quickAccessItemCount,
       let albums = quickAlbumsFetchController?.fetchedObjects as? [AlbumMO] {
      containers += albums.prefix(Self.quickAccessItemCount - containers.count)
        .map { Album(managedObject: $0) as PlayableContainable }
    }
    var items = containers.prefix(Self.quickAccessItemCount)
      .map { HomeItem(section: .quickAccess, playableContainable: $0) }
    if items.count % 2 == 1, items.count > 1 { items.removeLast() }
    data[.quickAccess] = items
    applySnapshotCB?()
  }

  func createFetchController() {
    createFireSonicFetchControllers()
    updateRecaps()
    updateSongOfTheDay()
    if orderedVisibleSections.contains(where: { $0 == .recentlyPlayedAlbums }) {
      albumsRecentlyPlayedFetchController = AlbumFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .recent,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount
      )
      albumsRecentlyPlayedFetchController?.delegate = self
      albumsRecentlyPlayedFetchController?.search(
        searchText: "",
        onlyCached: isOfflineMode,
        displayFilter: .recent
      )
      updateAlbumsRecentlyPlayed()
    } else {
      albumsRecentlyPlayedFetchController?.delegate = nil
      albumsRecentlyPlayedFetchController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .newestAlbums }) {
      albumsNewestFetchController = AlbumFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .newest,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount
      )
      albumsNewestFetchController?.delegate = self
      albumsNewestFetchController?.search(
        searchText: "",
        onlyCached: isOfflineMode,
        displayFilter: .newest
      )
      updateAlbumsNewest()
    } else {
      albumsNewestFetchController?.delegate = nil
      albumsNewestFetchController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .randomAlbums }) {
      Task { @MainActor in
        await updateRandomAlbums(isOfflineMode: isOfflineMode)
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .randomArtists }) {
      Task { @MainActor in
        await updateRandomArtists(isOfflineMode: isOfflineMode)
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .randomGenres }) {
      Task { @MainActor in
        await updateRandomGenres()
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .randomSongs }) {
      Task { @MainActor in
        await updateRandomSongs(isOfflineMode: isOfflineMode)
      }
    }

    if orderedVisibleSections.contains(where: { $0 == .lastTimePlayedPlaylists }) {
      playlistsLastTimePlayedFetchController = PlaylistFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .lastPlayed,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount
      )
      playlistsLastTimePlayedFetchController?.delegate = self
      playlistsLastTimePlayedFetchController?.search(
        searchText: "",
        playlistSearchCategory: isOfflineMode ? .cached : .all
      )
      updatePlaylistsLastTimePlayed()
    } else {
      playlistsLastTimePlayedFetchController?.delegate = nil
      playlistsLastTimePlayedFetchController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .newestPodcastEpisodes }) {
      podcastEpisodesFetchedController = PodcastEpisodesReleaseDateFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.sectionMaxItemCount
      )
      podcastEpisodesFetchedController?.delegate = self
      podcastEpisodesFetchedController?.search(searchText: "", onlyCachedSongs: isOfflineMode)
      updatePodcastEpisodesNewest()
    } else {
      podcastEpisodesFetchedController?.delegate = nil
      podcastEpisodesFetchedController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .podcasts }) {
      podcastsFetchedController = PodcastFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        isGroupedInAlphabeticSections: false
      )
      podcastsFetchedController?.delegate = self
      podcastsFetchedController?.search(searchText: "", onlyCached: isOfflineMode)
      updatePodcasts()
    } else {
      podcastsFetchedController?.delegate = nil
      podcastsFetchedController = nil
    }

    if orderedVisibleSections.contains(where: { $0 == .radios }) {
      radiosFetchedController = RadiosFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        isGroupedInAlphabeticSections: true
      )
      radiosFetchedController?.delegate = self
      radiosFetchedController?.fetch()
      updateRadios()
    } else {
      radiosFetchedController?.delegate = nil
      radiosFetchedController = nil
    }
  }

  func updateFromRemote() {
    guard storage.settings.user.isOnlineMode else { return }
    if orderedVisibleSections.contains(where: { $0 == .newestAlbums }) {
      Task { @MainActor in
        do {
          try await AutoDownloadLibrarySyncer(
            storage: self.storage,
            account: self.account,
            librarySyncer: self.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.getMeta(self.account.info)
              .playableDownloadManager
          )
          .syncNewestLibraryElements(offset: 0, count: Self.sectionMaxItemCount)
        } catch {
          self.eventLogger.report(topic: "Newest Albums Sync", error: error)
        }
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .recentlyPlayedAlbums }) {
      Task { @MainActor in
        do {
          try await self.getMeta(self.account.info).librarySyncer
            .syncRecentAlbums(
              offset: 0,
              count: Self.sectionMaxItemCount
            )
        } catch {
          self.eventLogger.report(topic: "Recent Albums Sync", error: error)
        }
      }
    }
    if orderedVisibleSections.contains(where: { $0 == .frequentAlbums }) {
      Task { @MainActor in
        await self.updateFrequentAlbums()
      }
    }
    if orderedVisibleSections.contains(where: {
      $0 == .lastTimePlayedPlaylists || $0 == .quickAccess || $0 == .topMixes || $0 == .ownMixes ||
        $0 == .recaps
    }) {
      Task { @MainActor in do {
        try await self.getMeta(self.account.info).librarySyncer
          .syncDownPlaylistsWithoutSongs()
      } catch {
        self.eventLogger.report(topic: "Playlists Sync", error: error)
      }}
    }
    if orderedVisibleSections.contains(where: { $0 == .newestPodcastEpisodes }) {
      Task { @MainActor in do {
        let _ = try await AutoDownloadLibrarySyncer(
          storage: self.storage,
          account: self.account,
          librarySyncer: self.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.getMeta(self.account.info)
            .playableDownloadManager
        )
        .syncNewestPodcastEpisodes()
      } catch {
        self.eventLogger.report(topic: "Podcasts Sync", error: error)
      }}
    }
    if orderedVisibleSections.contains(where: { $0 == .radios }) {
      Task { @MainActor in
        do {
          try await self.getMeta(self.account.info).librarySyncer
            .syncRadios()
        } catch {
          self.eventLogger.report(topic: "Radios Sync", error: error)
        }
      }
    }
  }

  func updateAlbumsRecentlyPlayed() {
    if let albums = albumsRecentlyPlayedFetchController?.fetchedObjects as? [AlbumMO] {
      data[.recentlyPlayedAlbums] = albums.prefix(Self.sectionMaxItemCount)
        .compactMap { Album(managedObject: $0) }.compactMap {
          HomeItem(section: .recentlyPlayedAlbums, playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updateAlbumsNewest() {
    if let albums = albumsNewestFetchController?.fetchedObjects as? [AlbumMO] {
      data[.newestAlbums] = albums.prefix(Self.sectionMaxItemCount)
        .compactMap { Album(managedObject: $0) }.compactMap {
          HomeItem(section: .newestAlbums, playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updateFrequentAlbums() async {
    do {
      let albumIds = try await getMeta(account.info).librarySyncer
        .syncFrequentAlbums(offset: 0, count: Self.sectionMaxItemCount)
      let albums = albumIds.compactMap {
        storage.main.library.getAlbum(for: account, id: $0, isDetailFaultResolution: false)
      }
      data[.frequentAlbums] = albums.compactMap {
        HomeItem(section: .frequentAlbums, playableContainable: $0)
      }
      applySnapshotCB?()
    } catch {
      eventLogger.report(topic: "Frequent Albums Sync", error: error)
    }
  }

  func updateRandomAlbums(isOfflineMode: Bool) async {
    let randomAlbums = storage.main.library.getRandomAlbums(
      for: account,
      count: Self.sectionMaxItemCount,
      onlyCached: isOfflineMode
    )
    data[.randomAlbums] = randomAlbums.compactMap {
      HomeItem(section: .randomAlbums, playableContainable: $0)
    }
    applySnapshotCB?()
  }

  func updateRandomArtists(isOfflineMode: Bool) async {
    let randomArtists = storage.main.library.getRandomArtists(
      for: account,
      count: Self.sectionMaxItemCount,
      onlyCached: isOfflineMode
    )
    data[.randomArtists] = randomArtists.compactMap {
      HomeItem(section: .randomArtists, playableContainable: $0)
    }
    applySnapshotCB?()
  }

  func updateRandomGenres() async {
    let randomGenres = storage.main.library.getRandomGenres(
      for: account,
      count: Self.sectionMaxItemCount
    )
    data[.randomGenres] = randomGenres.compactMap {
      HomeItem(section: .randomGenres, playableContainable: $0)
    }
    applySnapshotCB?()
  }

  func updateRandomSongs(isOfflineMode: Bool) async {
    let randomSongs = storage.main.library.getRandomSongs(
      for: account,
      count: Self.sectionMaxItemCount,
      onlyCached: isOfflineMode
    )
    data[.randomSongs] = randomSongs.compactMap {
      HomeItem(section: .randomSongs, playableContainable: $0)
    }
    applySnapshotCB?()
  }

  func updatePlaylistsLastTimePlayed() {
    if let playlists = playlistsLastTimePlayedFetchController?.fetchedObjects as? [PlaylistMO] {
      data[.lastTimePlayedPlaylists] = playlists.prefix(Self.sectionMaxItemCount)
        .compactMap { Playlist(
          library: storage.main.library,
          managedObject: $0
        ) }.compactMap {
          HomeItem(section: .lastTimePlayedPlaylists, playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updatePodcastEpisodesNewest() {
    if let podcastEpisodes = podcastEpisodesFetchedController?
      .fetchedObjects as? [PodcastEpisodeMO] {
      data[.newestPodcastEpisodes] = podcastEpisodes.prefix(Self.sectionMaxItemCount)
        .compactMap { PodcastEpisode(managedObject: $0) }.compactMap {
          HomeItem(section: .newestPodcastEpisodes, playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updatePodcasts() {
    if let podcasts = podcastsFetchedController?.fetchedObjects as? [PodcastMO] {
      data[.podcasts] = podcasts.prefix(Self.sectionMaxItemCount)
        .compactMap { Podcast(managedObject: $0) }.compactMap {
          HomeItem(section: .podcasts, playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }

  func updateRadios() {
    if let radios = radiosFetchedController?.fetchedObjects as? [RadioMO] {
      data[.radios] = radios.prefix(Self.sectionMaxItemCount)
        .compactMap { Radio(managedObject: $0) }.compactMap {
          HomeItem(section: .radios, playableContainable: $0)
        }
      applySnapshotCB?()
    }
  }
}

extension HomeManager: @preconcurrency NSFetchedResultsControllerDelegate {
  func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
    // fetch controller is created on Main thread -> Runtime Error if this function call is not on Main thread
    MainActor.assumeIsolated {
      if controller == albumsRecentlyPlayedFetchController?.fetchResultsController {
        updateAlbumsRecentlyPlayed()
      } else if controller == albumsNewestFetchController?.fetchResultsController {
        updateAlbumsNewest()
      } else if controller == playlistsLastTimePlayedFetchController?.fetchResultsController {
        updatePlaylistsLastTimePlayed()
      } else if controller == podcastEpisodesFetchedController?.fetchResultsController {
        updatePodcastEpisodesNewest()
      } else if controller == podcastsFetchedController?.fetchResultsController {
        updatePodcasts()
      } else if controller == radiosFetchedController?.fetchResultsController {
        updateRadios()
      } else if controller == topMixesFetchController?.fetchResultsController {
        updateTopMixes()
        updateQuickAccess()
      } else if controller == ownMixesFetchController?.fetchResultsController {
        updateOwnMixes()
        updateQuickAccess()
      } else if controller == quickPlaylistsFetchController?.fetchResultsController ||
        controller == quickAlbumsFetchController?.fetchResultsController {
        updateQuickAccess()
      }
    }
  }
}

// MARK: - RecapStoriesVC

/// Blackbox: Spotify-Wrapped-like story viewer for the data of the Rückblick plugin.
/// Tap right/left to go forward/back, hold to pause. The top song plays in the background.
final class RecapStoriesVC: UIViewController {
  private let recap: RecapData
  private let playlist: Playlist
  private let account: Account

  private let gradient = CAGradientLayer()
  private let progressStack = UIStackView()
  private var progressBars: [UIProgressView] = []
  private let content = UIView()
  private let closeButton = UIButton(type: .system)

  private var slides: [Slide] = []
  private var index = 0
  private var elapsed: TimeInterval = 0
  private var lastTick: CFTimeInterval?
  private var displayLink: CADisplayLink?
  private var isPaused = false
  private static let slideDuration: TimeInterval = 7

  private var musicPlayer: AVPlayer?
  private var mainPlayerWasPlaying = false

  private struct Slide {
    let colors: [UIColor]
    let autoAdvance: Bool
    let build: (RecapStoriesVC) -> UIView
  }

  init(recap: RecapData, playlist: Playlist, account: Account) {
    self.recap = recap
    self.playlist = playlist
    self.account = account
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var prefersStatusBarHidden: Bool { true }
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  private var appDelegateRef: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    overrideUserInterfaceStyle = .dark
    gradient.startPoint = CGPoint(x: 0, y: 0)
    gradient.endPoint = CGPoint(x: 1, y: 1)
    view.layer.addSublayer(gradient)

    slides = buildSlides()

    content.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content)

    progressStack.axis = .horizontal
    progressStack.spacing = 4
    progressStack.distribution = .fillEqually
    progressStack.translatesAutoresizingMaskIntoConstraints = false
    for _ in slides {
      let bar = UIProgressView(progressViewStyle: .bar)
      bar.trackTintColor = UIColor.white.withAlphaComponent(0.3)
      bar.progressTintColor = .white
      bar.layer.cornerRadius = 1.5
      bar.clipsToBounds = true
      progressBars.append(bar)
      progressStack.addArrangedSubview(bar)
    }
    view.addSubview(progressStack)

    var closeConfig = UIButton.Configuration.plain()
    closeConfig.image = UIImage(
      systemName: "xmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    )
    closeConfig.baseForegroundColor = .white
    closeButton.configuration = closeConfig
    closeButton.accessibilityLabel = "Schließen"
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
    view.addSubview(closeButton)

    NSLayoutConstraint.activate([
      progressStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
      progressStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      progressStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      progressStack.heightAnchor.constraint(equalToConstant: 3),
      closeButton.topAnchor.constraint(equalTo: progressStack.bottomAnchor, constant: 6),
      closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
      closeButton.widthAnchor.constraint(equalToConstant: 44),
      closeButton.heightAnchor.constraint(equalToConstant: 44),
      content.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 4),
      content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
    ])

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    view.addGestureRecognizer(tap)
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
    hold.minimumPressDuration = 0.25
    view.addGestureRecognizer(hold)
    let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
    swipeDown.direction = .down
    view.addGestureRecognizer(swipeDown)

    show(index: 0, animated: false)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    gradient.frame = view.bounds
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    RecapRegistry.markSeen(recap)
    startMusic()
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    displayLink?.invalidate()
    displayLink = nil
    stopMusic(resumeMainPlayer: true)
  }

  // MARK: Navigation

  private func close() {
    dismiss(animated: true)
  }

  @objc
  private func swipedDown() { close() }

  @objc
  private func handleTap(_ gesture: UITapGestureRecognizer) {
    let x = gesture.location(in: view).x
    if x < view.bounds.width * 0.3 {
      show(index: max(0, index - 1), animated: true)
    } else if index < slides.count - 1 {
      show(index: index + 1, animated: true)
    }
  }

  @objc
  private func handleHold(_ gesture: UILongPressGestureRecognizer) {
    switch gesture.state {
    case .began:
      isPaused = true
      musicPlayer?.pause()
    case .ended, .cancelled, .failed:
      isPaused = false
      lastTick = nil
      musicPlayer?.play()
    default: break
    }
  }

  @objc
  private func tick(_ link: CADisplayLink) {
    defer { lastTick = link.timestamp }
    guard !isPaused, let last = lastTick, slides.indices.contains(index) else { return }
    guard slides[index].autoAdvance else { return }
    elapsed += link.timestamp - last
    progressBars[index].progress = Float(min(1, elapsed / Self.slideDuration))
    if elapsed >= Self.slideDuration, index < slides.count - 1 {
      show(index: index + 1, animated: true)
    }
  }

  private func show(index newIndex: Int, animated: Bool) {
    index = newIndex
    elapsed = 0
    for (i, bar) in progressBars.enumerated() {
      bar.progress = i < index ? 1 : (i == index && !slides[i].autoAdvance ? 1 : 0)
    }
    let slide = slides[index]
    let newView = slide.build(self)
    newView.translatesAutoresizingMaskIntoConstraints = false
    let old = content.subviews
    newView.alpha = animated ? 0 : 1
    newView.transform = animated ? CGAffineTransform(translationX: 0, y: 24) : .identity
    content.addSubview(newView)
    NSLayoutConstraint.activate([
      newView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      newView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      newView.topAnchor.constraint(equalTo: content.topAnchor),
      newView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    let colors = slide.colors.map(\.cgColor)
    if animated {
      let anim = CABasicAnimation(keyPath: "colors")
      anim.fromValue = gradient.colors
      anim.toValue = colors
      anim.duration = 0.6
      gradient.add(anim, forKey: "colors")
    }
    gradient.colors = colors
    UIView.animate(withDuration: animated ? 0.45 : 0, delay: 0, options: [.curveEaseOut]) {
      newView.alpha = 1
      newView.transform = .identity
      old.forEach { $0.alpha = 0 }
    } completion: { _ in
      old.forEach { $0.removeFromSuperview() }
    }
    UIAccessibility.post(notification: .screenChanged, argument: newView)
  }

  // MARK: Music

  private func startMusic() {
    let player = appDelegateRef.player
    mainPlayerWasPlaying = player.isPlaying
    if mainPlayerWasPlaying { player.pause() }
    guard let songId = recap.topSongs.first?.songId else { return }
    let api = appDelegateRef.getMeta(account.info).backendApi
    Task { @MainActor [weak self] in
      guard let url = try? await api.generateUrl(forSongId: songId), let self,
            self.view.window != nil else { return }
      let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": api.httpHeaders])
      let item = AVPlayerItem(asset: asset)
      let music = AVPlayer(playerItem: item)
      music.volume = 0
      self.musicPlayer = music
      _ = await music.seek(to: CMTime(seconds: 30, preferredTimescale: 600))
      guard self.musicPlayer === music else { return }
      music.play()
      // fade in
      for step in 1 ... 20 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard self.musicPlayer === music else { return }
        music.volume = Float(step) / 20 * 0.8
      }
    }
  }

  private func stopMusic(resumeMainPlayer: Bool) {
    musicPlayer?.pause()
    musicPlayer = nil
    if resumeMainPlayer, mainPlayerWasPlaying {
      appDelegateRef.player.play()
    }
    mainPlayerWasPlaying = false
  }

  private func playPlaylist() {
    stopMusic(resumeMainPlayer: false)
    appDelegateRef.player.play(context: PlayContext(containable: playlist))
    dismiss(animated: true)
  }

  // MARK: Slides

  private static let palettes: [[UIColor]] = [
    [UIColor(red: 0.36, green: 0.09, blue: 0.55, alpha: 1), UIColor(red: 0.93, green: 0.28, blue: 0.6, alpha: 1)],
    [UIColor(red: 0.05, green: 0.2, blue: 0.45, alpha: 1), UIColor(red: 0.1, green: 0.75, blue: 0.7, alpha: 1)],
    [UIColor(red: 0.6, green: 0.1, blue: 0.2, alpha: 1), UIColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1)],
    [UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1), UIColor(red: 0.3, green: 0.12, blue: 0.5, alpha: 1)],
    [UIColor(red: 0.1, green: 0.4, blue: 0.2, alpha: 1), UIColor(red: 0.85, green: 0.9, blue: 0.2, alpha: 1)],
    [UIColor(red: 0.85, green: 0.25, blue: 0.45, alpha: 1), UIColor(red: 0.98, green: 0.8, blue: 0.2, alpha: 1)],
  ]

  private func buildSlides() -> [Slide] {
    var out: [Slide] = []
    var palette = 0
    func add(_ autoAdvance: Bool = true, _ build: @escaping (RecapStoriesVC) -> UIView) {
      out.append(Slide(colors: Self.palettes[palette % Self.palettes.count], autoAdvance: autoAdvance, build: build))
      palette += 1
    }
    let r = recap
    add { vc in
      vc.textSlide(
        eyebrow: "BLACKBOX RÜCKBLICK",
        big: r.label,
        text: r.isYear ? "Dein Jahr in Musik. Tippe dich durch." : "Dein Monat in Musik. Tippe dich durch.",
        bigSize: 52
      )
    }
    add { vc in
      var lines = ["\(r.plays.formatted()) Wiedergaben"]
      if let ds = r.ds { lines.append("\(ds.formatted()) verschiedene Songs") }
      if let pm = r.pm, pm > 0, let plb = r.plb {
        let diff = Int((Double(r.minutes - pm) / Double(pm) * 100).rounded())
        lines.append(diff >= 0 ? "\(diff) % mehr als im \(plb)" : "\(-diff) % weniger als im \(plb)")
      }
      return vc.textSlide(
        eyebrow: "DU HAST",
        big: r.minutes.formatted(),
        text: "Minuten Musik gehört.\n\n" + lines.joined(separator: "\n"),
        bigSize: 76
      )
    }
    if let top = r.topSongs.first {
      add { vc in
        vc.heroSlide(
          eyebrow: "DEIN SONG NR. 1",
          coverArtId: top.coverArtId,
          title: top.name,
          subtitle: top.sub ?? "",
          footnote: "\(top.plays)× gehört"
        )
      }
    }
    if !r.topArtists.isEmpty {
      add { vc in vc.listSlide(title: "Deine Top-Interpreten", items: r.topArtists, round: true) }
    }
    if r.topSongs.count > 1 {
      add { vc in vc.listSlide(title: "Deine Top-Songs", items: r.topSongs, round: false) }
    }
    if !r.topAlbums.isEmpty {
      add { vc in vc.listSlide(title: "Deine Top-Alben", items: r.topAlbums, round: false) }
    }
    if !r.topGenres.isEmpty {
      add { vc in vc.genreSlide(r.topGenres) }
    }
    if let tyn = r.tyn {
      add { vc in
        var detail = r.tyd ?? ""
        if let dp = r.dp, let bw = r.bw {
          detail += "\n\nAm liebsten hörst du \(dp) – und am meisten \(bw)s."
        }
        return vc.textSlide(eyebrow: "DU BIST", big: tyn, text: detail, bigSize: 48)
      }
    }
    var moments: [String] = []
    if let st = r.st, st > 1 { moments.append("🔥 \(st) Tage am Stück Musik") }
    if let td = r.td, let tdm = r.tdm, tdm > 0 { moments.append("📅 \(Self.formatDay(td)): \(tdm) Minuten") }
    if let bm = r.bm, r.isYear { moments.append("🗓 Aktivster Monat: \(bm)") }
    if let na = r.na, na > 0 { moments.append("✨ \(na) neue Interpreten entdeckt") }
    if let fs = r.fs { moments.append("▶︎ Erster Song: \(fs.name)") }
    if !moments.isEmpty {
      add { vc in vc.textSlide(eyebrow: "DEINE MOMENTE", big: "Highlights", text: moments.joined(separator: "\n\n"), bigSize: 44) }
    }
    add(false) { vc in vc.summarySlide() }
    return out
  }

  private static func formatDay(_ iso: String) -> String {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: iso) else { return iso }
    let out = DateFormatter()
    out.locale = Locale(identifier: "de_DE")
    out.dateFormat = "d. MMMM"
    return out.string(from: date)
  }

  private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat = 1, lines: Int = 0) -> UILabel {
    let l = UILabel()
    l.text = text
    l.textColor = UIColor.white.withAlphaComponent(alpha)
    l.font = UIFontMetrics.default.scaledFont(for: .systemFont(ofSize: size, weight: weight), maximumPointSize: size * 1.4)
    l.adjustsFontForContentSizeCategory = true
    l.numberOfLines = lines
    l.adjustsFontSizeToFitWidth = true
    l.minimumScaleFactor = 0.5
    return l
  }

  private func centeredStack(_ views: [UIView], spacing: CGFloat = 12) -> UIView {
    let container = UIView()
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = .vertical
    stack.spacing = spacing
    stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
    ])
    return container
  }

  private func textSlide(eyebrow: String, big: String, text: String, bigSize: CGFloat) -> UIView {
    centeredStack([
      label(eyebrow, size: 15, weight: .bold, alpha: 0.8, lines: 1),
      label(big, size: bigSize, weight: .black, lines: 3),
      label(text, size: 20, weight: .semibold, alpha: 0.9),
    ], spacing: 14)
  }

  private func coverView(coverArtId: String?, round: Bool, size: CGFloat?) -> UIImageView {
    let iv = UIImageView()
    iv.contentMode = .scaleAspectFill
    iv.clipsToBounds = true
    iv.backgroundColor = UIColor.white.withAlphaComponent(0.15)
    iv.layer.cornerRadius = round ? (size ?? 0) / 2 : 10
    iv.layer.cornerCurve = .continuous
    iv.translatesAutoresizingMaskIntoConstraints = false
    if let size {
      iv.widthAnchor.constraint(equalToConstant: size).isActive = true
      iv.heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    if let coverArtId {
      let info = account.info
      Task { @MainActor [weak iv] in
        let image = await PlaylistCoverLoader.shared.image(coverArtId: coverArtId, accountInfo: info)
        guard let iv, let image else { return }
        UIView.transition(with: iv, duration: 0.3, options: .transitionCrossDissolve) { iv.image = image }
      }
    }
    return iv
  }

  private func heroSlide(eyebrow: String, coverArtId: String?, title: String, subtitle: String, footnote: String) -> UIView {
    let cover = coverView(coverArtId: coverArtId, round: false, size: nil)
    cover.layer.cornerRadius = 16
    cover.heightAnchor.constraint(equalTo: cover.widthAnchor).isActive = true
    cover.layer.shadowColor = UIColor.black.cgColor
    let stack = centeredStack([
      label(eyebrow, size: 15, weight: .bold, alpha: 0.8, lines: 1),
      cover,
      label(title, size: 32, weight: .heavy, lines: 2),
      label(subtitle, size: 20, weight: .semibold, alpha: 0.85, lines: 1),
      label(footnote, size: 17, weight: .medium, alpha: 0.75, lines: 1),
    ], spacing: 12)
    cover.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
    let w = cover.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.85)
    w.priority = .defaultHigh
    w.isActive = true
    cover.heightAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
    return stack
  }

  private func listSlide(title: String, items: [RecapData.Item], round: Bool) -> UIView {
    var rows: [UIView] = [label(title, size: 34, weight: .black, lines: 2)]
    for (i, item) in items.prefix(5).enumerated() {
      let number = label("\(i + 1)", size: 26, weight: .black, lines: 1)
      number.widthAnchor.constraint(equalToConstant: 30).isActive = true
      let cover = coverView(coverArtId: item.coverArtId, round: round, size: i == 0 ? 72 : 56)
      let name = label(item.name, size: i == 0 ? 21 : 18, weight: .bold, lines: 1)
      var subText = "\(item.plays)× gehört"
      if let sub = item.sub, !sub.isEmpty { subText = "\(sub) · " + subText }
      let sub = label(subText, size: 14, weight: .medium, alpha: 0.75, lines: 1)
      let texts = UIStackView(arrangedSubviews: [name, sub])
      texts.axis = .vertical
      texts.spacing = 2
      let row = UIStackView(arrangedSubviews: [number, cover, texts])
      row.axis = .horizontal
      row.alignment = .center
      row.spacing = 12
      rows.append(row)
    }
    return centeredStack(rows, spacing: 16)
  }

  private func genreSlide(_ genres: [RecapData.Item]) -> UIView {
    var rows: [UIView] = [label("Deine Genres", size: 34, weight: .black, lines: 1)]
    for g in genres.prefix(5) {
      let name = label("\(g.name)  \(g.plays) %", size: 19, weight: .bold, lines: 1)
      let track = UIView()
      track.backgroundColor = UIColor.white.withAlphaComponent(0.2)
      track.layer.cornerRadius = 7
      track.translatesAutoresizingMaskIntoConstraints = false
      let fill = UIView()
      fill.backgroundColor = .white
      fill.layer.cornerRadius = 7
      fill.translatesAutoresizingMaskIntoConstraints = false
      track.addSubview(fill)
      NSLayoutConstraint.activate([
        track.heightAnchor.constraint(equalToConstant: 14),
        fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
        fill.topAnchor.constraint(equalTo: track.topAnchor),
        fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        fill.widthAnchor.constraint(
          equalTo: track.widthAnchor,
          multiplier: CGFloat(max(4, min(100, g.plays))) / 100
        ),
      ])
      let block = UIStackView(arrangedSubviews: [name, track])
      block.axis = .vertical
      block.spacing = 6
      rows.append(block)
      track.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
    }
    let stack = centeredStack(rows, spacing: 18)
    rows.dropFirst().forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return stack
  }

  private func summarySlide() -> UIView {
    let r = recap
    func tile(_ caption: String, _ value: String) -> UIView {
      let v = UIStackView(arrangedSubviews: [
        label(caption, size: 13, weight: .bold, alpha: 0.7, lines: 1),
        label(value, size: 19, weight: .heavy, lines: 2),
      ])
      v.axis = .vertical
      v.spacing = 4
      return v
    }
    let grid1 = UIStackView(arrangedSubviews: [
      tile("TOP-INTERPRET", r.topArtists.first?.name ?? "–"),
      tile("TOP-SONG", r.topSongs.first?.name ?? "–"),
    ])
    let grid2 = UIStackView(arrangedSubviews: [
      tile("MINUTEN", r.minutes.formatted()),
      tile("TOP-GENRE", r.topGenres.first?.name ?? "–"),
    ])
    [grid1, grid2].forEach {
      $0.axis = .horizontal
      $0.distribution = .fillEqually
      $0.spacing = 16
    }
    let cover = coverView(coverArtId: r.topSongs.first?.coverArtId, round: false, size: 120)

    var playConfig = UIButton.Configuration.filled()
    playConfig.title = "Playlist abspielen"
    playConfig.image = UIImage(systemName: "play.fill")
    playConfig.imagePadding = 8
    playConfig.baseBackgroundColor = .white
    playConfig.baseForegroundColor = .black
    playConfig.cornerStyle = .capsule
    playConfig.buttonSize = .large
    let play = UIButton(configuration: playConfig)
    play.addAction(UIAction { [weak self] _ in self?.playPlaylist() }, for: .touchUpInside)

    var doneConfig = UIButton.Configuration.plain()
    doneConfig.title = "Fertig"
    doneConfig.baseForegroundColor = .white
    let done = UIButton(configuration: doneConfig)
    done.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)

    let stack = centeredStack([
      label("RÜCKBLICK \(r.label.uppercased())", size: 15, weight: .bold, alpha: 0.8, lines: 1),
      cover, grid1, grid2, play, done,
    ], spacing: 18)
    [grid1, grid2, play].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return stack
  }
}
