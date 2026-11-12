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
import Network
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
      title: "Library",
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
      title: "Playlists",
      image: .playlist,
      identifier: "Tabs.FireSonic.Playlists"
    ) { _ in
      UINavigationController(
        rootViewController: AppStoryboard.Main.segueToPlaylists(account: self.account)
      )
    }
    fixTabs.append(playlistsTab!)

    settingsTab = UITab(
      title: "Settings",
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

    tabBarMinimizeBehavior = .onScrollDown

    miniPlayer = MiniPlayerView(player: appDelegate.player)
    miniPlayer!.configureForiOS()
    miniPlayer!.glassContainer.translatesAutoresizingMaskIntoConstraints = false

    let accessory = UITabAccessory(contentView: miniPlayer!.glassContainer)
    bottomAccessory = accessory

    heightConstraint = miniPlayer!.glassContainer.heightAnchor.constraint(equalToConstant: 48.0)
    heightConstraint?.isActive = true
    compactWidthConstraint = miniPlayer!.glassContainer.widthAnchor
      .constraint(equalTo: miniPlayer!.glassContainer.superview!.widthAnchor)

    miniPlayer!.tabAccessoryTraitChangeCB = configureTraitChangesForMiniPlayer
    configureTraitChangesForMiniPlayer()

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.miniPlayer?
          .refreshForTraitChange(horizontalSizeClass: self.traitCollection.horizontalSizeClass)
        self.configureTraitChangesForMiniPlayer()
      }
    )

    if appDelegate.storage.settings.user.isOfflineMode {
      appDelegate.eventLogger.info(topic: "Reminder", message: "Offline Mode is active.")
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
    guard let miniPlayer else { return }
    let isInline = miniPlayer.glassContainer.traitCollection.tabAccessoryEnvironment == .inline

    if traitCollection.horizontalSizeClass == .regular {
      centerConstraint = miniPlayer.glassContainer.safeAreaLayoutGuide.centerXAnchor.constraint(
        equalTo: mainContent().safeAreaLayoutGuide.centerXAnchor,
        constant: 0
      )
      let mainContentView = mainContent()
      var playerWidth = mainContentView.frame.width - mainContentView.safeAreaInsets
        .left - mainContentView.safeAreaInsets.right
      playerWidth = min(playerWidth, 600)
      compactWidthConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      regularWidthConstraint = miniPlayer.glassContainer.widthAnchor
        .constraint(equalToConstant: playerWidth)
      regularWidthConstraint?.isActive = true
      centerConstraint?.isActive = true
      heightConstraint?.constant = 60.0
    } else if isInline {
      heightConstraint?.constant = 48.0
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
    } else {
      heightConstraint?.constant = 48.0
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
    }

    miniPlayer.glassContainer.setNeedsLayout()
    miniPlayer.glassContainer.layoutIfNeeded()
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
    tabBarMinimizeBehavior = appDelegate.storage.settings.user
      .isToolbarPlayerAutoCollapse ? .onScrollDown : .never
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

  func playQueue(songIds: [String], index: Int, position: Double) async throws {
    let body = try JSONSerialization.data(withJSONObject: [
      "songIds": songIds, "index": index, "position": position,
    ])
    _ = try await request("queue", method: "POST", body: body)
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
    deviceConfig.title = "FireTV suchen …"
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

    symbolButton(prevButton, "backward.fill", size: 28, label: "Zurück")
    symbolButton(playButton, "play.fill", size: 40, label: "Wiedergabe")
    symbolButton(nextButton, "forward.fill", size: 28, label: "Weiter")
    prevButton.addAction(UIAction { [weak self] _ in self?.send("previous") }, for: .touchUpInside)
    playButton.addAction(UIAction { [weak self] _ in self?.send("toggle") }, for: .touchUpInside)
    nextButton.addAction(UIAction { [weak self] _ in self?.send("next") }, for: .touchUpInside)

    var transferConfig = UIButton.Configuration.filled()
    transferConfig.title = "iPhone-Wiedergabe auf FireTV übertragen"
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
    hintLabel.text = "Blackbox muss auf dem FireTV geöffnet sein (gleiches WLAN)."

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
    actions.append(UIAction(title: "IP-Adresse eingeben …", image: UIImage(systemName: "keyboard")) { [weak self] _ in
      self?.askForHost()
    })
    deviceButton.menu = UIMenu(title: "FireTV wählen", children: actions)
  }

  private func select(device: FireTVBrowser.Device) {
    Task { @MainActor in
      guard let host = await FireTVBrowser.resolve(device.endpoint) else {
        appDelegateRef.eventLogger.info(topic: "FireTV", message: "„\(device.name)“ ist nicht erreichbar.")
        return
      }
      connect(host: host, name: device.name)
    }
  }

  private func askForHost() {
    let alert = UIAlertController(
      title: "FireTV-Adresse",
      message: "IP-Adresse des FireTV, z. B. 192.168.30.21",
      preferredStyle: .alert
    )
    alert.addTextField {
      $0.keyboardType = .numbersAndPunctuation
      $0.text = FireTVClient.savedHost
    }
    alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel))
    alert.addAction(UIAlertAction(title: "Verbinden", style: .default) { [weak self, weak alert] _ in
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
      hintLabel.text = "Verbunden"
    } catch {
      status = nil
      hintLabel.text = "FireTV nicht erreichbar – ist Blackbox auf dem FireTV geöffnet?"
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
        appDelegateRef.eventLogger.info(topic: "FireTV", message: "Wiedergabe läuft jetzt auf dem FireTV.")
        await refresh()
      } catch {
        appDelegateRef.eventLogger.info(topic: "FireTV", message: "Übertragung fehlgeschlagen.")
      }
    }
  }
}
