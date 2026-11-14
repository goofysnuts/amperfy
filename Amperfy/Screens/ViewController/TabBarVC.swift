//
//  TabBarVC.swift
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
import AVKit
import DominantColors
import Network
import SwiftUI
import UIKit

// MARK: - TabBarVC

class TabBarVC: UITabBarController {
  private var libraryGroup: UITabGroup?
  private var searchTab: UISearchTab?
  private var homeTab: UITab?
  private var playlistsTab: UITab?
  private var settingsTab: UITab?
  private let account: Account

  init(account: Account) {
    self.account = account
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var welcomePopupPresenter = WelcomePopupPresenter()
  var miniPlayer: MiniPlayerView?
  let blackboxMini = BlackboxMiniPlayer()

  override func viewDidLoad() {
    super.viewDidLoad()
    var fixTabs = [UITab]()

    searchTab = UISearchTab { _ in
      UINavigationController(
        rootViewController: TabNavigatorItem.search
          .getController(account: self.account)
      )
    }
    searchTab!.automaticallyActivatesSearch = true

    homeTab = UITab(
      title: TabNavigatorItem.home.title,
      image: TabNavigatorItem.home.icon,
      identifier: "Tabs.\(TabNavigatorItem.home.title)"
    ) { _ in
      UINavigationController(
        rootViewController: TabNavigatorItem.home
          .getController(account: self.account)
      )
    }
    fixTabs.append(homeTab!)

    // all library tabs in the order arranged by the user, the ones not in use are hidden
    let librarySettings = appDelegate.storage.settings.accounts
      .getSetting(account.info).read
      .libraryDisplaySettings
    let libraryTabs = librarySettings.order
      .compactMap { item in
        let tab = UITab(
          title: item.displayName,
          image: item.image,
          identifier: "Tabs.\(item.displayName)"
        ) { tab in
          item.controller(account: self.account, settings: self.appDelegate.storage.settings)
        }
        tab.allowsHiding = true
        tab.isHiddenByDefault = !librarySettings.isVisible(libraryType: item)
        return tab
      }

    libraryGroup = UITabGroup(
      title: T("Library"),
      image: .musicLibrary,
      identifier: "Tabs.Library",
      children: libraryTabs
    ) { tab in
      AppStoryboard.Main.segueToLibrary(account: self.account)
    }
    libraryGroup!.managingNavigationController = UINavigationController()
    libraryGroup!.allowsReordering = true
    fixTabs.append(libraryGroup!)

    // FireSonic: tab bar like Apple Music – Home, Library, Playlists, Settings and the
    // separate search button (UISearchTab is placed at the trailing end by the system)
    playlistsTab = UITab(
      title: T("Playlists"),
      image: .playlist,
      identifier: "Tabs.FireSonic.Playlists"
    ) { _ in
      UINavigationController(
        rootViewController: AppStoryboard.Main.segueToPlaylists(account: self.account)
      )
    }
    fixTabs.append(playlistsTab!)

    settingsTab = UITab(
      title: T("Settings"),
      image: .settings,
      identifier: "Tabs.FireSonic.Settings"
    ) { _ in
      AppStoryboard.Main.segueToSettings()
    }
    fixTabs.append(settingsTab!)

    fixTabs.append(searchTab!)

    delegate = self
    tabs = fixTabs

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleLibraryItemsChanged(notification:)),
      name: .LibraryItemsChanged,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAutoCollapseToolbarPlayer(notification:)),
      name: .autoCollapseToolbarPlayerChanged,
      object: nil
    )

    // Blackbox: Mini-Player und Tab-Leiste beim Scrollen nicht verkleinern
    tabBarMinimizeBehavior = .never

    miniPlayer = MiniPlayerView(player: appDelegate.player)
    miniPlayer!.configureForiOS()
    // Blackbox: own mini player (larger, progress ring around the play button, FireTV remote)
    blackboxMini.translatesAutoresizingMaskIntoConstraints = false

    let accessory = UITabAccessory(contentView: blackboxMini)
    bottomAccessory = accessory

    heightConstraint = blackboxMini.heightAnchor.constraint(equalToConstant: 48.0)
    heightConstraint?.isActive = true
    compactWidthConstraint = blackboxMini.widthAnchor
      .constraint(equalTo: blackboxMini.superview!.widthAnchor)

    blackboxMini.traitChangeCB = { [weak self] in self?.configureTraitChangesForMiniPlayer() }
    configureTraitChangesForMiniPlayer()
    if PlayQueueSync.isEnabled { PlayQueueSync.shared.start() }

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.miniPlayer?
          .refreshForTraitChange(horizontalSizeClass: self.traitCollection.horizontalSizeClass)
        self.configureTraitChangesForMiniPlayer()
      }
    )

    if appDelegate.storage.settings.user.isOfflineMode {
      appDelegate.eventLogger.info(topic: "Reminder", message: T("Offline Mode is active."))
    }
  }

  private func mainContent() -> UIView {
    // Attempt to find the main content view controller's view if the sidebar is visible.
    // Fallback to self.view.safeAreaLayoutGuide.leadingAnchor otherwise.
    if traitCollection.horizontalSizeClass == .regular, let selectedViewController {
      return selectedViewController.view
    }
    return view
  }

  var centerConstraint: NSLayoutConstraint?
  var regularWidthConstraint: NSLayoutConstraint?
  var heightConstraint: NSLayoutConstraint?
  var compactWidthConstraint: NSLayoutConstraint?

  func configureTraitChangesForMiniPlayer() {
    let container: UIView = blackboxMini
    guard container.superview != nil else { return }
    let isInline = container.traitCollection.tabAccessoryEnvironment == .inline

    if traitCollection.horizontalSizeClass == .regular {
      centerConstraint = container.safeAreaLayoutGuide.centerXAnchor.constraint(
        equalTo: mainContent().safeAreaLayoutGuide.centerXAnchor,
        constant: 0
      )
      let mainContentView = mainContent()
      var playerWidth = mainContentView.frame.width - mainContentView.safeAreaInsets
        .left - mainContentView.safeAreaInsets.right
      playerWidth = min(playerWidth, 600)
      compactWidthConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      regularWidthConstraint = container.widthAnchor
        .constraint(equalToConstant: playerWidth)
      regularWidthConstraint?.isActive = true
      centerConstraint?.isActive = true
      heightConstraint?.constant = 60.0
    } else if isInline {
      heightConstraint?.constant = 44.0
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
    } else {
      // Standardhöhe des Tab-Zubehörs – größer rückt der Mini-Player zu nah an die Tab-Leiste
      heightConstraint?.constant = 48.0
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
    }

    container.setNeedsLayout()
    container.layoutIfNeeded()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    configureTraitChangesForMiniPlayer()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    refresh()
    selectedTab = homeTab
    welcomePopupPresenter.displayInfoPopupsIfNeeded()
  }

  @objc
  func handleLibraryItemsChanged(notification: Notification) {
    refresh()
  }

  @objc
  func handleAutoCollapseToolbarPlayer(notification: Notification) {
    // Blackbox: Mini-Player bleibt immer in voller Größe
    tabBarMinimizeBehavior = .never
  }

  func refresh() {
    guard let libraryGroup else { return }
    let config = appDelegate.storage.settings.accounts.getSetting(account.info).read
      .libraryDisplaySettings
    libraryGroup.displayOrderIdentifiers = config.order.compactMap { "Tabs.\($0.displayName)" }
    for tab in libraryGroup.displayOrder {
      guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
      if let _ = config.inUse.first(where: { $0 == item }) {
        tab.isHidden = false
      } else {
        tab.isHidden = true
      }
    }
  }

  public func push(vc: UIViewController) {
    guard let libraryGroup else { return }
    // Select the library first: changing the selection rebuilds the managed navigation stack,
    // which would otherwise drop a view controller pushed beforehand (no back button).
    if selectedTab?.managingTabGroup !== libraryGroup, selectedTab !== libraryGroup {
      selectedTab = libraryGroup
    }
    libraryGroup.managingNavigationController?.pushViewController(vc, animated: true)
  }
}

// MARK: UITabBarControllerDelegate

extension TabBarVC: UITabBarControllerDelegate {
  func tabBarControllerDidEndEditing(_ tabBarController: UITabBarController) {
    var order = [LibraryDisplayType]()
    var visibleItems = Set<LibraryDisplayType>()
    guard let libraryGroup else { return }
    // display order contains the hidden tabs too -> keep their position
    for tab in libraryGroup.displayOrder {
      guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
      order.append(item)
      if !tab.isHidden {
        visibleItems.insert(item)
      }
    }
    appDelegate.storage.settings.accounts
      .updateSetting(account.info) { accountSettings in
        accountSettings.libraryDisplaySettings = LibraryDisplaySettings(
          order: order,
          inUse: visibleItems
        )
      }
    NotificationCenter.default.post(name: .LibraryItemsChanged, object: nil, userInfo: nil)
  }
}

// MARK: MainSceneHostingViewController

extension TabBarVC: MainSceneHostingViewController {
  public func pushNavLibrary(vc: UIViewController) {
    push(vc: vc)
  }

  public func pushLibraryCategory(vc: UIViewController) {
    guard let libraryGroup else { return }
    libraryGroup.managingNavigationController?.popToRootViewController(animated: false)
    push(vc: vc)
  }

  func pushTabCategory(tabCategory: TabNavigatorItem) {
    switch tabCategory {
    case .home:
      selectedTab = homeTab
    case .search:
      selectedTab = searchTab
    }
    configureTraitChangesForMiniPlayer()
  }

