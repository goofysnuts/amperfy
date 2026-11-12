//
//  SearchVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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
import CoreData
import Combine
import SwiftUI
import UIKit

// MARK: - SearchSection

public enum SearchSection: Int, CaseIterable {
  case History
  case Artist
  case Album
  case Playlist
  case Song
}

// MARK: - SearchDiffableDataSource

class SearchDiffableDataSource: BasicUITableViewDiffableDataSource {
  public var searchVC: SearchVC!

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch SearchSection(rawValue: section) {
    case .History:
      if searchVC.searchHistory.isEmpty {
        return ""
      } else {
        return "Zuletzt gesucht"
      }
    case .Playlist:
      return "Playlists"
    case .Artist:
      return "Interpreten"
    case .Album:
      return "Alben"
    case .Song:
      return "Songs"
    case .none:
      return ""
    }
  }
}

// MARK: - SearchVC

class SearchVC: BasicTableViewController {
  override var sceneTitle: String { "Search" }

  nonisolated private static let categoryItemLimit = 20

  private var diffableDataSource: SearchDiffableDataSource?
  private let searchTaskRunner = SearchTaskRunner()
  fileprivate var searchHistory: [SearchHistoryItem] = []
  fileprivate var artists: [Artist] = []
  fileprivate var albums: [Album] = []
  fileprivate var playlists: [Playlist] = []
  fileprivate var songs: [Song] = []

  private var userButton: UIButton?
  private var userBarButtonItem: UIBarButtonItem?
  private var isSearchActive = false {
    didSet { if oldValue != isSearchActive { refreshCategoryBar() } }
  }

  // MARK: Blackbox: search categories (Top-Treffer, Interpreten, Alben, Songs, Playlists)

  enum SearchCategory: Int, CaseIterable {
    case top, artists, albums, songs, playlists

    var title: String {
      switch self {
      case .top: return "Top-Treffer"
      case .artists: return "Interpreten"
      case .albums: return "Alben"
      case .songs: return "Songs"
      case .playlists: return "Playlists"
      }
    }

    var section: SearchSection? {
      switch self {
      case .top: return nil
      case .artists: return .Artist
      case .albums: return .Album
      case .songs: return .Song
      case .playlists: return .Playlist
      }
    }
  }

  static let topHitsLimit = 4

  // MARK: Blackbox Request: fehlende Alben direkt in der Suche anfragen

  private let requestModel = BBRSearchModel()
  private var requestHost: UIHostingController<BlackboxRequestInlineView>?
  private var requestCancellable: AnyCancellable?

