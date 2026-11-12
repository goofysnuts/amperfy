//
//  HomeVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 24.11.25.
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
import CoreData
import OSLog
import UIKit

// MARK: - HomeVC

final class HomeVC: UICollectionViewController {
  // MARK: - Properties

  private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!
  private let log = OSLog(subsystem: "Amperfy", category: "HomeVC")

  private static let itemWidth: CGFloat = 160.0
  /// FireSonic: the mix sections get larger covers (Spotify-like "Deine Top-Mixes")
  private static let mixItemWidth: CGFloat = 176.0

  private static func itemWidth(for section: HomeSection?) -> CGFloat {
    switch section {
    case .topMixes, .ownMixes: return mixItemWidth
    default: return itemWidth
    }
  }

  /// Gives the layout access to the visible sections (the layout is created before `self`)
  @MainActor
  private final class SectionLookup {
    var sections: () -> [HomeSection] = { [] }
    var recapLarge: () -> Bool = { false }
  }

  private let sectionLookup: SectionLookup
  /// Blackbox: only sections with content are shown (no empty headers)
  private var displayedSections: [HomeSection] = []
  private var recapLargeShown = false

  private var userButton: UIButton?
  private var userBarButtonItem: UIBarButtonItem?
  private let account: Account
  private var accountNotificationHandler: AccountNotificationHandler?
  private let sharedHome: HomeManager

  // MARK: - Init