  func displaySearch() {
    guard let searchTab else { return }
    visualizePopupPlayer(direction: .close, animated: true) {
      self.selectedTab = searchTab
      searchTab.viewController?.navigationController?.popToRootViewController(animated: false)
      Task {
        try await Task.sleep(nanoseconds: 500_000_000)
        if let searchTabVC = searchTab.viewController?.navigationController?
          .topViewController as? SearchVC {
          searchTabVC.activateSearchBar()
        }
      }
    }
  }

  func getSafeAreaExtension() -> CGFloat {
    0.0
  }
}

// MARK: - FireTV remote (Blackbox)

/// Status reported by Blackbox on the FireTV (HTTP server in the TV app, port 47321,
/// announced via Bonjour/NSD as "_blackbox._tcp").
struct FireTVStatus: Decodable, Sendable {
  let name: String?
  let playing: Bool
  let position: Double
  let duration: Double
  let title: String?
  let artist: String?
  let album: String?
  let coverArt: String?
  let songId: String?
  let queueIndex: Int?
  let queueLength: Int?
  let shuffle: Bool?
  let repeatMode: Int?
  let queue: [FireTVQueueEntry]?
}

struct FireTVQueueEntry: Decodable, Sendable, Hashable {
  let index: Int
  let id: String
  let title: String
  let artist: String
  let coverArt: String?
}

@MainActor
final class FireTVClient {
  static let defaultPort = 47321
  private static let hostKey = "blackbox.remote.host"

  static var savedHost: String? {
    get { UserDefaults.standard.string(forKey: hostKey) }
    set { UserDefaults.standard.set(newValue, forKey: hostKey) }
  }

  let baseURL: URL

  init?(host: String) {
    var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if !h.hasPrefix("http://"), !h.hasPrefix("https://") { h = "http://" + h }
    guard var comps = URLComponents(string: h) else { return nil }
    if comps.port == nil { comps.port = Self.defaultPort }
    guard let url = comps.url else { return nil }
    baseURL = url
  }

  private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
    var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { comps.queryItems = query }
    var req = URLRequest(url: comps.url!)
    req.httpMethod = method
    req.timeoutInterval = 4
    if let body {
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return data
  }

  func status() async throws -> FireTVStatus {
    try JSONDecoder().decode(FireTVStatus.self, from: try await request("status"))
  }

  func control(_ action: String, value: Double? = nil) async throws {
    var q = [URLQueryItem(name: "action", value: action)]
    if let value { q.append(URLQueryItem(name: "value", value: String(value))) }
    _ = try await request("control", method: "POST", query: q)
  }

  func playQueue(songIds: [String], index: Int, position: Double, shuffle: Bool = false) async throws {
    let body = try JSONSerialization.data(withJSONObject: [
      "songIds": songIds, "index": index, "position": position, "shuffle": shuffle,
    ])
    _ = try await request("queue", method: "POST", body: body)
  }

  func enqueue(songIds: [String], next: Bool) async throws {
    let body = try JSONSerialization.data(withJSONObject: ["songIds": songIds, "next": next])
    _ = try await request("enqueue", method: "POST", body: body)
  }
}

/// Finds Blackbox FireTVs in the local network and resolves them to "ip:port".
@MainActor
final class FireTVBrowser {
  struct Device: Hashable {
    let name: String
    let endpoint: NWEndpoint
  }

  var onChange: (([Device]) -> ())?
  private var browser: NWBrowser?

  func start() {
    let params = NWParameters.tcp
    let browser = NWBrowser(for: .bonjour(type: "_blackbox._tcp", domain: nil), using: params)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let devices = results.compactMap { result -> Device? in
        if case let .service(name, _, _, _) = result.endpoint {
          return Device(name: name, endpoint: result.endpoint)
        }
        return nil
      }
      Task { @MainActor in self?.onChange?(devices) }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  func stop() {
    browser?.cancel()
    browser = nil
  }

  /// Opens a short TCP connection to learn the IPv4 address of the service.
  static func resolve(_ endpoint: NWEndpoint) async -> String? {
    let params = NWParameters.tcp
    if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
      ip.version = .v4
    }
    let connection = NWConnection(to: endpoint, using: params)
    return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
      let box = ResumeOnce(cont)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          var result: String?
          if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
            var h = "\(host)"
            if let percent = h.firstIndex(of: "%") { h = String(h[..<percent]) }
            result = "\(h):\(port.rawValue)"
          }
          connection.cancel()
          box.resume(result)
        case .failed, .cancelled:
          box.resume(nil)
        default:
          break
        }
      }
      connection.start(queue: .global())
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        connection.cancel()
        box.resume(nil)
      }
    }
  }

  private final class ResumeOnce: @unchecked Sendable {
    private var cont: CheckedContinuation<String?, Never>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<String?, Never>) { self.cont = cont }
    func resume(_ value: String?) {
      lock.lock()
      let c = cont
      cont = nil
      lock.unlock()
      c?.resume(returning: value)
    }
  }
}

/// Remote control for Blackbox on the FireTV: now playing, transport controls, seek and
/// "send what's playing on the iPhone to the TV".
final class FireTVRemoteVC: UIViewController {
  private var client: FireTVClient?
  private let browser = FireTVBrowser()
  private var devices: [FireTVBrowser.Device] = []
  private var pollTask: Task<(), Never>?
  private var status: FireTVStatus?
  private var isScrubbing = false
  private var lastCover: String?

  private let deviceButton = UIButton(type: .system)
  private let coverView = UIImageView()
  private let titleLabel = UILabel()
  private let artistLabel = UILabel()
  private let slider = UISlider()
  private let elapsedLabel = UILabel()
  private let remainingLabel = UILabel()
  private let prevButton = UIButton(type: .system)
  private let playButton = UIButton(type: .system)
  private let nextButton = UIButton(type: .system)
  private let transferButton = UIButton(type: .system)
  private let hintLabel = UILabel()