  private func setupRequestFooter() {
    let host = UIHostingController(rootView: BlackboxRequestInlineView(
      model: requestModel,
      onOpenAll: { [weak self] q in self?.openRequestSearch(q) },
      onOpenAlbum: { [weak self] id in self?.openRequestAlbum(id) }
    ))
    host.view.backgroundColor = .clear
    addChild(host)
    host.didMove(toParent: self)
    requestHost = host
    requestCancellable = requestModel.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        DispatchQueue.main.async { self?.layoutRequestFooter() }
      }
  }

  private func updateRequestSearch(_ text: String) {
    guard BlackboxRequestConfig.isConfigured else {
      requestModel.search("")
      layoutRequestFooter()
      return
    }
    requestModel.search(isSearchActive || !text.isEmpty ? text : "")
    layoutRequestFooter()
  }

  private func layoutRequestFooter() {
    guard isViewLoaded, let host = requestHost else { return }
    let show = BlackboxRequestConfig.isConfigured && requestModel.query.count >= 2
    if !show {
      if tableView.tableFooterView != nil { tableView.tableFooterView = nil }
      return
    }
    let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
    let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    let height = ceil(size.height)
    if tableView.tableFooterView !== host.view || abs(host.view.frame.height - height) > 0.5
      || abs(host.view.frame.width - width) > 0.5 {
      host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
      tableView.tableFooterView = host.view
    }
    if isSearchActive, artists.isEmpty, albums.isEmpty, playlists.isEmpty, songs.isEmpty {
      contentUnavailableConfiguration = nil
    }
  }

  private func openRequestSearch(_ query: String) {
    let vc = UIHostingController(rootView: BlackboxRequestSearchView(initialQuery: query))
    present(vc, animated: true)
  }

  private func openRequestAlbum(_ id: String) {
    let model = requestModel
    let vc = UIHostingController(rootView: BBRAlbumSheet(albumId: id, onChange: { model.refresh() }))
    if let sheet = vc.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(vc, animated: true)
  }
  private var category: SearchCategory = .top
  private var categoryButtons: [UIButton] = []
  private lazy var categoryBar: UIView = {
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 52))
    scroll.showsHorizontalScrollIndicator = false
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
      stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -16),
    ])
    for cat in SearchCategory.allCases {
      let button = UIButton(type: .system)
      button.addAction(UIAction { [weak self] _ in self?.select(category: cat) }, for: .touchUpInside)
      categoryButtons.append(button)
      stack.addArrangedSubview(button)
    }
    return scroll
  }()

  private func styleCategoryButtons() {
    for (i, button) in categoryButtons.enumerated() {
      let selected = i == category.rawValue
      var config = selected ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
      config.title = SearchCategory(rawValue: i)?.title
      config.cornerStyle = .capsule
      config.baseForegroundColor = selected ? .white : .secondaryLabel
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
        var a = attrs
        a.font = UIFont.preferredFont(forTextStyle: .headline)
        return a
      }
      button.configuration = config
      button.accessibilityTraits = selected ? [.button, .selected] : .button
    }
  }

  private func refreshCategoryBar() {
    guard isViewLoaded else { return }
    if isSearchActive {
      styleCategoryButtons()
      categoryBar.frame.size.height = 52
      tableView.tableHeaderView = categoryBar
    } else {
      tableView.tableHeaderView = nil
    }
  }

  private func select(category newCategory: SearchCategory) {
    category = newCategory
    styleCategoryButtons()
    updateDataSource(animated: false, reloadingSections: [.Artist, .Album, .Song, .Playlist])
    tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
  }

  /// items shown for a result section with the current category
  fileprivate func visibleCount(_ section: SearchSection, total: Int) -> Int {
    switch category {
    case .top: return min(total, Self.topHitsLimit)
    default: return category.section == section ? total : 0
    }
  }
  private var accountObjectId: NSManagedObjectID?
  private let account: Account
  private var accountNotificationHandler: AccountNotificationHandler?

  init(account: Account) {
    self.account = account
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func createDiffableDataSource() -> SearchDiffableDataSource {
    let source =
      SearchDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        return self.tableView(self.tableView, cellForRowAt: indexPath)
      }
    source.searchVC = self
    return source
  }

  /// `reloadingSections`: sections whose header changed (applying a snapshot doesn't update the
  /// headers of unchanged sections)
  func updateDataSource(animated: Bool, reloadingSections: [SearchSection] = []) {
    guard let dataSource = tableView?.dataSource as? UITableViewDiffableDataSource<
      Int,
      NSManagedObjectID
    > else {
      assertionFailure("The data source has not implemented snapshot support while it should")
      return
    }
    var snapshot = dataSource.snapshot() as NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>
    snapshot.deleteAllItems()
    snapshot.appendSections(SearchSection.allCases.compactMap { $0.rawValue })
    snapshot.appendItems(
      searchHistory.compactMap { $0.managedObject.objectID },
      toSection: SearchSection.History.rawValue
    )
    snapshot.appendItems(
      artists.prefix(visibleCount(.Artist, total: artists.count)).compactMap { $0.managedObject.objectID },
      toSection: SearchSection.Artist.rawValue
    )
    snapshot.appendItems(
      albums.prefix(visibleCount(.Album, total: albums.count)).compactMap { $0.managedObject.objectID },
      toSection: SearchSection.Album.rawValue
    )
    snapshot.appendItems(
      playlists.prefix(visibleCount(.Playlist, total: playlists.count)).compactMap { $0.managedObject.objectID },
      toSection: SearchSection.Playlist.rawValue
    )
    snapshot.appendItems(
      songs.prefix(visibleCount(.Song, total: songs.count)).compactMap { $0.managedObject.objectID },
      toSection: SearchSection.Song.rawValue
    )
    snapshot.reloadSections(reloadingSections.map(\.rawValue))
    dataSource.apply(snapshot, animatingDifferences: animated)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    /// Store the data source in an instance property to make sure it's retained.
    diffableDataSource = createDiffableDataSource()
    /// Assign the data source to your collection view.
    tableView.dataSource = diffableDataSource

    accountObjectId = account.managedObject.objectID
    searchHistory = appDelegate.storage.main.library.getSearchHistory(for: account)
    updateDataSource(animated: false)
    navigationController?.navigationItem.searchBarPlacementAllowsExternalIntegration = true

    tableView.register(nibName: PlaylistTableCell.typeName)
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.reloadOnTextSizeChange()
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderTopPadding = 0.0

    containableAtIndexPathCallback = { indexPath in
      switch SearchSection(rawValue: indexPath.section) {
      case .History:
        return self.searchHistory[indexPath.row].searchedPlayableContainable
      case .Playlist:
        return self.playlists[indexPath.row]
      case .Artist:
        return self.artists[indexPath.row]
      case .Album:
        return self.albums[indexPath.row]
      case .Song:
        return self.songs[indexPath.row]
      case .none:
        return nil
      }
    }
    playContextAtIndexPathCallback = { indexPath in
      switch SearchSection(rawValue: indexPath.section) {
      case .History:
        let history = self.searchHistory[indexPath.row]
        guard let container = history.searchedPlayableContainable else { return nil }
        return PlayContext(containable: container)
      case .Playlist:
        let entity = self.playlists[indexPath.row]
        return PlayContext(containable: entity)
      case .Artist:
        let entity = self.artists[indexPath.row]
        return PlayContext(containable: entity)
      case .Album:
        let entity = self.albums[indexPath.row]
        return PlayContext(containable: entity)
      case .Song:
        let entity = self.songs[indexPath.row]
        return PlayContext(containable: entity)
      case .none:
        return nil
      }
    }
    swipeCallback = { indexPath, completionHandler in
      self.determSwipeActionContext(at: indexPath) { actionContext in
        completionHandler(actionContext)
      }
    }
    updateContentUnavailable()
    setupRequestFooter()
    accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForActiveAccountChange { [weak self] accountInfo in
      guard let self else { return }
      setupUserNavButton(
        currentAccount: account,
        userButton: &userButton,
        userBarButtonItem: &userBarButtonItem
      )
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if let footer = tableView.tableFooterView, abs(footer.frame.width - tableView.bounds.width) > 0.5 {
      layoutRequestFooter()
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    appDelegate.userStatistics.visited(.search)
    configureSearchController(
      placeholder: "Search in \"Library\"",
      scopeButtonTitles: ["All", "Cached"]
    )
  }

  public func activateSearchBar() {
    if isViewLoaded {
      // activate searchBar
      searchController.searchBar.becomeFirstResponder()
    }
  }

  private func clearSearchHistory() {
    appDelegate.storage.main.library.deleteSearchHistory()
    appDelegate.storage.main.library.saveContext()
    searchHistory = []
    // also hide the history header with the "Clear" button
    updateDataSource(animated: true, reloadingSections: [.History])
    updateContentUnavailable()
  }

  func determSwipeActionContext(
    at indexPath: IndexPath,
    completionHandler: @escaping (_ actionContext: SwipeActionContext?) -> ()
  ) {
    switch SearchSection(rawValue: indexPath.section) {
    case .History:
      let history = searchHistory[indexPath.row]
      guard let container = history.searchedPlayableContainable
      else { completionHandler(nil); return }
      Task { @MainActor in
        do {
          try await container.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "History Sync", error: error)
        }
        completionHandler(SwipeActionContext(containable: container))
      }
    case .Playlist:
      let playlist = playlists[indexPath.row]
      Task { @MainActor in
        do {
          try await playlist.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
        }
        completionHandler(SwipeActionContext(containable: playlist))
      }
    case .Artist:
      let artist = artists[indexPath.row]
      Task { @MainActor in
        do {
          try await artist.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Artist Sync", error: error)
        }
        completionHandler(SwipeActionContext(containable: artist))
      }
    case .Album:
      let album = albums[indexPath.row]
      Task { @MainActor in
        do {
          try await album.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Album Sync", error: error)
        }
        completionHandler(SwipeActionContext(containable: album))
      }
    case .Song:
      let song = songs[indexPath.row]
      completionHandler(SwipeActionContext(containable: song))
    case .none:
      completionHandler(nil)
    }
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    if SearchSection(rawValue: indexPath.section) == .Song {
      let song = songs[indexPath.row]
      return PlayContext(containable: song)
    } else if SearchSection(rawValue: indexPath.section) == .History {
      let history = searchHistory[indexPath.row]
      guard let song = history.searchedPlayableContainable as? Song else { return nil }
      return PlayContext(containable: song)
    }
    return nil
  }

  // MARK: - Table view data source

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch SearchSection(rawValue: indexPath.section) {
    case .History:
      let history = searchHistory[indexPath.row]
      guard let container = history.searchedPlayableContainable else { return UITableViewCell() }
      if let playlist = container as? Playlist {
        let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
        cell.display(playlist: playlist, rootView: self)
        return cell
      } else if let song = container as? Song {
        let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
        cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
        return cell
      } else {
        let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
        cell.display(container: container, rootView: self)
        return cell
      }
    case .Playlist:
      let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
      let playlist = playlists[indexPath.row]
      cell.display(playlist: playlist, rootView: self)
      return cell
    case .Artist:
      let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
      let artist = artists[indexPath.row]
      cell.display(container: artist, rootView: self)
      return cell
    case .Album:
      let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
      let album = albums[indexPath.row]
      cell.display(container: album, rootView: self)
      return cell
    case .Song:
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      let song = songs[indexPath.row]
      cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
      return cell
    case .none:
      return UITableViewCell()
    }
  }

  /// The search history header has a "Clear" button. It is part of the table (not the navigation
  /// bar), because on iPhone the search tab activates the search automatically, which hides the
  /// navigation bar.
  override func tableView(
    _ tableView: UITableView,
    viewForHeaderInSection section: Int
  )
    -> UIView? {
    // Blackbox: "Mehr anzeigen …" in the result sections of the top hits
    if isSearchActive, category == .top, let searchSection = SearchSection(rawValue: section),
       searchSection != .History {
      let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
      var content = header.defaultContentConfiguration()
      content.text = tableView.dataSource?.tableView?(tableView, titleForHeaderInSection: section)
      content.textProperties.font = UIFont.preferredFont(forTextStyle: .title3).withBoldTrait()
      content.textProperties.color = .label
      header.contentConfiguration = content
      let target = SearchCategory.allCases.first { $0.section == searchSection }
      let more = UIButton(type: .system, primaryAction: UIAction(title: "Mehr anzeigen …") { [weak self] _ in
        if let target { self?.select(category: target) }
      })
      more.translatesAutoresizingMaskIntoConstraints = false
      header.contentView.addSubview(more)
      NSLayoutConstraint.activate([
        more.trailingAnchor.constraint(equalTo: header.contentView.layoutMarginsGuide.trailingAnchor),
        more.centerYAnchor.constraint(equalTo: header.contentView.centerYAnchor),
      ])
      return header
    }
    // nil: default header for all other sections
    guard SearchSection(rawValue: section) == .History, !isSearchActive,
          !searchHistory.isEmpty else { return nil }

    let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
    var content = header.defaultContentConfiguration()
    content.text = tableView.dataSource?.tableView?(tableView, titleForHeaderInSection: section)
    header.contentConfiguration = content

    let clearButton = UIButton(
      type: .system,
      primaryAction: UIAction(title: "Clear") { [weak self] _ in
        self?.clearSearchHistory()
      }
    )
    clearButton.translatesAutoresizingMaskIntoConstraints = false
    clearButton.preferredBehavioralStyle = .pad
    header.contentView.addSubview(clearButton)
    NSLayoutConstraint.activate([
      clearButton.trailingAnchor
        .constraint(equalTo: header.contentView.layoutMarginsGuide.trailingAnchor),
      clearButton.centerYAnchor.constraint(equalTo: header.contentView.centerYAnchor),
    ])
    return header
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    switch SearchSection(rawValue: section) {
    case .History:
      return !isSearchActive ? CommonScreenOperations.tableSectionHeightLarge : 0
    case .Playlist:
      return (isSearchActive && visibleCount(.Playlist, total: playlists.count) > 0) ? CommonScreenOperations
        .tableSectionHeightLarge : 0
    case .Artist:
      return (isSearchActive && visibleCount(.Artist, total: artists.count) > 0) ? CommonScreenOperations
        .tableSectionHeightLarge : 0
    case .Album:
      return (isSearchActive && visibleCount(.Album, total: albums.count) > 0) ? CommonScreenOperations
        .tableSectionHeightLarge : 0
    case .Song:
      return (isSearchActive && visibleCount(.Song, total: songs.count) > 0) ? CommonScreenOperations.tableSectionHeightLarge : 0
    case .none:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch SearchSection(rawValue: indexPath.section) {
    case .History:
      let history = searchHistory[indexPath.row]
      guard let container = history.searchedPlayableContainable else { return 0.0 }
      if container is Playlist {
        return PlaylistTableCell.rowHeight
      } else if container is Song {
        return PlayableTableCell.rowHeight
      } else {
        return GenericTableCell.rowHeight
      }
    case .Playlist:
      return PlaylistTableCell.rowHeight
    case .Artist:
      return GenericTableCell.rowHeight
    case .Album:
      return GenericTableCell.rowHeight
    case .Song:
      return PlayableTableCell.rowHeight
    case .none:
      return 0.0
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    switch SearchSection(rawValue: indexPath.section) {
    case .History:
      let history = searchHistory[indexPath.row]
      guard let container = history.searchedPlayableContainable else { break }
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: container)
      if !(container is Song) {
        EntityPreviewActionBuilder(container: container, on: self).performPreviewTransition()
      }
    case .Playlist:
      let playlist = playlists[indexPath.row]
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: playlist)
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
        animated: true
      )
    case .Artist:
      let artist = artists[indexPath.row]
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: artist)
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
        animated: true
      )
    case .Album:
      let album = albums[indexPath.row]
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: album)
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
    case .Song:
      let song = songs[indexPath.row]
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: song)
    case .none: break
    }
    appDelegate.storage.main.library.saveContext()
  }

  struct SearchResultObjectContainer: Sendable {
    var artistsIDs = [NSManagedObjectID]()
    var albumsIDs = [NSManagedObjectID]()
    var playlistsIDs = [NSManagedObjectID]()
    var songsIDs = [NSManagedObjectID]()
  }

  override func updateSearchResults(for searchController: UISearchController) {
    guard let searchText = searchController.searchBar.text, let accountObjectId else { return }
    searchTaskRunner.cancelAll()
    updateRequestSearch(searchText)
    if !searchText.isEmpty, !searchController.searchBar.isCachedScopeSelected {
      searchTaskRunner.runRemoteSearch(searchText: searchText) { do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .searchArtists(searchText: searchText)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Artists Search", error: error)
      }}

      searchTaskRunner.runRemoteSearch(searchText: searchText) { do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .searchAlbums(searchText: searchText)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Albums Search", error: error)
      }}

      searchTaskRunner.runRemoteSearch(searchText: searchText) { do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .searchSongs(searchText: searchText)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Songs Search", error: error)
      }}

      searchTaskRunner.run { do {
        let searchResult = try await self.appDelegate.storage.async
          .performAndGet { asyncCompanion in
            let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
            let artists = asyncCompanion.library.searchArtists(
              for: accountAsync,
              searchText: searchText,
              onlyCached: false,
              displayFilter: .all
            )
            let albums = asyncCompanion.library.searchAlbums(
              for: accountAsync,
              searchText: searchText,
              onlyCached: false,
              displayFilter: .all
            )
            let playlists = asyncCompanion.library.searchPlaylists(
              for: accountAsync,
              searchText: searchText,
              playlistSearchCategory: .all
            )
            let songs = asyncCompanion.library.searchSongs(
              for: accountAsync,
              searchText: searchText,
              onlyCached: false,
              displayFilter: .all
            )

            var result = SearchResultObjectContainer()
            result.artistsIDs = FuzzySearcher
              .findBestMatch(in: artists, search: searchText, isTokenized: true)
              .prefix(upToAsArray: Self.categoryItemLimit)
              .compactMap { $0 as? Artist }
              .compactMap { $0.managedObject.objectID }
            result.albumsIDs = FuzzySearcher
              .findBestMatch(in: albums, search: searchText, isTokenized: true)
              .prefix(upToAsArray: Self.categoryItemLimit)
              .compactMap { $0 as? Album }
              .compactMap { $0.managedObject.objectID }
            result.playlistsIDs = FuzzySearcher
              .findBestMatch(in: playlists, search: searchText, isTokenized: true)
              .prefix(upToAsArray: Self.categoryItemLimit)
              .compactMap { $0 as? Playlist }
              .compactMap { $0.managedObject.objectID }
            result.songsIDs = FuzzySearcher.findBestMatch(
              in: songs,
              search: searchText,
              isTokenized: true,
              searchableText: { "\($0.name) \(($0 as? Song)?.creatorName ?? "")" }
            )
            .prefix(upToAsArray: Self.categoryItemLimit)
            .compactMap { $0 as? Song }
            .compactMap { $0.managedObject.objectID }
            // Blackbox: tolerante Suche ("suicide boys" findet "$uicideboy$", "ac dc" findet "AC/DC")
            let loose = blackboxLoose(searchText)
            if loose.count >= 3 {
              let looseArtists = asyncCompanion.library.getArtists(for: accountAsync)
                .filter { blackboxLoose($0.name).contains(loose) }
                .prefix(10)
              let artistIDs = Set(looseArtists.map(\.id))
              let looseAlbums = asyncCompanion.library.getAlbums(for: accountAsync)
                .filter { blackboxLoose($0.name).contains(loose) || ($0.artist.map { artistIDs.contains($0.id) } ?? false) }
                .prefix(30)
              var looseSongs: [Song] = []
              for artist in looseArtists.prefix(3) {
                looseSongs += asyncCompanion.library.searchSongs(
                  for: accountAsync, searchText: artist.name, onlyCached: false, displayFilter: .all
                ).filter { ($0.artist.map { artistIDs.contains($0.id) } ?? false) }
              }
              func merge(_ existing: [NSManagedObjectID], _ extra: [NSManagedObjectID]) -> [NSManagedObjectID] {
                var seen = Set(existing)
                return existing + extra.filter { seen.insert($0).inserted }
              }
              result.artistsIDs = merge(result.artistsIDs, looseArtists.map { $0.managedObject.objectID })
              result.albumsIDs = merge(result.albumsIDs, looseAlbums.map { $0.managedObject.objectID })
              result.songsIDs = merge(result.songsIDs, looseSongs.prefix(Self.categoryItemLimit).map { $0.managedObject.objectID })
            }
            return result
          }

        guard searchText == self.searchController.searchBar.text else { return }
        self.isSearchActive = true
        self.searchHistory = []
        self.artists = searchResult.artistsIDs
          .compactMap { self.appDelegate.storage.main.context.object(with: $0) as? ArtistMO }
          .compactMap { Artist(managedObject: $0) }
        self.albums = searchResult.albumsIDs
          .compactMap { self.appDelegate.storage.main.context.object(with: $0) as? AlbumMO }
          .compactMap { Album(managedObject: $0) }
        self.playlists = searchResult.playlistsIDs
          .compactMap { self.appDelegate.storage.main.context.object(with: $0) as? PlaylistMO }
          .compactMap { Playlist(library: self.appDelegate.storage.main.library, managedObject: $0)
          }
        self.songs = searchResult.songsIDs
          .compactMap { self.appDelegate.storage.main.context.object(with: $0) as? SongMO }
          .compactMap { Song(managedObject: $0) }
        self.tableView.separatorStyle = .singleLine
        self.updateDataSource(animated: false)
        self.updateContentUnavailable()
      } catch {
        // do nothing
      }}
    } else if !searchText.isEmpty, searchController.searchBar.isCachedScopeSelected {
      searchTaskRunner.run { do {
        let searchResult = try await self.appDelegate.storage.async
          .performAndGet { asyncCompanion in
            let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
            let artists = asyncCompanion.library.searchArtists(
              for: accountAsync,
              searchText: searchText,
              onlyCached: true,
              displayFilter: .all
            )
            let albums = asyncCompanion.library.searchAlbums(
              for: accountAsync,
              searchText: searchText,
              onlyCached: true,
              displayFilter: .all
            )
            let playlists = asyncCompanion.library.searchPlaylists(
              for: accountAsync,
              searchText: searchText,
              playlistSearchCategory: .cached
            )
            let songs = asyncCompanion.library.searchSongs(
              for: accountAsync,
              searchText: searchText,
              onlyCached: true,
              displayFilter: .all
            )

            var result = SearchResultObjectContainer()
            result.artistsIDs = FuzzySearcher
              .findBestMatch(in: artists, search: searchText, isTokenized: true)
              .prefix(upToAsArray: Self.categoryItemLimit)
              .compactMap { $0 as? Artist }
              .compactMap { $0.managedObject.objectID }
            result.albumsIDs = FuzzySearcher
              .findBestMatch(in: albums, search: searchText, isTokenized: true)
              .prefix(upToAsArray: Self.categoryItemLimit)
              .compactMap { $0 as? Album }
              .compactMap { $0.managedObject.objectID }
            result.playlistsIDs = FuzzySearcher
              .findBestMatch(in: playlists, search: searchText, isTokenized: true)
              .prefix(upToAsArray: Self.categoryItemLimit)
              .compactMap { $0 as? Playlist }
              .compactMap { $0.managedObject.objectID }
            result.songsIDs = FuzzySearcher.findBestMatch(
              in: songs,
              search: searchText,
              isTokenized: true,
              searchableText: { "\($0.name) \(($0 as? Song)?.creatorName ?? "")" }
            )
            .prefix(upToAsArray: Self.categoryItemLimit)
            .compactMap { $0 as? Song }
            .compactMap { $0.managedObject.objectID }
            return result
          }

        guard searchText == self.searchController.searchBar.text else { return }
        self.isSearchActive = true
        self.searchHistory = []
        self.artists = searchResult.artistsIDs
          .compactMap { self.appDelegate.storage.main.context.object(with: $0) as? ArtistMO }
          .compactMap { Artist(managedObject: $0) }
        self.albums = searchResult.albumsIDs
          .compactMap { self.appDelegate.storage.main.context.object(with: $0) as? AlbumMO }
          .compactMap { Album(managedObject: $0) }
        self.playlists = searchResult.playlistsIDs
          .compactMap { self.appDelegate.storage.main.context.object(with: $0) as? PlaylistMO }
          .compactMap { Playlist(library: self.appDelegate.storage.main.library, managedObject: $0)
          }
        self.songs = searchResult.songsIDs
          .compactMap { self.appDelegate.storage.main.context.object(with: $0) as? SongMO }
          .compactMap { Song(managedObject: $0) }
        self.tableView.separatorStyle = .singleLine
        self.updateDataSource(animated: false)
        self.updateContentUnavailable()
      } catch {
        // do nothing
      }}
    } else {
      isSearchActive = false
      searchHistory = appDelegate.storage.main.library.getSearchHistory(for: account)
      artists = []
      albums = []
      playlists = []
      songs = []
      tableView.separatorStyle = .singleLine
      updateDataSource(animated: false)
      updateContentUnavailable()
    }
  }

  func updateContentUnavailable() {
    if isSearchActive {
      if artists.isEmpty, albums.isEmpty, playlists.isEmpty, songs.isEmpty,
         !(BlackboxRequestConfig.isConfigured && requestModel.query.count >= 2) {
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
      } else {
        contentUnavailableConfiguration = nil
      }
    } else {
      contentUnavailableConfiguration = searchHistory.isEmpty ? noSearchHistoryConfig : nil
    }
  }

  lazy var noSearchHistoryConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = .clock
    config.text = "No Search History"
    config.secondaryText = "Your search history will appear here."
    return config
  }()
}

/// Vergleichsform für die tolerante Suche: Kleinbuchstaben, ohne Akzente/Leer- und Sonderzeichen, $ -> s, & -> and
func blackboxLoose(_ s: String) -> String {
  let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    .replacingOccurrences(of: "$", with: "s")
    .replacingOccurrences(of: "&", with: "and")
    .replacingOccurrences(of: "+", with: "and")
  return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)).lowercased()
}

extension UIFont {
  fileprivate func withBoldTrait() -> UIFont {
    guard let d = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
    return UIFont(descriptor: d, size: 0)
  }
}