  init(account: Account) {
    self.account = account
    let appDelegate = (UIApplication.shared.delegate as! AppDelegate)
    self.sharedHome = HomeManager(
      account: account,
      storage: appDelegate.storage,
      getMeta: appDelegate.getMeta,
      eventLogger: appDelegate.eventLogger
    )
    let lookup = SectionLookup()
    self.sectionLookup = lookup
    let layout = HomeVC.createLayout(lookup: lookup)
    super.init(collectionViewLayout: layout)
    lookup.sections = { [weak self] in self?.displayedSections ?? [] }
    lookup.recapLarge = { [weak self] in self?.sharedHome.hasUnseenRecap ?? false }
    sharedHome.applySnapshotCB = { [weak self] in
      guard let self else { return }
      applySnapshot(animated: true)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    // ensures that the collection view stops placing items under the sidebar
    collectionView.contentInsetAdjustmentBehavior = .scrollableAxes
    title = BlackboxAppearance.homeTitle

    accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    // Blackbox: account switching and the section editor live in the settings

    registerForTraitChanges(
      [UITraitPreferredContentSizeCategory.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.collectionView.collectionViewLayout.invalidateLayout()
      }
    )

    navigationController?.navigationBar.prefersLargeTitles = true
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "tv"),
      style: .plain,
      target: self,
      action: #selector(remoteTapped)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = "FireTV fernsteuern"
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appearanceChanged),
      name: BlackboxAppearance.changedNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(homeSectionsEdited),
      name: HomeVC.sectionsEditedNotification,
      object: nil
    )
    configureCollectionView()
    configureDataSource()
    sharedHome.createFetchController()
    applySnapshot(animated: false)

    appDelegate.notificationHandler.register(
      self,
      selector: #selector(refreshOfflineMode),
      name: .offlineModeChanged,
      object: nil
    )
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    sharedHome.updateFromRemote()
  }

  // MARK: - Layout

  private static func createQuickAccessLayout(
    environment: NSCollectionLayoutEnvironment
  ) -> NSCollectionLayoutSection {
    let tileHeight = HomeQuickAccessCell.tileHeight(for: environment.traitCollection)
    let columns = environment.container.effectiveContentSize.width > 700 ? 4 : 2
    let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
      heightDimension: .fractionalHeight(1.0)
    ))
    item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
    let group = NSCollectionLayoutGroup.horizontal(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .absolute(tileHeight)
      ),
      repeatingSubitem: item,
      count: columns
    )
    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 8
    section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 24, trailing: 12)
    return section
  }

  private static func headerItem() -> NSCollectionLayoutBoundarySupplementaryItem {
    let header = NSCollectionLayoutBoundarySupplementaryItem(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(44)
      ),
      elementKind: UICollectionView.elementKindSectionHeader,
      alignment: .top
    )
    header.zIndex = 1
    return header
  }

  private static func createRecapLayout(
    environment: NSCollectionLayoutEnvironment,
    large: Bool
  ) -> NSCollectionLayoutSection {
    let width = environment.container.effectiveContentSize.width
    let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .fractionalHeight(1.0)
    ))
    let groupSize: NSCollectionLayoutSize
    if large {
      let cardWidth = min(width - 40, 520)
      groupSize = NSCollectionLayoutSize(
        widthDimension: .absolute(cardWidth),
        heightDimension: .absolute(cardWidth * 1.15)
      )
    } else {
      let tileHeight = HomeQuickAccessCell.tileHeight(for: environment.traitCollection)
      groupSize = NSCollectionLayoutSize(
        widthDimension: .absolute(min(width * 0.62, 280)),
        heightDimension: .absolute(tileHeight + 8)
      )
    }
    let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
    let section = NSCollectionLayoutSection(group: group)
    section.orthogonalScrollingBehavior = large ? .groupPagingCentered : .continuous
    section.interGroupSpacing = large ? 14 : 10
    section.contentInsets = NSDirectionalEdgeInsets(
      top: 8,
      leading: large ? 0 : 16,
      bottom: large ? 28 : 20,
      trailing: large ? 0 : 16
    )
    if !large {
      section.boundarySupplementaryItems = [headerItem()]
    }
    return section
  }

  private static func createSongOfTheDayLayout(
    environment: NSCollectionLayoutEnvironment
  ) -> NSCollectionLayoutSection {
    let height = TextScaling.scaledValue(
      150,
      compatibleWith: environment.traitCollection,
      maximum: .accessibilityMedium
    )
    let width = environment.container.effectiveContentSize.width
    let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .fractionalHeight(1.0)
    ))
    let group = NSCollectionLayoutGroup.horizontal(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .absolute(min(width - 32, 620)),
        heightDimension: .absolute(height)
      ),
      subitems: [item]
    )
    let section = NSCollectionLayoutSection(group: group)
    section.orthogonalScrollingBehavior = .none
    section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 24, trailing: 16)
    section.boundarySupplementaryItems = [headerItem()]
    return section
  }

  private static func createLayout(lookup: SectionLookup) -> UICollectionViewCompositionalLayout {
    let layout = UICollectionViewCompositionalLayout { sectionIndex, environment in
      let homeSection = lookup.sections().element(at: sectionIndex)
      if homeSection == .quickAccess {
        return createQuickAccessLayout(environment: environment)
      }
      if homeSection == .recaps {
        return createRecapLayout(environment: environment, large: lookup.recapLarge())
      }
      if homeSection == .songOfTheDay {
        return createSongOfTheDayLayout(environment: environment)
      }
      let itemWidth = Self.itemWidth(for: homeSection)

      // Item: square image with title below
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .fractionalHeight(1.0)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)

      // Group: fixed width to show large image; height fits image + labels for the text size
      let labelAreaHeight = AlbumCollectionCell
        .labelAreaHeight(for: environment.traitCollection, defaultHeight: 50.0)
      let groupSize = NSCollectionLayoutSize(
        widthDimension: .absolute(itemWidth),
        heightDimension: .absolute(itemWidth + labelAreaHeight)
      )
      let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

      let sectionLayout = NSCollectionLayoutSection(group: group)
      sectionLayout.orthogonalScrollingBehavior = .continuous
      sectionLayout.interGroupSpacing = 12
      sectionLayout.contentInsets = NSDirectionalEdgeInsets(
        top: 8,
        leading: 16,
        bottom: 24,
        trailing: 16
      )

      // Header
      let headerSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(44)
      )
      let header = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: headerSize,
        elementKind: UICollectionView.elementKindSectionHeader,
        alignment: .top
      )
      header.pinToVisibleBounds = false
      header.zIndex = 1
      sectionLayout.boundarySupplementaryItems = [header]

      return sectionLayout
    }
    return layout
  }

  // MARK: - CollectionView Setup

  private func configureCollectionView() {
    collectionView.backgroundColor = .systemBackground
    collectionView.register(
      UINib(nibName: AlbumCollectionCell.typeName, bundle: .main),
      forCellWithReuseIdentifier: AlbumCollectionCell.typeName
    )
    collectionView.register(
      HomeQuickAccessCell.self,
      forCellWithReuseIdentifier: HomeQuickAccessCell.reuseID
    )
    collectionView.register(
      HomeRecapCell.self,
      forCellWithReuseIdentifier: HomeRecapCell.reuseID
    )
    collectionView.register(
      HomeSongOfTheDayCell.self,
      forCellWithReuseIdentifier: HomeSongOfTheDayCell.reuseID
    )
    collectionView.register(
      SectionHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: SectionHeaderView.reuseID
    )
  }

  // MARK: - Data Source

  private func configureDataSource() {
    dataSource = UICollectionViewDiffableDataSource<
      HomeSection,
      HomeItem
    >(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
      guard let self else { return UICollectionViewCell() }
      let homeSection = self.displayedSections.element(at: indexPath.section)
      let theme = self.appDelegate.storage.settings.accounts.getSetting(self.account.info).read
        .themePreference
      if homeSection == .recaps, let playlist = item.playableContainable as? Playlist {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: HomeRecapCell.reuseID,
          for: indexPath
        ) as! HomeRecapCell
        cell.display(
          playlist: playlist,
          recap: RecapRegistry.recaps[playlist.id],
          large: self.sharedHome.hasUnseenRecap,
          theme: theme
        )
        return cell
      }
      if homeSection == .songOfTheDay, let song = item.playableContainable as? Song {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: HomeSongOfTheDayCell.reuseID,
          for: indexPath
        ) as! HomeSongOfTheDayCell
        cell.display(song: song, theme: theme)
        cell.playHandler = { [weak self] in
          self?.appDelegate.player.play(context: PlayContext(containable: song))
        }
        cell.addHandler = { [weak self] in
          guard let self else { return }
          self.appDelegate.player.insertUserQueue(playables: [song])
          self.appDelegate.eventLogger.info(
            topic: "Song des Tages",
            message: "„\(song.title)“ wird als Nächstes gespielt."
          )
        }
        return cell
      }
      if homeSection == .quickAccess {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: HomeQuickAccessCell.reuseID,
          for: indexPath
        ) as! HomeQuickAccessCell
        cell.display(
          container: item.playableContainable,
          theme: self.appDelegate.storage.settings.accounts.getSetting(self.account.info).read
            .themePreference
        )
        return cell
      }
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: AlbumCollectionCell.typeName,
        for: indexPath
      ) as! AlbumCollectionCell
      cell.display(
        container: item.playableContainable,
        rootView: self,
        itemWidth: Self.itemWidth(for: homeSection),
        initialIndexPath: indexPath
      )
      return cell
    }

    dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
      guard kind == UICollectionView.elementKindSectionHeader,
            let header = collectionView.dequeueReusableSupplementaryView(
              ofKind: kind,
              withReuseIdentifier: SectionHeaderView.reuseID,
              for: indexPath
            ) as? SectionHeaderView,
            let section = self?.displayedSections.element(at: indexPath.section)
      else {
        return nil
      }
      header.title = section.title
      if section == .randomAlbums {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomAlbumsSection() }
      } else if section == .randomArtists {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomArtistsSection() }
      } else if section == .randomGenres {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomGenresSection() }
      } else if section == .randomSongs {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomSongsSection() }
      } else {
        header.showsRefreshButton = false
        header.setRefreshHandler(nil)
      }
      return header
    }
  }

  private func applySnapshot(animated: Bool = true) {
    var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
    let previousSections = displayedSections
    let previousRecapLarge = recapLargeShown
    displayedSections = sharedHome.orderedVisibleSections.filter { !(sharedHome.data[$0] ?? []).isEmpty }
    recapLargeShown = sharedHome.hasUnseenRecap
    snapshot.appendSections(displayedSections)
    for section in displayedSections {
      // Ids are stable per entity, so a repeated entity would be a duplicate identifier (assert).
      var seenIds = Set<String>()
      let items = (sharedHome.data[section] ?? []).filter { seenIds.insert($0.id).inserted }
      snapshot.appendItems(items, toSection: section)
    }
    let oldItems = dataSource.snapshot().itemIdentifiers
    let oldFingerprints = Dictionary(oldItems.map { ($0.id, $0.artworkFingerprint) }) { first, _ in
      first
    }
    let oldCovers = Dictionary(oldItems.map { ($0.id, $0.serverCoverId) }) { first, _ in first }
    let changedItems = snapshot.itemIdentifiers.filter {
      guard let old = oldFingerprints[$0.id] else { return false }
      return old != $0.artworkFingerprint || oldCovers[$0.id] != $0.serverCoverId
    }
    snapshot.reconfigureItems(changedItems)
    if previousRecapLarge != recapLargeShown, snapshot.sectionIdentifiers.contains(.recaps) {
      // large <-> small recap cards: new layout and new cell content
      snapshot.reconfigureItems(snapshot.itemIdentifiers(inSection: .recaps))
    }
    if previousSections != displayedSections || previousRecapLarge != recapLargeShown {
      collectionView.collectionViewLayout.invalidateLayout()
    }
    dataSource.apply(snapshot, animatingDifferences: animated)
  }

  @objc
  private func refreshOfflineMode() {
    os_log("HomeVC: OfflineModeChanged", log: self.log, type: .info)
    sharedHome.createFetchController()
  }

  static let sectionsEditedNotification = Notification.Name("de.jannes.blackbox.homeSectionsEdited")

  @objc
  private func remoteTapped() {
    let nav = UINavigationController(rootViewController: FireTVRemoteVC())
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }

  @objc
  private func appearanceChanged() {
    title = BlackboxAppearance.homeTitle
    navigationItem.title = title
    collectionView.reloadData()
  }

  @objc
  private func homeSectionsEdited() {
    sharedHome.reloadSectionsFromSettings()
  }

  /// Blackbox: section editor, opened from the settings
  @MainActor
  static func presentSectionEditor(from presenter: UIViewController, accountInfo: AccountInfo) {
    let appDelegate = (UIApplication.shared.delegate as! AppDelegate)
    let setting = appDelegate.storage.settings.accounts.getSetting(accountInfo).read
    let editor = HomeEditorVC(
      order: setting.homeSectionOrder,
      visible: setting.homeSections
    ) { order, visible in
      appDelegate.storage.settings.accounts.updateSetting(accountInfo) { accountSettings in
        accountSettings.homeSections = visible
        accountSettings.homeSectionOrder = order
      }
      NotificationCenter.default.post(name: HomeVC.sectionsEditedNotification, object: nil)
    }
    let nav = UINavigationController(rootViewController: editor)
    nav.modalPresentationStyle = .formSheet
    presenter.present(nav, animated: true)
  }

  private func presentSectionEditor() {
    // Build a simple editor using a temporary UIViewController with a table view
    let editor = HomeEditorVC(
      order: appDelegate.storage.settings.accounts.getSetting(account.info).read.homeSectionOrder,
      visible: sharedHome.orderedVisibleSections
    ) { [weak self] order, visible in
      guard let self else { return }
      sharedHome.orderedVisibleSections = visible
      // same account the order was read from
      appDelegate.storage.settings.accounts.updateSetting(account.info) { accountSettings in
        accountSettings.homeSections = visible
        accountSettings.homeSectionOrder = order
      }
      applySnapshot(animated: true)

      sharedHome.createFetchController()
      sharedHome.updateFromRemote()
    }
    #if targetEnvironment(macCatalyst)
      // reordering via drag & drop did not drop inside a form sheet on macOS
      // revert to the form sheet once fixed: https://developer.apple.com/forums/thread/850756
      navigationController?.pushViewController(editor, animated: true)
    #else
      let nav = UINavigationController(rootViewController: editor)
      nav.modalPresentationStyle = .formSheet
      present(nav, animated: true)
    #endif
  }

  @objc
  func refreshRandomAlbumsSection() {
    Task { @MainActor in
      await sharedHome.updateRandomAlbums(isOfflineMode: sharedHome.isOfflineMode)
    }
  }

  @objc
  func refreshRandomArtistsSection() {
    Task { @MainActor in
      await sharedHome.updateRandomArtists(isOfflineMode: sharedHome.isOfflineMode)
    }
  }

  @objc
  func refreshRandomGenresSection() {
    Task { @MainActor in
      await sharedHome.updateRandomGenres()
    }
  }

  @objc
  func refreshRandomSongsSection() {
    Task { @MainActor in
      await sharedHome.updateRandomSongs(isOfflineMode: sharedHome.isOfflineMode)
    }
  }

  // MARK: - Selection Handling

  override func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    guard let playableContainer = dataSource.itemIdentifier(for: indexPath)?.playableContainable
    else { return }

    if displayedSections.element(at: indexPath.section) == .recaps,
       let playlist = playableContainer as? Playlist,
       let recap = RecapRegistry.recaps[playlist.id] {
      let stories = RecapStoriesVC(recap: recap, playlist: playlist, account: account)
      stories.modalPresentationStyle = .fullScreen
      present(stories, animated: true)
      return
    }

    if let album = playableContainer as? Album {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let artist = playableContainer as? Artist {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let playlist = playableContainer as? Playlist {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let song = playableContainer as? Song {
      appDelegate.player.play(context: PlayContext(containable: song))
    } else if let podcastEpisode = playableContainer as? PodcastEpisode,
              let podcast = podcastEpisode.podcast {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPodcastDetail(
          account: account,
          podcast: podcast,
          episodeToScrollTo: podcastEpisode
        ),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let podcast = playableContainer as? Podcast {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPodcastDetail(account: account, podcast: podcast),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let _ = playableContainer as? Radio {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToRadios(account: account),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let genre = playableContainer as? Genre {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToGenreDetail(account: account, genre: genre),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    }
  }
}

extension HomeVC {
  override func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard let containable = dataSource.itemIdentifier(for: indexPath)?.playableContainable
    else { return nil }

    let identifier = NSString(string: TableViewPreviewInfo(
      playableContainerIdentifier: containable.containerIdentifier,
      indexPath: indexPath
    ).asJSONString())
    return UIContextMenuConfiguration(identifier: identifier, previewProvider: {
      let vc = EntityPreviewVC()
      vc.display(container: containable, on: self)
      Task { @MainActor in
        do {
          try await containable.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Preview Sync", error: error)
        }
        vc.refresh()
      }
      return vc
    }) { suggestedActions in
      var playIndexCB: (() -> PlayContext?)?
      playIndexCB = { PlayContext(containable: containable) }
      return EntityPreviewActionBuilder(
        container: containable,
        on: self,
        playContextCb: playIndexCB
      ).createMenu()
    }
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionCommitAnimating
  ) {
    animator.addCompletion {
      if let identifier = configuration.identifier as? String,
         let tvPreviewInfo = TableViewPreviewInfo.create(fromIdentifier: identifier),
         let containerIdentifier = tvPreviewInfo.playableContainerIdentifier,
         let container = self.appDelegate.storage.main.library
         .getContainer(identifier: containerIdentifier) {
        EntityPreviewActionBuilder(container: container, on: self).performPreviewTransition()
      }
    }
  }
}

// MARK: - SectionHeaderView

final class SectionHeaderView: UICollectionReusableView {
  static let reuseID = "SectionHeaderView"

  private let refreshButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.setImage(UIImage.refresh, for: .normal)
    btn.isHidden = true
    btn.accessibilityLabel = "Refresh Randoms"
    return btn
  }()

  private let titleLabel: UILabel = {
    let lbl = ScaledLabel()
    lbl.translatesAutoresizingMaskIntoConstraints = false
    // FireSonic: title 2 bold (Spotify-like section headers) at the default text size, scaled with the user's text size
    let defaultTraits = UITraitCollection(preferredContentSizeCategory: .large)
    let font = UIFont.preferredFont(forTextStyle: .title2, compatibleWith: defaultTraits)
      .withWeight(.bold)
    lbl.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: font)
    lbl.adjustsFontForContentSizeCategory = true
    lbl.textColor = .label
    return lbl
  }()

  var showsRefreshButton: Bool {
    get { !refreshButton.isHidden }
    set { refreshButton.isHidden = !newValue }
  }

  func setRefreshHandler(_ handler: (() -> ())?) {
    refreshButton.removeTarget(nil, action: nil, for: .allEvents)
    guard let handler else { return }
    refreshButton.addAction(UIAction { _ in handler() }, for: .touchUpInside)
  }

  var title: String? {
    didSet { titleLabel.text = title }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(titleLabel)
    addSubview(refreshButton)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: refreshButton.leadingAnchor,
        constant: -8
      ),
      titleLabel.topAnchor.constraint(equalTo: topAnchor),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    addSubview(titleLabel)
    addSubview(refreshButton)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: refreshButton.leadingAnchor,
        constant: -8
      ),
      titleLabel.topAnchor.constraint(equalTo: topAnchor),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
}