  private var appDelegateRef: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "FireTV"
    view.backgroundColor = .systemBackground
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .done,
      primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
    )
    buildUI()
    if let host = FireTVClient.savedHost { connect(host: host, name: nil) } else { updateDeviceMenu() }
    browser.onChange = { [weak self] found in
      guard let self else { return }
      devices = found
      updateDeviceMenu()
      if client == nil, let first = found.first { select(device: first) }
    }
    browser.start()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startPolling()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    pollTask?.cancel()
    pollTask = nil
    browser.stop()
  }

  private func symbolButton(_ button: UIButton, _ name: String, size: CGFloat, label: String) {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: name,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
    )
    config.baseForegroundColor = .label
    button.configuration = config
    button.accessibilityLabel = label
  }

  private func buildUI() {
    var deviceConfig = UIButton.Configuration.gray()
    deviceConfig.image = UIImage(systemName: "tv")
    deviceConfig.imagePadding = 8
    deviceConfig.title = T("FireTV suchen …")
    deviceConfig.cornerStyle = .capsule
    deviceButton.configuration = deviceConfig
    deviceButton.showsMenuAsPrimaryAction = true

    coverView.contentMode = .scaleAspectFill
    coverView.clipsToBounds = true
    coverView.layer.cornerRadius = 14
    coverView.layer.cornerCurve = .continuous
    coverView.backgroundColor = .secondarySystemFill
    coverView.image = UIImage(systemName: "music.note")
    coverView.tintColor = .tertiaryLabel

    titleLabel.font = UIFontMetrics(forTextStyle: .title2)
      .scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 2
    artistLabel.font = UIFont.preferredFont(forTextStyle: .body)
    artistLabel.adjustsFontForContentSizeCategory = true
    artistLabel.textColor = .secondaryLabel
    artistLabel.textAlignment = .center

    slider.addTarget(self, action: #selector(scrubStart), for: .touchDown)
    slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
    [elapsedLabel, remainingLabel].forEach {
      $0.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
      $0.textColor = .secondaryLabel
    }
    remainingLabel.textAlignment = .right

    symbolButton(prevButton, "backward.fill", size: 28, label: T("Zurück"))
    symbolButton(playButton, "play.fill", size: 40, label: T("Wiedergabe"))
    symbolButton(nextButton, "forward.fill", size: 28, label: T("Weiter"))
    prevButton.addAction(UIAction { [weak self] _ in self?.send("previous") }, for: .touchUpInside)
    playButton.addAction(UIAction { [weak self] _ in self?.send("toggle") }, for: .touchUpInside)
    nextButton.addAction(UIAction { [weak self] _ in self?.send("next") }, for: .touchUpInside)

    var transferConfig = UIButton.Configuration.filled()
    transferConfig.title = T("iPhone-Wiedergabe auf FireTV übertragen")
    transferConfig.image = UIImage(systemName: "arrow.up.right.square")
    transferConfig.imagePadding = 8
    transferConfig.cornerStyle = .capsule
    transferConfig.buttonSize = .large
    transferButton.configuration = transferConfig
    transferButton.addAction(UIAction { [weak self] _ in self?.transfer() }, for: .touchUpInside)

    hintLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
    hintLabel.textColor = .secondaryLabel
    hintLabel.numberOfLines = 0
    hintLabel.textAlignment = .center
    hintLabel.text = T("Der FireTV muss an sein (FireLauncher) oder Blackbox geöffnet (gleiches WLAN).")

    let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, remainingLabel])
    timeRow.distribution = .fillEqually
    let controls = UIStackView(arrangedSubviews: [prevButton, playButton, nextButton])
    controls.distribution = .equalCentering
    controls.alignment = .center
    let stack = UIStackView(arrangedSubviews: [
      deviceButton, coverView, titleLabel, artistLabel, slider, timeRow, controls, transferButton, hintLabel,
    ])
    stack.axis = .vertical
    stack.spacing = 14
    stack.alignment = .fill
    stack.setCustomSpacing(24, after: deviceButton)
    stack.setCustomSpacing(20, after: coverView)
    stack.setCustomSpacing(4, after: titleLabel)
    stack.setCustomSpacing(22, after: artistLabel)
    stack.setCustomSpacing(26, after: controls)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
      coverView.heightAnchor.constraint(equalTo: coverView.widthAnchor),
      controls.heightAnchor.constraint(equalToConstant: 64),
    ])
    render()
  }

  // MARK: Devices

  private func updateDeviceMenu() {
    var actions: [UIMenuElement] = devices.map { device in
      UIAction(title: device.name, image: UIImage(systemName: "tv")) { [weak self] _ in
        self?.select(device: device)
      }
    }
    actions.append(UIAction(title: T("IP-Adresse eingeben …"), image: UIImage(systemName: "keyboard")) { [weak self] _ in
      self?.askForHost()
    })
    deviceButton.menu = UIMenu(title: T("FireTV wählen"), children: actions)
  }

  private func select(device: FireTVBrowser.Device) {
    Task { @MainActor in
      guard let host = await FireTVBrowser.resolve(device.endpoint) else {
        appDelegateRef.eventLogger.info(topic: "FireTV", message: T("„\(device.name)“ ist nicht erreichbar."))
        return
      }
      connect(host: host, name: device.name)
    }
  }

  private func askForHost() {
    let alert = UIAlertController(
      title: T("FireTV-Adresse"),
      message: T("IP-Adresse des FireTV, z. B. 192.168.30.21"),
      preferredStyle: .alert
    )
    alert.addTextField {
      $0.keyboardType = .numbersAndPunctuation
      $0.text = FireTVClient.savedHost
    }
    alert.addAction(UIAlertAction(title: T("Abbrechen"), style: .cancel))
    alert.addAction(UIAlertAction(title: T("Verbinden"), style: .default) { [weak self, weak alert] _ in
      guard let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
      self?.connect(host: text, name: nil)
    })
    present(alert, animated: true)
  }

  private func connect(host: String, name: String?) {
    guard let c = FireTVClient(host: host) else { return }
    client = c
    FireTVClient.savedHost = host
    var config = deviceButton.configuration
    config?.title = name ?? host
    deviceButton.configuration = config
    updateDeviceMenu()
    startPolling()
  }

  // MARK: Status

  private func startPolling() {
    pollTask?.cancel()
    guard client != nil, view.window != nil else { return }
    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  private func refresh() async {
    guard let client else { return }
    do {
      status = try await client.status()
      hintLabel.text = T("Verbunden")
    } catch {
      status = nil
      hintLabel.text = T("FireTV nicht erreichbar – ist er an und im selben WLAN?")
    }
    render()
  }

  private static func time(_ sec: Double) -> String {
    let s = max(0, Int(sec.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  private func render() {
    let s = status
    titleLabel.text = s?.title ?? "Nichts wird abgespielt"
    artistLabel.text = s?.artist ?? " "
    let enabled = client != nil && s != nil
    [prevButton, playButton, nextButton, slider].forEach { $0.isEnabled = enabled }
    symbolButton(playButton, (s?.playing ?? false) ? "pause.fill" : "play.fill", size: 40, label: (s?.playing ?? false) ? "Pause" : "Wiedergabe")
    if !isScrubbing {
      slider.maximumValue = Float(max(1, s?.duration ?? 1))
      slider.value = Float(s?.position ?? 0)
      elapsedLabel.text = Self.time(s?.position ?? 0)
      remainingLabel.text = "-" + Self.time((s?.duration ?? 0) - (s?.position ?? 0))
    }
    transferButton.isEnabled = client != nil && appDelegateRef.player.currentlyPlaying != nil
    if s?.coverArt != lastCover {
      lastCover = s?.coverArt
      if let cover = s?.coverArt, let info = appDelegateRef.storage.settings.accounts.active {
        Task { @MainActor [weak self] in
          let image = await PlaylistCoverLoader.shared.image(coverArtId: cover, accountInfo: info)
          guard let self, self.lastCover == cover, let image else { return }
          UIView.transition(with: self.coverView, duration: 0.3, options: .transitionCrossDissolve) {
            self.coverView.image = image
          }
        }
      } else {
        coverView.image = UIImage(systemName: "music.note")
      }
    }
  }

  private func send(_ action: String, value: Double? = nil) {
    guard let client else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task { @MainActor in
      try? await client.control(action, value: value)
      await refresh()
    }
  }

  @objc
  private func scrubStart() { isScrubbing = true }

  @objc
  private func scrubChanged() {
    elapsedLabel.text = Self.time(Double(slider.value))
    remainingLabel.text = "-" + Self.time(Double(slider.maximumValue - slider.value))
  }

  @objc
  private func scrubEnd() {
    isScrubbing = false
    send("seek", value: Double(slider.value))
  }

  private func transfer() {
    guard let client else { return }
    let player = appDelegateRef.player
    guard let current = player.currentlyPlaying else { return }
    let prev = player.getAllPrevQueueItems().suffix(100)
    let next = player.getAllUserQueueItems() + player.getAllNextQueueItems()
    let ids = (prev.map(\.id) + [current.id] + next.prefix(200).map(\.id))
    let index = prev.count
    let position = player.elapsedTime
    Task { @MainActor in
      do {
        try await client.playQueue(songIds: ids, index: index, position: position)
        player.pause()
        appDelegateRef.eventLogger.info(topic: "FireTV", message: T("Wiedergabe läuft jetzt auf dem FireTV."))
        await refresh()
      } catch {
        appDelegateRef.eventLogger.info(topic: "FireTV", message: T("Übertragung fehlgeschlagen."))
      }
    }
  }
}

// MARK: - RemoteSession (Blackbox)

/// Connection to Blackbox on the FireTV. While connected the iPhone works like a remote:
/// every playback command of the app is redirected to the TV (see `PlayerRemote`).
@MainActor
final class RemoteSession: PlayerRemoteRedirect {
  static let shared = RemoteSession()
  static let changedNotification = Notification.Name("de.jannes.blackbox.remoteChanged")

  private(set) var client: FireTVClient?
  private(set) var deviceName: String?
  private(set) var status: FireTVStatus?
  private var pollTask: Task<(), Never>?
  private var appDelegateRef: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

  var isRemoteActive: Bool { client != nil }

  func connect(host: String, name: String?) {
    guard let c = FireTVClient(host: host) else { return }
    client = c
    deviceName = name ?? host
    FireTVClient.savedHost = host
    PlayerRemote.redirect = self
    // the iPhone only works as a remote now
    if appDelegateRef.player.isPlaying {
      PlayerRemote.redirect = nil
      appDelegateRef.player.pause()
      PlayerRemote.redirect = self
    }
    startPolling()
    post()
  }

  func disconnect() {
    pollTask?.cancel()
    pollTask = nil
    client = nil
    status = nil
    deviceName = nil
    PlayerRemote.redirect = nil
    post()
  }

  private func post() {
    NotificationCenter.default.post(name: Self.changedNotification, object: nil)
  }

  private func startPolling() {
    pollTask?.cancel()
    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  func refresh() async {
    guard let client else { return }
    status = try? await client.status()
    post()
  }

  /// Transfers what plays on the iPhone to the TV
  func transferLocalPlayback() {
    let player = appDelegateRef.player
    guard let client, let current = player.currentlyPlaying else { return }
    let prev = player.getAllPrevQueueItems().suffix(100)
    let next = player.getAllUserQueueItems() + player.getAllNextQueueItems()
    let ids = prev.map(\.id) + [current.id] + next.prefix(200).map(\.id)
    let position = player.elapsedTime
    Task { @MainActor in
      try? await client.playQueue(songIds: ids, index: prev.count, position: position)
      await refresh()
    }
  }

  // MARK: PlayerRemoteRedirect

  func remotePlay(playables: [AbstractPlayable], index: Int, shuffle: Bool) {
    guard let client else { return }
    let ids = playables.prefix(500).map(\.id)
    guard !ids.isEmpty else { return }
    Task { @MainActor in
      do {
        try await client.playQueue(songIds: ids, index: min(index, ids.count - 1), position: 0, shuffle: shuffle)
      } catch {
        appDelegateRef.eventLogger.info(topic: "FireTV", message: T("Wiedergabe auf dem FireTV fehlgeschlagen."))
      }
      await refresh()
    }
  }

  func remoteEnqueue(playables: [AbstractPlayable], next: Bool) {
    guard let client else { return }
    let ids = playables.prefix(500).map(\.id)
    Task { @MainActor in
      try? await client.enqueue(songIds: ids, next: next)
      await refresh()
    }
  }

  func remoteCommand(_ action: String, value: Double?) {
    guard let client else { return }
    Task { @MainActor in
      try? await client.control(action, value: value)
      await refresh()
    }
  }
}

// MARK: - Now playing (local or remote)

@MainActor
struct BlackboxNowPlaying {
  var title: String
  var artist: String
  var song: Song?
  var playable: AbstractPlayable?
  var coverArtId: String?
  var isPlaying: Bool
  var position: Double
  var duration: Double
  var isShuffle: Bool
  var repeatMode: RepeatMode
  var isRemote: Bool
  var hasItem: Bool

  static func current() -> BlackboxNowPlaying {
    let delegate = UIApplication.shared.delegate as! AppDelegate
    let player = delegate.player
    let remote = RemoteSession.shared
    if remote.isRemoteActive {
      let s = remote.status
      var song: Song?
      if let id = s?.songId, let info = delegate.storage.settings.accounts.active {
        let account = delegate.storage.main.library.getAccount(info: info)
        song = delegate.storage.main.library.getSong(for: account, id: id)
      }
      return BlackboxNowPlaying(
        title: s?.title ?? "Nichts wird abgespielt",
        artist: s.map { _ in s?.artist ?? "" } ?? "Verbinde mit \(remote.deviceName ?? "FireTV") …",
        song: song,
        playable: song,
        coverArtId: s?.coverArt,
        isPlaying: s?.playing ?? false,
        position: s?.position ?? 0,
        duration: s?.duration ?? 0,
        isShuffle: s?.shuffle ?? false,
        // Media3 on the FireTV: 0 = off, 1 = one, 2 = all
        repeatMode: { switch s?.repeatMode ?? 0 { case 1: return RepeatMode.single; case 2: return .all; default: return .off } }(),
        isRemote: true,
        hasItem: s?.title != nil
      )
    }
    let cur = player.currentlyPlaying
    return BlackboxNowPlaying(
      title: cur?.title ?? "Nichts wird abgespielt",
      artist: cur?.creatorName ?? "",
      song: cur?.asSong,
      playable: cur,
      coverArtId: nil,
      isPlaying: player.isPlaying,
      position: player.elapsedTime,
      duration: player.duration,
      isShuffle: player.isShuffle,
      repeatMode: player.repeatMode,
      isRemote: false,
      hasItem: cur != nil
    )
  }

  /// Artwork: local cache first, then the server cover (remote)
  func loadArtwork(_ completion: @escaping @MainActor (UIImage?) -> ()) {
    let delegate = UIApplication.shared.delegate as! AppDelegate
    if let playable, let info = playable.account?.info {
      let setting = delegate.storage.settings.accounts.getSetting(info).read
      let image = LibraryEntityImage.getImageToDisplayImmediately(
        libraryEntity: playable,
        themePreference: setting.themePreference,
        artworkDisplayPreference: setting.artworkDisplayPreference,
        useCache: true
      )
      if let artwork = playable.artwork {
        delegate.getMeta(info).artworkDownloadManager.download(object: artwork)
      }
      // noch nicht lokal geladen -> erst Platzhalter, dann das Cover direkt vom Server
      let artworkCached = playable.artwork?.isCached ?? false
      if coverArtId == nil {
        completion(image)
        let remoteId = playable.artwork?.id ?? playable.asSong?.album?.artwork?.id
        if !artworkCached, let remoteId, !remoteId.isEmpty {
          Task { @MainActor in
            if let remote = await PlaylistCoverLoader.shared.image(coverArtId: remoteId, accountInfo: info) {
              completion(remote)
            }
          }
        }
        return
      }
    }
    guard let coverArtId, let info = delegate.storage.settings.accounts.active else {
      completion(nil)
      return
    }
    Task { @MainActor in
      completion(await PlaylistCoverLoader.shared.image(coverArtId: coverArtId, accountInfo: info))
    }
  }
}

// MARK: - BlackboxMiniPlayer

/// Mini player in the tab bar accessory: artwork, title/artist, play button with circular
/// progress ring and next. Shows the FireTV while it is controlled remotely.
final class BlackboxMiniPlayer: UIView, MusicPlayable {
  private let artwork = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let playButton = UIButton(type: .system)
  private let nextButton = UIButton(type: .system)
  private let ringTrack = CAShapeLayer()
  private let ring = CAShapeLayer()
  private let ringHost = UIView()
  private var timer: Timer?
  private var lastArtworkKey: String?
  private var appDelegateRef: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

  override init(frame: CGRect) {
    super.init(frame: frame)
    artwork.contentMode = .scaleAspectFill
    artwork.clipsToBounds = true
    artwork.layer.cornerRadius = 8
    artwork.layer.cornerCurve = .continuous
    artwork.backgroundColor = .tertiarySystemFill

    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    subtitleLabel.font = .systemFont(ofSize: 13)
    subtitleLabel.textColor = .secondaryLabel

    var playConfig = UIButton.Configuration.plain()
    playConfig.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
    playConfig.baseForegroundColor = .label
    playButton.configuration = playConfig
    playButton.accessibilityLabel = T("Wiedergabe")
    playButton.addAction(UIAction { [weak self] _ in self?.appDelegateRef.player.togglePlayPause() }, for: .touchUpInside)

    var nextConfig = UIButton.Configuration.plain()
    nextConfig.image = UIImage(systemName: "forward.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
    nextConfig.baseForegroundColor = .label
    nextButton.configuration = nextConfig
    nextButton.accessibilityLabel = T("Weiter")
    nextButton.addAction(UIAction { [weak self] _ in self?.appDelegateRef.player.playNext() }, for: .touchUpInside)

    ringHost.isUserInteractionEnabled = false
    ringTrack.fillColor = UIColor.clear.cgColor
    ringTrack.lineWidth = 2.5
    ring.fillColor = UIColor.clear.cgColor
    ring.lineWidth = 2.5
    ring.lineCap = .round
    ring.strokeEnd = 0
    ringHost.layer.addSublayer(ringTrack)
    ringHost.layer.addSublayer(ring)

    let texts = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    texts.axis = .vertical
    texts.spacing = 1
    [artwork, texts, ringHost, playButton, nextButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }
    NSLayoutConstraint.activate([
      artwork.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      artwork.centerYAnchor.constraint(equalTo: centerYAnchor),
      artwork.heightAnchor.constraint(equalTo: heightAnchor, constant: -14),
      artwork.widthAnchor.constraint(equalTo: artwork.heightAnchor),
      texts.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
      texts.centerYAnchor.constraint(equalTo: centerYAnchor),
      texts.trailingAnchor.constraint(lessThanOrEqualTo: playButton.leadingAnchor, constant: -6),
      nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      nextButton.widthAnchor.constraint(equalToConstant: 40),
      nextButton.heightAnchor.constraint(equalToConstant: 40),
      playButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -2),
      playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      playButton.widthAnchor.constraint(equalToConstant: 40),
      playButton.heightAnchor.constraint(equalToConstant: 40),
      ringHost.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
      ringHost.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
      ringHost.widthAnchor.constraint(equalToConstant: 36),
      ringHost.heightAnchor.constraint(equalToConstant: 36),
    ])
    let tap = UITapGestureRecognizer(target: self, action: #selector(openPlayer))
    addGestureRecognizer(tap)
    isAccessibilityElement = false

    appDelegateRef.player.addNotifier(notifier: self)
    NotificationCenter.default.addObserver(self, selector: #selector(remoteChanged), name: RemoteSession.changedNotification, object: nil)
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshProgress() }
    }
    refresh()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let path = UIBezierPath(
      arcCenter: CGPoint(x: 18, y: 18),
      radius: 16.5,
      startAngle: -.pi / 2,
      endAngle: 1.5 * .pi,
      clockwise: true
    ).cgPath
    ringTrack.path = path
    ring.path = path
  }

  var traitChangeCB: (() -> ())?

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    subtitleLabel.isHidden = traitCollection.tabAccessoryEnvironment == .inline
    refreshColors()
    traitChangeCB?()
  }

  private func refreshColors() {
    ringTrack.strokeColor = UIColor.label.withAlphaComponent(0.18).resolvedColor(with: traitCollection).cgColor
    ring.strokeColor = tintColor.resolvedColor(with: traitCollection).cgColor
  }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    refreshColors()
  }

  @objc
  private func openPlayer() {
    BlackboxPlayerVC.present()
  }

  @objc
  private func remoteChanged() { refresh() }

  func refresh() {
    let np = BlackboxNowPlaying.current()
    titleLabel.text = np.title
    var sub = np.artist
    if np.isRemote { sub = "📺 " + (RemoteSession.shared.deviceName ?? "FireTV") + (sub.isEmpty ? "" : " · " + sub) }
    subtitleLabel.text = sub
    var config = playButton.configuration
    config?.image = UIImage(
      systemName: np.isPlaying ? "pause.fill" : "play.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)
    )
    playButton.configuration = config
    playButton.accessibilityLabel = np.isPlaying ? "Pause" : "Wiedergabe"
    refreshColors()
    refreshProgress(np)
    let key = (np.coverArtId ?? "") + (np.playable?.id ?? "")
    if key != lastArtworkKey {
      lastArtworkKey = key
      np.loadArtwork { [weak self] image in
        guard let self, self.lastArtworkKey == key else { return }
        self.artwork.image = image
      }
    }
  }

  private func refreshProgress(_ given: BlackboxNowPlaying? = nil) {
    let np = given ?? BlackboxNowPlaying.current()
    let value = np.duration > 0 ? CGFloat(np.position / np.duration) : 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.strokeEnd = max(0, min(1, value))
    CATransaction.commit()
  }

  // MARK: MusicPlayable
  func didStartPlayingFromBeginning() { refresh() }
  func didStartPlaying() { refresh() }
  func didPause() { refresh() }
  func didStopPlaying() { refresh() }
  func didElapsedTimeChange() { refreshProgress() }
  func didPlaylistChange() { refresh() }
  func didArtworkChange() { lastArtworkKey = nil; refresh() }
  func didShuffleChange() {}
  func didRepeatChange() {}
  func didPlaybackRateChange() {}
}

// MARK: - BlackboxPlayerVC

/// Full screen player (edge to edge, background from the cover colors).
/// Works for the local player and – while connected – for the FireTV.
final class BlackboxPlayerVC: UIViewController, MusicPlayable, RatingViewDelegate {
  static func present() {
    guard let host = AppDelegate.mainWindowHostVC as? UIViewController else { return }
    var top: UIViewController = host
    while let presented = top.presentedViewController { top = presented }
    if top is BlackboxPlayerVC { return }
    let vc = BlackboxPlayerVC()
    // overFullScreen: die Ansicht darunter bleibt erhalten -> nach dem Schließen ist man wieder dort, wo man war
    vc.modalPresentationStyle = .overFullScreen
    top.present(vc, animated: true)
  }

  private let gradient = CAGradientLayer()
  private let scroll = UIScrollView()
  private let remoteBadge = UILabel()
  private let coverView = UIImageView()
  private let titleLabel = UILabel()
  private let artistLabel = UILabel()
  private let favoriteButton = UIButton(type: .system)
  private let ratingView = RatingView()
  private let optionsButton = UIButton(type: .system)
  private let slider = UISlider()
  private let elapsedLabel = UILabel()
  private let remainingLabel = UILabel()
  private let audioInfoLabel = UILabel()
  private let shuffleButton = UIButton(type: .system)
  private let prevButton = UIButton(type: .system)
  private let playButton = UIButton(type: .system)
  private let nextButton = UIButton(type: .system)
  private let repeatButton = UIButton(type: .system)
  private let devicesButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)
  private let lyricsButton = UIButton(type: .system)
  private let queueButton = UIButton(type: .system)
  private let sleepButton = UIButton(type: .system)

  private var isScrubbing = false
  private var lastArtworkKey: String?
  private var appDelegateRef: AppDelegate { UIApplication.shared.delegate as! AppDelegate }
  private var player: PlayerFacade { appDelegateRef.player }

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = .black
    gradient.colors = [UIColor.darkGray.cgColor, UIColor.black.cgColor]
    view.layer.addSublayer(gradient)
    buildUI()
    player.addNotifier(notifier: self)
    NotificationCenter.default.addObserver(self, selector: #selector(remoteChanged), name: RemoteSession.changedNotification, object: nil)
    let swipe = UISwipeGestureRecognizer(target: self, action: #selector(close))
    swipe.direction = .down
    view.addGestureRecognizer(swipe)
    // Titel antippen -> Album, Interpret antippen -> Interpreten-Seite
    titleLabel.isUserInteractionEnabled = true
    titleLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openAlbum)))
    titleLabel.accessibilityTraits.insert(.button)
    titleLabel.accessibilityHint = T("Öffnet das Album")
    artistLabel.isUserInteractionEnabled = true
    artistLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openArtist)))
    artistLabel.accessibilityTraits.insert(.button)
    artistLabel.accessibilityHint = T("Öffnet den Interpreten")
    refresh()
  }

  private func navigate(to makeVC: @escaping @MainActor () -> UIViewController?) {
    guard let vc = makeVC() else {
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
      return
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let delegate = appDelegateRef
    dismiss(animated: true) {
      delegate.displayInLibraryTab(vc: vc)
    }
  }

  @objc
  private func openAlbum() {
    guard let song = BlackboxNowPlaying.current().song else { return }
    navigate {
      guard let album = song.album, let account = album.account else { return nil }
      return AppStoryboard.Main.segueToAlbumDetail(account: account, album: album, songToScrollTo: song)
    }
  }

  @objc
  private func openArtist() {
    guard let song = BlackboxNowPlaying.current().song else { return }
    navigate {
      guard let artist = song.artist ?? song.album?.artist, let account = artist.account else { return nil }
      return AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist)
    }
  }

  private var coverMaxHeight: NSLayoutConstraint?

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    gradient.frame = view.bounds
    // everything below the cover needs ~400 pt -> the cover gets the rest (iPad landscape)
    let available = view.safeAreaLayoutGuide.layoutFrame.height - 410
    let maxHeight = max(140, available)
    if coverMaxHeight?.constant != maxHeight { coverMaxHeight?.constant = maxHeight }
  }

  private func symbol(_ button: UIButton, _ name: String, size: CGFloat, weight: UIImage.SymbolWeight = .semibold, label: String, filled: Bool = false) {
    var c = filled ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
    c.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    c.baseForegroundColor = filled ? .black : .white
    if filled {
      c.baseBackgroundColor = UIColor.white.withAlphaComponent(0.85)
      c.cornerStyle = .capsule
    }
    button.configuration = c
    button.accessibilityLabel = label
  }

  private func buildUI() {
    remoteBadge.font = .systemFont(ofSize: 13, weight: .semibold)
    remoteBadge.textColor = UIColor.white.withAlphaComponent(0.85)
    remoteBadge.textAlignment = .center

    coverView.contentMode = .scaleAspectFill
    coverView.clipsToBounds = true
    coverView.layer.cornerRadius = 12
    coverView.layer.cornerCurve = .continuous
    coverView.backgroundColor = UIColor.white.withAlphaComponent(0.1)

    titleLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 24, weight: .bold), maximumPointSize: 34)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .white
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 2
    artistLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20), maximumPointSize: 28)
    artistLabel.adjustsFontForContentSizeCategory = true
    artistLabel.textColor = UIColor.white.withAlphaComponent(0.8)
    artistLabel.textAlignment = .center

    symbol(favoriteButton, "heart", size: 22, weight: .regular, label: T("Favorit"))
    favoriteButton.addAction(UIAction { [weak self] _ in self?.toggleFavorite() }, for: .touchUpInside)
    ratingView.delegate = self
    symbol(optionsButton, "ellipsis", size: 20, label: T("Mehr"))
    optionsButton.showsMenuAsPrimaryAction = true

    slider.minimumTrackTintColor = .white
    slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
    slider.setThumbImage(UIImage(), for: .normal)
    slider.addTarget(self, action: #selector(scrubStart), for: .touchDown)
    slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
    [elapsedLabel, remainingLabel, audioInfoLabel].forEach {
      $0.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
      $0.textColor = UIColor.white.withAlphaComponent(0.7)
    }
    audioInfoLabel.textAlignment = .center
    remainingLabel.textAlignment = .right

    symbol(prevButton, "backward.fill", size: 30, label: T("Zurück"))
    symbol(playButton, "play.fill", size: 44, label: T("Wiedergabe"))
    symbol(nextButton, "forward.fill", size: 30, label: T("Weiter"))
    prevButton.addAction(UIAction { [weak self] _ in self?.player.playPreviousOrReplay() }, for: .touchUpInside)
    playButton.addAction(UIAction { [weak self] _ in self?.player.togglePlayPause() }, for: .touchUpInside)
    nextButton.addAction(UIAction { [weak self] _ in self?.player.playNext() }, for: .touchUpInside)
    shuffleButton.addAction(UIAction { [weak self] _ in self?.player.toggleShuffle() }, for: .touchUpInside)
    repeatButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.player.setRepeatMode(self.player.repeatMode.nextMode)
    }, for: .touchUpInside)

    symbol(devicesButton, "airplayaudio", size: 20, label: T("Wiedergabegerät"))
    devicesButton.addAction(UIAction { [weak self] _ in self?.showDevices() }, for: .touchUpInside)
    symbol(settingsButton, "gearshape.fill", size: 20, label: T("Schnelleinstellungen"))
    settingsButton.addAction(UIAction { [weak self] _ in self?.showQuickSettings() }, for: .touchUpInside)
    symbol(closeButton, "chevron.down", size: 22, label: T("Schließen"))
    closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
    symbol(lyricsButton, "quote.bubble", size: 20, label: T("Songtext"))
    lyricsButton.addAction(UIAction { [weak self] _ in self?.showSheet(LyricsVC()) }, for: .touchUpInside)
    symbol(queueButton, "list.bullet", size: 20, label: T("Wiedergabeliste"))
    queueButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.showSheet(RemoteSession.shared.isRemoteActive ? RemoteQueueVC() : QueueVC())
    }, for: .touchUpInside)
    symbol(sleepButton, "moon.zzz", size: 20, label: T("Schlaftimer"))
    sleepButton.showsMenuAsPrimaryAction = true
    sleepButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
      guard let self else { completion([]); return }
      completion([self.appDelegateRef.createSleepTimerMenu(refreshCB: nil)])
    }])
    optionsButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
      guard let self, let song = BlackboxNowPlaying.current().song else { completion([]); return }
      completion(EntityPreviewActionBuilder(container: song, on: self).createMenuActions())
    }])

    let ratingRow = UIStackView(arrangedSubviews: [favoriteButton, ratingView, optionsButton])
    ratingRow.distribution = .equalCentering
    ratingRow.alignment = .center
    let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, audioInfoLabel, remainingLabel])
    timeRow.distribution = .fillEqually
    let transport = UIStackView(arrangedSubviews: [shuffleButton, prevButton, playButton, nextButton, repeatButton])
    transport.distribution = .equalSpacing
    transport.alignment = .center
    let bottom = UIStackView(arrangedSubviews: [devicesButton, settingsButton, closeButton, lyricsButton, queueButton, sleepButton])
    bottom.distribution = .equalSpacing
    bottom.alignment = .center

    // cover: always square and complete (iPad landscape), centered in its row
    let coverRow = UIView()
    coverRow.addSubview(coverView)
    coverView.translatesAutoresizingMaskIntoConstraints = false
    let stack = UIStackView(arrangedSubviews: [coverRow, titleLabel, artistLabel, ratingRow, slider, timeRow, transport, bottom])
    stack.axis = .vertical
    stack.spacing = 10
    stack.setCustomSpacing(26, after: coverRow)
    stack.setCustomSpacing(2, after: titleLabel)
    stack.setCustomSpacing(18, after: artistLabel)
    stack.setCustomSpacing(14, after: ratingRow)
    stack.setCustomSpacing(4, after: slider)
    stack.setCustomSpacing(22, after: timeRow)
    stack.setCustomSpacing(28, after: transport)
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.alwaysBounceVertical = false
    scroll.showsVerticalScrollIndicator = false
    view.addSubview(scroll)
    scroll.addSubview(stack)

    let cover = coverView.widthAnchor.constraint(equalTo: coverRow.widthAnchor)
    cover.priority = .defaultHigh
    coverMaxHeight = coverView.heightAnchor.constraint(lessThanOrEqualToConstant: 600)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
      stack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
      cover,
      coverView.widthAnchor.constraint(lessThanOrEqualTo: coverRow.widthAnchor),
      coverView.heightAnchor.constraint(equalTo: coverView.widthAnchor),
      coverMaxHeight!,
      coverView.centerXAnchor.constraint(equalTo: coverRow.centerXAnchor),
      coverView.topAnchor.constraint(equalTo: coverRow.topAnchor),
      coverView.bottomAnchor.constraint(equalTo: coverRow.bottomAnchor),
      ratingView.heightAnchor.constraint(equalToConstant: 36),
      playButton.widthAnchor.constraint(equalToConstant: 72),
      playButton.heightAnchor.constraint(equalToConstant: 72),
      shuffleButton.widthAnchor.constraint(equalToConstant: 44),
      shuffleButton.heightAnchor.constraint(equalToConstant: 44),
      repeatButton.widthAnchor.constraint(equalToConstant: 44),
      repeatButton.heightAnchor.constraint(equalToConstant: 44),
      bottom.heightAnchor.constraint(equalToConstant: 44),
    ])
  }

  // MARK: Refresh

  @objc
  private func remoteChanged() { refresh() }

  /// last applied button state – buttons/menus are only rebuilt on changes (no flicker while polling)
  private var renderedKey: String?

  private func refresh() {
    let np = BlackboxNowPlaying.current()
    remoteBadge.isHidden = true
    if titleLabel.text != np.title { titleLabel.text = np.title }
    if artistLabel.text != np.artist { artistLabel.text = np.artist }
    let song = np.song
    let key = [
      "\(np.isPlaying)", "\(np.isShuffle)", "\(np.repeatMode.rawValue)", "\(np.isRemote)",
      song?.id ?? "-", "\(song?.isFavorite ?? false)", "\(song?.rating ?? 0)", "\(np.hasItem)",
    ].joined(separator: "|")
    if key != renderedKey {
      renderedKey = key
      symbol(playButton, np.isPlaying ? "pause.fill" : "play.fill", size: 44, label: np.isPlaying ? "Pause" : "Wiedergabe")
      symbol(shuffleButton, "shuffle", size: 17, label: T("Zufall"), filled: np.isShuffle)
      let repeatName = np.repeatMode == .single ? "repeat.1" : "repeat"
      symbol(repeatButton, repeatName, size: 17, label: T("Wiederholen"), filled: np.repeatMode != .off)
      var dc = UIButton.Configuration.plain()
      dc.image = UIImage(
        systemName: np.isRemote ? "tv.fill" : "airplayaudio",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
      )
      dc.baseForegroundColor = np.isRemote ? view.tintColor : .white
      devicesButton.configuration = dc
      devicesButton.accessibilityLabel = np.isRemote
        ? "Wiedergabe auf \(RemoteSession.shared.deviceName ?? "FireTV")" : "Wiedergabegerät"

      favoriteButton.isEnabled = song != nil
      var fc = UIButton.Configuration.plain()
      fc.image = UIImage(
        systemName: (song?.isFavorite ?? false) ? "heart.fill" : "heart",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
      )
      fc.baseForegroundColor = (song?.isFavorite ?? false) ? .redHeart : .white
      favoriteButton.configuration = fc
      ratingView.isRatingEnabled = song != nil
      ratingView.setRating(song?.rating ?? 0)
      optionsButton.isEnabled = song != nil
      lyricsButton.isEnabled = !np.isRemote
      queueButton.isEnabled = true
    }

    refreshTime(np)

    let artKey = (np.coverArtId ?? "") + (np.playable?.id ?? "")
    if artKey != lastArtworkKey {
      lastArtworkKey = artKey
      np.loadArtwork { [weak self] image in
        guard let self, self.lastArtworkKey == artKey else { return }
        UIView.transition(with: self.coverView, duration: 0.3, options: .transitionCrossDissolve) {
          self.coverView.image = image
        }
        self.applyColors(from: image)
      }
    }
  }

  private func applyColors(from image: UIImage?) {
    var colors: [UIColor] = [UIColor(white: 0.25, alpha: 1), .black]
    if let image, let dominant = try? image.blackboxThumbnail().dominantColors(max: 2), let first = dominant.first {
      let darker = Self.darken(first, by: 0.55)
      let darkest = Self.darken(dominant.count > 1 ? dominant[1] : first, by: 0.25)
      colors = [darker, darkest]
    }
    let anim = CABasicAnimation(keyPath: "colors")
    anim.fromValue = gradient.colors
    anim.toValue = colors.map(\.cgColor)
    anim.duration = 0.5
    gradient.add(anim, forKey: "colors")
    gradient.colors = colors.map(\.cgColor)
  }

  private static func darken(_ color: UIColor, by factor: CGFloat) -> UIColor {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return UIColor(hue: h, saturation: min(1, s * 1.1), brightness: max(0.08, min(b, 0.9) * factor), alpha: 1)
  }

  private static func time(_ sec: Double) -> String {
    let s = max(0, Int(sec.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  private func refreshTime(_ given: BlackboxNowPlaying? = nil) {
    guard !isScrubbing else { return }
    let np = given ?? BlackboxNowPlaying.current()
    slider.maximumValue = Float(max(1, np.duration))
    slider.value = Float(np.position)
    slider.isEnabled = np.hasItem
    elapsedLabel.text = np.hasItem ? Self.time(np.position) : "--:--"
    remainingLabel.text = np.hasItem ? "-" + Self.time(np.duration - np.position) : "--:--"
    if np.isRemote {
      audioInfoLabel.text = "FireTV"
    } else if let cur = player.currentlyPlaying {
      let kbps = cur.bitrate / 1000
      let source = player.playType == .cache ? "Cache" : "Stream"
      let format = (cur.fileContentType ?? cur.contentType ?? "").split(separator: "/").last.map { String($0).uppercased().replacingOccurrences(of: "MPEG", with: "MP3") } ?? ""
      audioInfoLabel.text = [source, format, kbps > 0 ? "\(kbps) kbps" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    } else {
      audioInfoLabel.text = ""
    }
  }

  // MARK: Actions

  @objc
  private func close() { dismiss(animated: true) }

  @objc private func scrubStart() { isScrubbing = true }

  @objc private func scrubChanged() {
    elapsedLabel.text = Self.time(Double(slider.value))
    remainingLabel.text = "-" + Self.time(Double(slider.maximumValue - slider.value))
  }

  @objc private func scrubEnd() {
    isScrubbing = false
    player.seek(toSecond: Double(slider.value))
  }

  private func toggleFavorite() {
    guard let song = BlackboxNowPlaying.current().song, let account = song.account else { return }
    Task { @MainActor in
      try? await song.remoteToggleFavorite(syncer: appDelegateRef.getMeta(account.info).librarySyncer)
      refresh()
    }
  }

  func ratingView(_ ratingView: RatingView, didChangeRating rating: Int) {
    guard let song = BlackboxNowPlaying.current().song, let account = song.account else { return }
    song.rating = rating
    Task { @MainActor in
      try? await appDelegateRef.getMeta(account.info).librarySyncer.setRating(song: song, rating: rating)
    }
  }

  private func showSheet(_ vc: UIViewController) {
    let nav = UINavigationController(rootViewController: vc)
    vc.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in
      nav?.dismiss(animated: true)
    })
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }

  private func showDevices() {
    let nav = UINavigationController(rootViewController: DevicePickerVC())
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }

  private func showQuickSettings() {
    let host = UIHostingController(rootView: BlackboxQuickSettingsView())
    host.title = T("Schnelleinstellungen")
    showSheet(host)
  }

  // MARK: MusicPlayable
  func didStartPlayingFromBeginning() { refresh() }
  func didStartPlaying() { refresh() }
  func didPause() { refresh() }
  func didStopPlaying() { refresh() }
  func didElapsedTimeChange() { if !RemoteSession.shared.isRemoteActive { refreshTime() } }
  func didPlaylistChange() { refresh() }
  func didArtworkChange() { lastArtworkKey = nil; refresh() }
  func didShuffleChange() { refresh() }
  func didRepeatChange() { refresh() }
  func didPlaybackRateChange() {}
}

// MARK: - DevicePickerVC

/// "Wiedergabe auf …": this iPhone, Blackbox FireTVs in the network, AirPlay/Bluetooth.
final class DevicePickerVC: UITableViewController {
  private let browser = FireTVBrowser()
  private var devices: [FireTVBrowser.Device] = []
  private var connecting: String?

  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Wiedergabe auf"
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    browser.onChange = { [weak self] found in
      self?.devices = found
      self?.tableView.reloadData()
    }
    browser.start()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    browser.stop()
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 3 }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch section {
    case 0: return nil
    case 1: return T("Blackbox im Netzwerk")
    default: return "AirPlay & Bluetooth"
    }
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    section == 1 ? "Solange ein FireTV gewählt ist, steuert das iPhone nur noch den FireTV – es spielt selbst nichts ab. Der FireTV muss nur an sein (FireLauncher) – ohne Launcher muss Blackbox auf dem FireTV geöffnet sein." : nil
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section {
    case 0: return 1
    case 1: return devices.count + 1
    default: return 1
    }
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    var content = cell.defaultContentConfiguration()
    cell.accessoryType = .none
    cell.accessoryView = nil
    let session = RemoteSession.shared
    switch indexPath.section {
    case 0:
      content.text = UIDevice.current.userInterfaceIdiom == .pad ? "Dieses iPad" : "Dieses iPhone"
      content.image = UIImage(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
      cell.accessoryType = session.isRemoteActive ? .none : .checkmark
    case 1:
      if indexPath.row < devices.count {
        let d = devices[indexPath.row]
        content.text = d.name
        content.image = UIImage(systemName: "tv")
        cell.accessoryType = session.deviceName == d.name ? .checkmark : .none
        if connecting == d.name {
          let spinner = UIActivityIndicatorView(style: .medium)
          spinner.startAnimating()
          cell.accessoryView = spinner
        }
      } else {
        content.text = T("IP-Adresse eingeben …")
        content.image = UIImage(systemName: "keyboard")
        if session.isRemoteActive, !devices.contains(where: { $0.name == session.deviceName }) {
          content.secondaryText = "Verbunden: \(session.deviceName ?? "")"
        }
      }
    default:
      content.text = T("AirPlay- oder Bluetooth-Gerät wählen")
      let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
      picker.tintColor = view.tintColor
      cell.accessoryView = picker
      content.image = UIImage(systemName: "airplayaudio")
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch indexPath.section {
    case 0:
      RemoteSession.shared.disconnect()
      tableView.reloadData()
    case 1:
      if indexPath.row < devices.count {
        let d = devices[indexPath.row]
        connecting = d.name
        tableView.reloadData()
        Task { @MainActor in
          if let host = await FireTVBrowser.resolve(d.endpoint) {
            RemoteSession.shared.connect(host: host, name: d.name)
          }
          connecting = nil
          tableView.reloadData()
        }
      } else {
        askForHost()
      }
    default:
      // AVRoutePickerView handles the tap itself
      if let picker = tableView.cellForRow(at: indexPath)?.accessoryView as? AVRoutePickerView {
        picker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
      }
    }
  }

  private func askForHost() {
    let alert = UIAlertController(title: T("FireTV-Adresse"), message: T("Steht auf dem FireTV in Blackbox unter Einstellungen."), preferredStyle: .alert)
    alert.addTextField {
      $0.keyboardType = .numbersAndPunctuation
      $0.text = FireTVClient.savedHost
      $0.placeholder = "192.168.30.21"
    }
    alert.addAction(UIAlertAction(title: T("Abbrechen"), style: .cancel))
    alert.addAction(UIAlertAction(title: T("Verbinden"), style: .default) { [weak self, weak alert] _ in
      guard let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
      RemoteSession.shared.connect(host: text, name: nil)
      self?.tableView.reloadData()
    })
    present(alert, animated: true)
  }
}

// MARK: - Quick settings (gear in the player)

struct BlackboxQuickSettingsView: View {
  private var delegate: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

  @State private var scrobble: Bool
  @State private var replayGain: Bool
  @State private var autoplay: Bool
  @State private var syncQueue: Bool
  @State private var wifi: StreamingMaxBitratePreference
  @State private var cellular: StreamingMaxBitratePreference
  @State private var resumeMessage: String?

  @MainActor
  init() {
    let user = (UIApplication.shared.delegate as! AppDelegate).storage.settings.user
    let accounts = (UIApplication.shared.delegate as! AppDelegate).storage.settings.accounts
    _scrobble = State(initialValue: accounts.active.map { accounts.getSetting($0).read.isScrobbleStreamedItems } ?? false)
    _replayGain = State(initialValue: user.isReplayGainEnabled)
    _autoplay = State(initialValue: user.isAutoplayEnabled)
    _syncQueue = State(initialValue: PlayQueueSync.isEnabled)
    _wifi = State(initialValue: user.streamingMaxBitrateWifiPreference)
    _cellular = State(initialValue: user.streamingMaxBitrateCellularPreference)
  }

  private func applyBitrates() {
    delegate.storage.settings.user.streamingMaxBitrateWifiPreference = wifi
    delegate.storage.settings.user.streamingMaxBitrateCellularPreference = cellular
    delegate.player.setStreamingMaxBitrates(to: StreamingMaxBitrates(wifi: wifi, cellular: cellular))
  }

  var body: some View {
    Form {
      Section {
        Toggle(T("Scrobbeln"), isOn: $scrobble)
          .onChange(of: scrobble) { _, v in
            guard let active = delegate.storage.settings.accounts.active else { return }
            delegate.storage.settings.accounts.updateSetting(active) { $0.isScrobbleStreamedItems = v }
          }
      } footer: {
        Text(T("Gestreamte Titel an den Server melden (Wiedergabezähler, Rückblicke)."))
      }
      Section {
        Toggle("ReplayGain", isOn: $replayGain)
          .onChange(of: replayGain) { _, v in delegate.storage.settings.user.isReplayGainEnabled = v }
      } footer: {
        Text(T("Lautstärke anhand der Metadaten angleichen."))
      }
      Section {
        Toggle(T("Fortlaufende Wiedergabe"), isOn: $autoplay)
          .onChange(of: autoplay) { _, v in delegate.storage.settings.user.isAutoplayEnabled = v }
      } footer: {
        Text(T("Wenn die Warteschlange endet, laufen ähnliche Titel weiter (Radio)."))
      }
      Section {
        Toggle(T("Wiedergabeliste geräteübergreifend synchronisieren"), isOn: $syncQueue)
          .onChange(of: syncQueue) { _, v in PlayQueueSync.isEnabled = v }
        Button(T("Wiedergabe von anderem Gerät fortsetzen")) {
          Task { @MainActor in resumeMessage = await PlayQueueSync.resume() }
        }
        if let resumeMessage { Text(resumeMessage).font(.footnote).foregroundStyle(.secondary) }
      } footer: {
        Text(T("Speichert Warteschlange und Position auf dem Server (auch der FireTV nutzt das), damit du auf einem anderen Gerät weiterhören kannst."))
      }
      Section("Transcoding") {
        Picker(T("WLAN"), selection: $wifi) {
          ForEach(StreamingMaxBitratePreference.allCases, id: \.self) { Text($0.description).tag($0) }
        }
        .onChange(of: wifi) { _, _ in applyBitrates() }
        Picker(T("Mobilfunk"), selection: $cellular) {
          ForEach(StreamingMaxBitratePreference.allCases, id: \.self) { Text($0.description).tag($0) }
        }
        .onChange(of: cellular) { _, _ in applyBitrates() }
      }
    }
  }
}

// MARK: - PlayQueueSync

/// Saves the play queue on the server (Subsonic savePlayQueue) and resumes it on another device.
@MainActor
final class PlayQueueSync: MusicPlayable {
  static let shared = PlayQueueSync()
  private static let key = "blackbox.syncPlayQueue"
  private var lastSave = Date.distantPast
  private var registered = false
  private var appDelegateRef: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

  static var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: key) }
    set {
      UserDefaults.standard.set(newValue, forKey: key)
      if newValue { shared.start(); shared.save(force: true) }
    }
  }

  func start() {
    guard !registered else { return }
    registered = true
    appDelegateRef.player.addNotifier(notifier: self)
  }

  private var api: BackendProxy? {
    guard let info = appDelegateRef.storage.settings.accounts.active else { return nil }
    return appDelegateRef.getMeta(info).backendApi
  }

  func save(force: Bool = false) {
    guard Self.isEnabled, !RemoteSession.shared.isRemoteActive else { return }
    guard force || Date().timeIntervalSince(lastSave) > 15 else { return }
    let player = appDelegateRef.player
    guard let current = player.currentlyPlaying, let api else { return }
    lastSave = Date()
    let prev = player.getAllPrevQueueItems().suffix(100)
    let next = player.getAllUserQueueItems() + player.getAllNextQueueItems()
    let ids = prev.map(\.id) + [current.id] + next.prefix(300).map(\.id)
    var query = ids.map { URLQueryItem(name: "id", value: $0) }
    query.append(URLQueryItem(name: "current", value: current.id))
    query.append(URLQueryItem(name: "position", value: String(Int(player.elapsedTime * 1000))))
    Task {
      guard let url = try? await api.generateUrl(forAction: "savePlayQueue", query: query) else { return }
      var req = URLRequest(url: url)
      for (k, v) in api.httpHeaders { req.setValue(v, forHTTPHeaderField: k) }
      _ = try? await URLSession.shared.data(for: req)
    }
  }

  /// Loads the queue saved by another device and plays it here (or on the connected FireTV).
  static func resume() async -> String {
    let delegate = UIApplication.shared.delegate as! AppDelegate
    guard let info = delegate.storage.settings.accounts.active else { return T("Kein Konto aktiv.") }
    let api = delegate.getMeta(info).backendApi
    guard let url = try? await api.generateUrl(forAction: "getPlayQueue", query: [URLQueryItem(name: "f", value: "json")]) else {
      return T("Vom Server nicht unterstützt.")
    }
    var req = URLRequest(url: url)
    for (k, v) in api.httpHeaders { req.setValue(v, forHTTPHeaderField: k) }
    guard let result = try? await URLSession.shared.data(for: req),
          let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
          let response = json["subsonic-response"] as? [String: Any],
          let queue = response["playQueue"] as? [String: Any],
          let entries = queue["entry"] as? [[String: Any]], !entries.isEmpty
    else { return T("Keine gespeicherte Wiedergabeliste gefunden.") }
    let account = delegate.storage.main.library.getAccount(info: info)
    let songs = entries.compactMap { $0["id"] as? String }.compactMap {
      delegate.storage.main.library.getSong(for: account, id: $0)
    }
    guard !songs.isEmpty else { return T("Die Titel sind in der Mediathek noch nicht synchronisiert.") }
    let current = queue["current"].map { "\($0)" }
    let index = songs.firstIndex(where: { $0.id == current }) ?? 0
    let position = (queue["position"] as? Double ?? Double(queue["position"] as? Int ?? 0)) / 1000
    delegate.player.play(context: PlayContext(name: "Fortgesetzt", index: index, playables: songs))
    if position > 1 {
      try? await Task.sleep(nanoseconds: 700_000_000)
      delegate.player.seek(toSecond: position)
    }
    let by = (queue["changedBy"] as? String).map { " (von \($0))" } ?? ""
    return T("Fortgesetzt: \(songs[index].title)\(by)")
  }

  func didStartPlayingFromBeginning() { save(force: true) }
  func didStartPlaying() {}
  func didPause() { save(force: true) }
  func didStopPlaying() {}
  func didElapsedTimeChange() { save() }
  func didPlaylistChange() { save(force: true) }
  func didArtworkChange() {}
  func didShuffleChange() {}
  func didRepeatChange() {}
  func didPlaybackRateChange() {}
}

// MARK: - Cover colored background for album / playlist details (Blackbox)

extension UIImage {
  /// kleine Kopie (max. 64 px) für Farbberechnungen
  func blackboxThumbnail(maxSide: CGFloat = 64) -> UIImage {
    let w = size.width * scale, h = size.height * scale
    guard max(w, h) > maxSide, w > 0, h > 0 else { return self }
    let f = maxSide / max(w, h)
    let target = CGSize(width: max(1, (w * f).rounded()), height: max(1, (h * f).rounded()))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      self.draw(in: CGRect(origin: .zero, size: target))
    }
  }
}

final class CoverGradientBackgroundView: UIView {
  private let gradient = CAGradientLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .systemBackground
    layer.addSublayer(gradient)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradient.frame = bounds
  }

  private var lastColor: UIColor?

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    apply(color: lastColor)
  }

  /// Cover color over the whole screen (incl. the song list), fading into the background
  func apply(color: UIColor?) {
    lastColor = color
    guard let color else {
      gradient.colors = nil
      return
    }
    let bg = UIColor.systemBackground.resolvedColor(with: traitCollection)
    func blend(_ t: CGFloat) -> CGColor {
      var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
      var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
      color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
      bg.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
      return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1).cgColor
    }
    gradient.colors = [blend(0.15), blend(0.45), blend(0.72)]
    gradient.locations = [0, 0.4, 1]
  }
}