extension UIFont {
  fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
    let descriptor = fontDescriptor.addingAttributes([
      UIFontDescriptor.AttributeName.traits: [UIFontDescriptor.TraitKey.weight: weight],
    ])
    return UIFont(descriptor: descriptor, size: pointSize)
  }
}

// MARK: - HomeQuickAccessCell

/// FireSonic: compact tile of the quick access grid at the top of Home (Spotify-like),
/// styled with system materials and Dynamic Type (HIG).
final class HomeQuickAccessCell: UICollectionViewCell {
  static let reuseID = "HomeQuickAccessCell"

  static func tileHeight(for traits: UITraitCollection) -> CGFloat {
    TextScaling.scaledValue(56.0, compatibleWith: traits, maximum: .accessibilityMedium)
  }

  private let artwork = EntityImageView(frame: .zero)
  private let titleLabel: UILabel = {
    let label = UILabel()
    label.font = UIFontMetrics(forTextStyle: .subheadline)
      .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold), maximumPointSize: 22)
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 2
    label.textColor = .label
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    var background = UIBackgroundConfiguration.clear()
    background.backgroundColor = .tertiarySystemFill
    background.cornerRadius = 8
    backgroundConfiguration = background
    contentView.layer.cornerRadius = 8
    contentView.layer.cornerCurve = .continuous
    contentView.clipsToBounds = true

    artwork.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(artwork)
    contentView.addSubview(titleLabel)
    NSLayoutConstraint.activate([
      artwork.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      artwork.topAnchor.constraint(equalTo: contentView.topAnchor),
      artwork.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      artwork.widthAnchor.constraint(equalTo: artwork.heightAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      titleLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 4),
      titleLabel.bottomAnchor.constraint(
        lessThanOrEqualTo: contentView.bottomAnchor,
        constant: -4
      ),
    ])
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.15) {
        self.contentView.alpha = self.isHighlighted ? 0.6 : 1.0
      }
    }
  }

  func display(container: PlayableContainable, theme: ThemePreference) {
    titleLabel.text = container.name
    accessibilityLabel = container.name
    artwork.display(theme: theme, container: container, cornerRadius: .verySmall)
    artwork.layer.cornerRadius = 0
  }
}

// MARK: - HomeRecapCell

/// Blackbox: recap card. Large (story-like, with the cover of the Rückblick plugin) until the
/// recap was opened once, afterwards a compact tile.
final class HomeRecapCell: UICollectionViewCell {
  static let reuseID = "HomeRecapCell"

  private let artwork = EntityImageView(frame: .zero)
  private let gradient = CAGradientLayer()
  private let eyebrowLabel = UILabel()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let pill = UILabel()
  private let textStack = UIStackView()
  private var isLarge = true
  private var largeConstraints: [NSLayoutConstraint] = []
  private var smallConstraints: [NSLayoutConstraint] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.layer.cornerRadius = 20
    contentView.layer.cornerCurve = .continuous
    contentView.clipsToBounds = true
    contentView.backgroundColor = .secondarySystemBackground

    artwork.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(artwork)

    gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.85).cgColor]
    gradient.locations = [0.45, 1.0]
    contentView.layer.addSublayer(gradient)

    eyebrowLabel.font = UIFontMetrics(forTextStyle: .caption1)
      .scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
    eyebrowLabel.adjustsFontForContentSizeCategory = true
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.numberOfLines = 2
    subtitleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
    subtitleLabel.adjustsFontForContentSizeCategory = true

    pill.text = "  Jetzt ansehen ›  "
    pill.font = UIFontMetrics(forTextStyle: .subheadline)
      .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
    pill.adjustsFontForContentSizeCategory = true
    pill.textColor = .black
    pill.backgroundColor = .white
    pill.layer.cornerRadius = 16
    pill.clipsToBounds = true
    pill.textAlignment = .center

    textStack.axis = .vertical
    textStack.spacing = 4
    textStack.alignment = .leading
    [eyebrowLabel, titleLabel, subtitleLabel, pill].forEach { textStack.addArrangedSubview($0) }
    textStack.setCustomSpacing(14, after: subtitleLabel)
    textStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(textStack)

    largeConstraints = [
      artwork.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      artwork.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      artwork.topAnchor.constraint(equalTo: contentView.topAnchor),
      artwork.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
      textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
      pill.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
    ]
    smallConstraints = [
      artwork.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      artwork.topAnchor.constraint(equalTo: contentView.topAnchor),
      artwork.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      artwork.widthAnchor.constraint(equalTo: artwork.heightAnchor),
      textStack.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 12),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -10),
      textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ]
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradient.frame = contentView.bounds
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.15) {
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
      }
    }
  }

  func display(playlist: Playlist, recap: RecapData?, large: Bool, theme: ThemePreference) {
    isLarge = large
    NSLayoutConstraint.deactivate(largeConstraints + smallConstraints)
    NSLayoutConstraint.activate(large ? largeConstraints : smallConstraints)
    gradient.isHidden = !large
    pill.isHidden = !large
    contentView.layer.cornerRadius = large ? 20 : 8
    contentView.backgroundColor = large ? .black : .tertiarySystemFill

    let label = recap?.label ?? playlist.name
    let isYear = recap?.isYear ?? false
    eyebrowLabel.text = (isYear ? "DEIN JAHR IN MUSIK" : "DEIN MONAT IN MUSIK")
    eyebrowLabel.isHidden = !large
    titleLabel.text = large ? label : "Rückblick \(label)"
    let minutes = recap.map { "\($0.minutes.formatted()) Minuten gehört" } ?? ""
    subtitleLabel.text = minutes
    subtitleLabel.isHidden = minutes.isEmpty

    if large {
      eyebrowLabel.textColor = UIColor.white.withAlphaComponent(0.8)
      titleLabel.textColor = .white
      subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.85)
      titleLabel.font = UIFontMetrics(forTextStyle: .largeTitle)
        .scaledFont(for: .systemFont(ofSize: 34, weight: .heavy), maximumPointSize: 48)
    } else {
      titleLabel.textColor = .label
      subtitleLabel.textColor = .secondaryLabel
      titleLabel.font = UIFontMetrics(forTextStyle: .subheadline)
        .scaledFont(for: .systemFont(ofSize: 14, weight: .semibold), maximumPointSize: 22)
      titleLabel.numberOfLines = 1
      subtitleLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
    }
    if large {
      titleLabel.numberOfLines = 2
      subtitleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
    }
    artwork.display(theme: theme, container: playlist, cornerRadius: .verySmall)
    artwork.layer.cornerRadius = 0
    accessibilityLabel = "Rückblick \(label). \(minutes)"
    setNeedsLayout()
  }
}