extension UITableViewController {
  /// Background with the colors of the cover (like the player)
  func applyBlackboxCoverBackground(for container: PlayableContainable) {
    let bg = (tableView.backgroundView as? CoverGradientBackgroundView) ?? CoverGradientBackgroundView()
    tableView.backgroundView = bg
    tableView.backgroundColor = .clear
    // song rows transparent, so the cover color covers the whole screen
    UITableViewCell.appearance(whenContainedInInstancesOf: [AlbumDetailVC.self]).backgroundColor = .clear
    UITableViewCell.appearance(whenContainedInInstancesOf: [PlaylistDetailVC.self]).backgroundColor = .clear
    let delegate = UIApplication.shared.delegate as! AppDelegate
    func setColor(from image: UIImage?) {
      guard let image else { return }
      // Farbe aus einer kleinen Kopie im Hintergrund berechnen – große Cover (z. B. 1000 px von
      // Blackbox Request) blockierten sonst den Main-Thread minutenlang
      Task.detached(priority: .userInitiated) {
        let small = image.blackboxThumbnail()
        guard let c = (try? small.dominantColors(max: 1))?.first else { return }
        await MainActor.run {
          UIView.transition(with: bg, duration: 0.3, options: .transitionCrossDissolve) { bg.apply(color: c) }
        }
      }
    }
    if let playlist = container as? Playlist,
       let coverArtId = PlaylistCategoryRegistry.coverArtId(ofPlaylistId: playlist.id),
       let info = playlist.account?.info {
      Task { @MainActor in
        setColor(from: await PlaylistCoverLoader.shared.image(coverArtId: coverArtId, accountInfo: info))
      }
      return
    }
    let entity: AbstractLibraryEntity? = (container as? AbstractLibraryEntity) ?? (container.playables.first as AbstractLibraryEntity?)
    guard let entity, let info = entity.account?.info else { return }
    let setting = delegate.storage.settings.accounts.getSetting(info).read
    setColor(from: LibraryEntityImage.getImageToDisplayImmediately(
      libraryEntity: entity,
      themePreference: setting.themePreference,
      artworkDisplayPreference: setting.artworkDisplayPreference,
      useCache: false
    ))
  }
}


// MARK: - RemoteQueueVC

/// Queue of the FireTV ("Als Nächstes"), tap = jump to the song.
final class RemoteQueueVC: UITableViewController {
  private var entries: [FireTVQueueEntry] = []
  private var current: Int?

  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Warteschlange – \(RemoteSession.shared.deviceName ?? "FireTV")"
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "q")
    NotificationCenter.default.addObserver(self, selector: #selector(reload), name: RemoteSession.changedNotification, object: nil)
    reload()
  }

  @objc
  private func reload() {
    let s = RemoteSession.shared.status
    let newCurrent = s?.queueIndex
    // nur der aktuelle und die kommenden Titel
    let new = (s?.queue ?? []).filter { newCurrent == nil || $0.index >= newCurrent! }
    guard new != entries || newCurrent != current else { return }
    let first = entries.isEmpty
    entries = new
    current = newCurrent
    tableView.reloadData()
    if first, let cur = current, let row = entries.firstIndex(where: { $0.index == cur }) {
      tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: false)
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    entries.isEmpty ? "Die Warteschlange ist leer oder der FireTV antwortet nicht." : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "q", for: indexPath)
    let e = entries[indexPath.row]
    var c = UIListContentConfiguration.subtitleCell()
    c.text = e.title
    c.secondaryText = e.artist
    let isCurrent = e.index == current
    c.textProperties.color = isCurrent ? .tintColor : .label
    c.textProperties.font = .systemFont(ofSize: 17, weight: isCurrent ? .semibold : .regular)
    c.image = UIImage(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
    c.imageProperties.tintColor = isCurrent ? .tintColor : .secondaryLabel
    cell.contentConfiguration = c
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    RemoteSession.shared.remoteCommand("jump", value: Double(entries[indexPath.row].index))
  }
}