// MARK: - HomeSongOfTheDayCell

/// Blackbox: "Song des Tages" – Spotify-like feature card: cover, caption, title, artist,
/// add (play next) and a prominent play button.
final class HomeSongOfTheDayCell: UICollectionViewCell {
  static let reuseID = "HomeSongOfTheDayCell"

  var playHandler: (() -> ())?
  var addHandler: (() -> ())?

  private let artwork = EntityImageView(frame: .zero)
  private let captionLabel = UILabel()
  private let titleLabel = UILabel()
  private let artistLabel = UILabel()
  private let addButton = UIButton(type: .system)
  private let playButton = UIButton(type: .system)

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.backgroundColor = .secondarySystemBackground
    contentView.layer.cornerRadius = 14
    contentView.layer.cornerCurve = .continuous
    contentView.clipsToBounds = true

    captionLabel.text = "Song des Tages"
    captionLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
    captionLabel.textColor = .secondaryLabel
    titleLabel.font = UIFontMetrics(forTextStyle: .title3)
      .scaledFont(for: .systemFont(ofSize: 20, weight: .bold), maximumPointSize: 30)
    titleLabel.numberOfLines = 2
    artistLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
    artistLabel.textColor = .secondaryLabel
    [captionLabel, titleLabel, artistLabel].forEach { $0.adjustsFontForContentSizeCategory = true }