// MARK: - Blackbox: Übersetzung der Texte aus Storyboards/XIBs

@MainActor
enum BBNibTranslator {
  /// Texte, die direkt in Storyboards/XIBs stehen
  static let nibTexts: Set<String> = [
    "Syncing", "Info", "Login", "Skip >", "Updating", "Description", "Artist", "Clear",
    "Next from:", "Play", "Shuffle", "New playlist name", "Create",
  ]

  private static var installed = false

  static func install() {
    guard !installed, BBLocale.isGerman else { return }
    installed = true
    swap(UIViewController.self, #selector(UIViewController.viewWillAppear(_:)), #selector(UIViewController.bb_viewWillAppear(_:)))
    swap(UIView.self, #selector(UIView.awakeFromNib), #selector(UIView.bb_viewAwakeFromNib))
  }

  private static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
    guard let o = class_getInstanceMethod(cls, original),
          let r = class_getInstanceMethod(cls, replacement) else { return }
    if class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r)) {
      class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o))
    } else {
      method_exchangeImplementations(o, r)
    }
  }

  static func tr(_ text: String?) -> String? {
    guard let text, nibTexts.contains(text) else { return nil }
    let t = TV(text)
    return t == text ? nil : t
  }

  /// nur das Element selbst – jedes aus einer XIB geladene Element wird einzeln geweckt
  static func translate(_ view: UIView) {
    if let label = view as? UILabel, let t = tr(label.text) {
      label.text = t
    } else if let button = view as? UIButton {
      if let t = tr(button.configuration?.title) {
        button.configuration?.title = t
      } else if let t = tr(button.title(for: .normal)) {
        button.setTitle(t, for: .normal)
      }
    } else if let field = view as? UITextField, let t = tr(field.placeholder) {
      field.placeholder = t
    }
  }

  static func translate(_ vc: UIViewController) {
    if let t = tr(vc.title) { vc.title = t }
    if let t = tr(vc.navigationItem.title) { vc.navigationItem.title = t }
    for item in (vc.navigationItem.rightBarButtonItems ?? []) + (vc.navigationItem.leftBarButtonItems ?? []) {
      if let t = tr(item.title) { item.title = t }
    }
  }
}

extension UIViewController {
  /// `dynamic`: Aufruf muss über die Objective-C-Laufzeit gehen, sonst ruft sich die Methode
  /// nach dem Vertauschen im Release-Build direkt selbst auf (Endlosschleife -> Absturz beim Start)
  @objc
  dynamic func bb_viewWillAppear(_ animated: Bool) {
    bb_viewWillAppear(animated)
    BBNibTranslator.translate(self)
  }
}

extension UIView {
  @objc
  dynamic func bb_viewAwakeFromNib() {
    bb_viewAwakeFromNib()
    BBNibTranslator.translate(self)
  }
}