    var addConfig = UIButton.Configuration.plain()
    addConfig.image = UIImage(
      systemName: "plus.circle",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
    )
    addConfig.baseForegroundColor = .secondaryLabel
    addButton.configuration = addConfig
    addButton.accessibilityLabel = "Als Nächstes spielen"
    addButton.addAction(UIAction { [weak self] _ in self?.addHandler?() }, for: .touchUpInside)

    var playConfig = UIButton.Configuration.filled()
    playConfig.image = UIImage(
      systemName: "play.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)
    )
    playConfig.baseBackgroundColor = .label
    playConfig.baseForegroundColor = .systemBackground
    playConfig.cornerStyle = .capsule
    playButton.configuration = playConfig
    playButton.accessibilityLabel = "Abspielen"
    playButton.addAction(UIAction { [weak self] _ in self?.playHandler?() }, for: .touchUpInside)

    let textStack = UIStackView(arrangedSubviews: [captionLabel, titleLabel, artistLabel])
    textStack.axis = .vertical
    textStack.spacing = 2
    let buttonRow = UIStackView(arrangedSubviews: [addButton, UIView(), playButton])
    buttonRow.axis = .horizontal
    buttonRow.alignment = .center
    let right = UIStackView(arrangedSubviews: [textStack, UIView(), buttonRow])
    right.axis = .vertical
    right.translatesAutoresizingMaskIntoConstraints = false
    artwork.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(artwork)
    contentView.addSubview(right)
    NSLayoutConstraint.activate([
      artwork.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      artwork.topAnchor.constraint(equalTo: contentView.topAnchor),
      artwork.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      artwork.widthAnchor.constraint(equalTo: artwork.heightAnchor),
      right.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 14),
      right.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      right.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
      right.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      playButton.widthAnchor.constraint(equalToConstant: 44),
      playButton.heightAnchor.constraint(equalToConstant: 44),
      addButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      addButton.heightAnchor.constraint(equalToConstant: 44),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func display(song: Song, theme: ThemePreference) {
    titleLabel.text = song.title
    artistLabel.text = song.creatorName
    artwork.display(theme: theme, container: song, cornerRadius: .verySmall)
    artwork.layer.cornerRadius = 0
    accessibilityLabel = "Song des Tages: \(song.title) von \(song.creatorName)"
  }
}
