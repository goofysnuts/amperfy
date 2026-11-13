//
//  SettingsView.swift
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

import AmperfyKit
import SwiftUI
import UserNotifications

// MARK: - SettingsView

struct SettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  func screenLockPreventionOffPressed() {
    settings.screenLockPreventionPreference = .never
    UIDevice.current.isBatteryMonitoringEnabled = false
    appDelegate.configureLockScreenPrevention()
  }

  func screenLockPreventionOnPressed() {
    settings.screenLockPreventionPreference = .always
    UIDevice.current.isBatteryMonitoringEnabled = false
    appDelegate.configureLockScreenPrevention()
  }

  func screenLockPreventionChargingPressed() {
    settings.screenLockPreventionPreference = .onlyIfCharging
    UIDevice.current.isBatteryMonitoringEnabled = true
    appDelegate.configureLockScreenPrevention()
  }

  func navigationLink(_ item: NavigationTarget) -> some View {
    NavigationLink(value: item) {
      Text(item.displayName)
    }
  }

  var body: some View {
    let list =
      SettingsList {
        SettingsSection {
          SettingsRow(title: T("Version")) {
            SecondaryText(AppDelegate.version)
          }
          SettingsRow(title: T("Build Number")) {
            SecondaryText(AppDelegate.buildNumber)
          }
        }

        BlackboxSettingsSections()

        BlackboxRequestSettingsSection()

        NavidromeScanSection()

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: T("Offline Mode"), isOn: $settings.isOfflineMode)
          },
          footer:
          "Songs, podcasts, and artworks won’t download offline. Searches are limited to the device, and playlists won’t sync with the server."
        )

        SettingsSection {
          SettingsRow(title: T("Prevent Screen Lock")) {
            Menu(settings.screenLockPreventionPreference.description) {
              Button(
                ScreenLockPreventionPreference.never.description,
                action: screenLockPreventionOffPressed
              )
              Button(
                ScreenLockPreventionPreference.always.description,
                action: screenLockPreventionOnPressed
              )
              Button(
                ScreenLockPreventionPreference.onlyIfCharging.description,
                action: screenLockPreventionChargingPressed
              )
            }
          }
        }

        #if !targetEnvironment(macCatalyst) // ok
          SettingsSection {
            navigationLink(.account)
            navigationLink(.displayAndInteraction)
            navigationLink(.library)
            navigationLink(.player)
            navigationLink(.equalizer)
            navigationLink(.swipe)
            navigationLink(.artwork)
          }

          SettingsSection {
            navigationLink(.support)
            navigationLink(.license)
            navigationLink(.xcallback)

            #if DEBUG
              navigationLink(.developer)
            #endif
          }
        #endif
      }

    #if targetEnvironment(macCatalyst) // ok
      ZStack {
        list
      }
      .navigationTitle(T("General"))
      .navigationBarTitleDisplayMode(.inline)
    #else
      NavigationStack {
        list
          .navigationTitle(T("Settings"))
          // All pushes in this stack must be value based. Mixing view based links
          // (NavigationLink(destination:)) with the value based links of the sub pages
          // results in a navigation loop.
          .navigationDestination(for: NavigationTarget.self) { item in
            AnyView(item.view())
          }
      }
    #endif
  }
}

// MARK: - SettingsView_Previews

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
  }
}

// MARK: - Blackbox settings

/// Darstellung (Home-Überschrift, Akzentfarbe), Home-Bereiche, Konten und FireTV-Fernbedienung.
struct BlackboxSettingsSections: View {
  @State
  private var homeTitle: String = BlackboxAppearance.homeTitle == "Home" ? "" : BlackboxAppearance.homeTitle
  @State
  private var accent: Color = Color(uiColor: BlackboxAppearance.customAccent ?? .systemOrange)
  @State
  private var useCustomAccent: Bool = BlackboxAppearance.customAccent != nil
  @State
  private var accountsVersion = 0
  @State
  private var language: BlackboxLanguage = BBLocale.setting

  private var delegate: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

  @MainActor
  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private func applyAccent() {
    BlackboxAppearance.customAccent = useCustomAccent ? UIColor(accent) : nil
    if let active = delegate.storage.settings.accounts.active {
      delegate.setAppTheme(
        color: delegate.storage.settings.accounts.getSetting(active).read.themePreference.asColor
      )
    }
    delegate.applyAppThemeToAlreadyLoadedViews()
  }

  var body: some View {
    SettingsSection(content: {
      SettingsRow(title: T("Home-Überschrift")) {
        TextField("Home", text: $homeTitle)
          .multilineTextAlignment(.trailing)
          .submitLabel(.done)
          .onChange(of: homeTitle) { _, newValue in
            BlackboxAppearance.homeTitle = newValue
          }
      }
      SettingsCheckBoxRow(title: T("Eigene Akzentfarbe"), isOn: $useCustomAccent)
        .onChange(of: useCustomAccent) { _, _ in applyAccent() }
      if useCustomAccent {
        ColorPicker(BBL("Akzentfarbe", en: "Accent color"), selection: $accent, supportsOpacity: false)
          .onChange(of: accent) { _, _ in applyAccent() }
      }
      Button(T("Home-Bereiche bearbeiten")) {
        guard let active = delegate.storage.settings.accounts.active,
              let presenter = topViewController() else { return }
        HomeVC.presentSectionEditor(from: presenter, accountInfo: active)
      }
    }, footer: T("Ohne eigene Akzentfarbe gilt die Theme-Farbe des Kontos."), header: "Blackbox")

    SettingsSection(content: {
      Picker(T("Sprache"), selection: $language) {
        ForEach(BlackboxLanguage.allCases, id: \.self) { lang in
          Text(lang.label).tag(lang)
        }
      }
      .onChange(of: language) { _, newValue in
        BBLocale.setting = newValue
      }
      if language != BBLocale.startSetting {
        Text(BBL(
          "Die Sprache wird nach einem Neustart der App vollständig übernommen. App schließen (vom unteren Rand nach oben wischen) und neu öffnen.",
          en: "The language is fully applied after restarting the app. Close the app (swipe up from the bottom) and open it again."
        ))
        .font(.footnote)
        .foregroundStyle(Color.secondary)
      }
    }, header: T("Sprache"))

    SettingsSection(content: {
      let accounts = delegate.storage.settings.accounts
      ForEach(accounts.allAccounts, id: \.self) { info in
        let creds = accounts.getSetting(info).read.loginCredentials
        Button {
          guard info != accounts.active else { return }
          delegate.switchAccount(accountInfo: info)
          accountsVersion += 1
        } label: {
          HStack {
            Image(systemName: "person.crop.circle")
            VStack(alignment: .leading) {
              Text(creds?.username ?? BBL("Unbekannt", en: "Unknown")).foregroundStyle(Color.primary)
              Text(creds?.displayServerUrl ?? "").font(.caption).foregroundStyle(Color.secondary)
            }
            Spacer()
            if info == accounts.active {
              Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
          }
        }
      }
      .id(accountsVersion)
      Button(T("Konto hinzufügen")) {
        let login = AppStoryboard.Main.segueToLogin()
        login.modalPresentationStyle = .formSheet
        topViewController()?.present(login, animated: true)
      }
    }, header: T("Konten"))
  }
}

// MARK: - Blackbox Request (Musik suchen & anfragen, Docker-Dienst auf dem NAS)

enum BlackboxRequestConfig {
  private static let urlKey = "blackbox.request.url"
  private static let apiKeyKey = "blackbox.request.apikey"

  static var url: String {
    get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey) }
  }

  static var apiKey: String {
    get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
    set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: apiKeyKey) }
  }

  static var isConfigured: Bool { !url.isEmpty }
}

struct BBRStatus: Codable, Hashable, Sendable {
  let id: Int
  let status: String
  let progress: Double?
  let message: String?
}

struct BBRTrack: Codable, Hashable, Sendable {
  let title: String?
  let duration: Int?
  /// schon in der Mediathek?
  var available: Bool? = nil
}

struct BBRAlbum: Codable, Hashable, Identifiable, Sendable {
  let id: String
  let title: String
  let artist: String
  let artistId: String?
  let year: Int?
  let cover: String?
  let coverSmall: String?
  let tracks: Int?
  let recordType: String?
  let inLibrary: Bool?
  let request: BBRStatus?
  let tracklist: [BBRTrack]?
  let genres: [String]?
  /// Anzahl Titel dieses Albums in der Mediathek; partial = nur ein Teil davon
  var libraryTracks: Int? = nil
  var partial: Bool? = nil
  /// Album-ID in Navidrome, wenn (teilweise) vorhanden
  var libraryId: String? = nil

  var partialInfo: (have: Int, total: Int)? {
    guard partial == true, let have = libraryTracks, let total = tracks else { return nil }
    return (have, total)
  }

  var isBusy: Bool { ["pending", "searching", "downloading", "importing"].contains(request?.status ?? "") }
}

struct BBRArtist: Codable, Hashable, Identifiable, Sendable {
  let id: String
  let name: String
  let picture: String?
  let albums: Int?
  let request: BBRStatus?
  let discography: [BBRAlbum]?
  var inLibrary: Bool? = nil
}

struct BBRSong: Codable, Hashable, Identifiable, Sendable {
  let id: String
  let title: String
  let artist: String
  let album: BBRAlbum
}

struct BBRSearchResult: Codable, Sendable {
  let artists: [BBRArtist]
  let albums: [BBRAlbum]
  let songs: [BBRSong]

  static let empty = BBRSearchResult(artists: [], albums: [], songs: [])

  /// Alben, die noch nicht in der Mediathek sind (inkl. Alben der gefundenen Songs), ohne Duplikate
  var missingAlbums: [BBRAlbum] {
    var seen = Set<String>()
    return (albums + songs.map(\.album)).filter { a in
      guard a.inLibrary != true, !seen.contains(a.id) else { return false }
      seen.insert(a.id)
      return true
    }
  }
}

struct BBRRequest: Codable, Hashable, Identifiable, Sendable {
  let id: Int
  let kind: String
  let sourceId: String
  let title: String
  let artist: String
  let year: Int?
  let cover: String?
  let status: String
  let message: String?
  let progress: Double?
  let releaseTitle: String?

  enum CodingKeys: String, CodingKey {
    case id, kind, title, artist, year, cover, status, message, progress
    case sourceId = "source_id"
    case releaseTitle = "release_title"
  }
}

enum BBRStatusText {
  static func text(_ status: String) -> String {
    switch status {
    case "pending": return T("Wartet")
    case "searching": return T("Suche Release")
    case "downloading": return T("Lädt")
    case "importing": return T("Importiert")
    case "available": return T("Verfügbar")
    case "notfound": return T("Nicht gefunden")
    case "failed": return T("Fehlgeschlagen")
    case "cancelled": return T("Abgebrochen")
    default: return status
    }
  }

  static func color(_ status: String) -> Color {
    switch status {
    case "available": return .green
    case "failed": return .red
    case "notfound": return .orange
    default: return .secondary
    }
  }
}

struct BlackboxRequestClient: Sendable {
  enum ClientError: LocalizedError {
    case notConfigured, unauthorized, server(String)
    var errorDescription: String? {
      switch self {
      case .notConfigured: return T("Blackbox Request ist nicht eingerichtet (Einstellungen → Musik anfragen).")
      case .unauthorized: return T("API-Key fehlt oder ist falsch.")
      case let .server(msg): return msg
      }
    }
  }

  let base: String
  let apiKey: String

  init(base: String = BlackboxRequestConfig.url, apiKey: String = BlackboxRequestConfig.apiKey) {
    var b = base
    if !b.isEmpty, !b.lowercased().hasPrefix("http") { b = "http://" + b }
    while b.hasSuffix("/") { b.removeLast() }
    self.base = b
    self.apiKey = apiKey
  }

  private func send<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> T {
    guard !base.isEmpty, let url = URL(string: base + path) else { throw ClientError.notConfigured }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpMethod = method
    req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
    if let body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw ClientError.unauthorized }
    if code == 404, ["/api/discover", "/api/genre", "/api/events"].contains(where: { path.hasPrefix($0) }) {
      throw ClientError.server("Blackbox Request ist veraltet – bitte den Container auf dem NAS neu bauen.")
    }
    guard (200 ..< 300).contains(code) else {
      let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
      throw ClientError.server(detail ?? "Serverfehler (\(code))")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private struct OK: Decodable {}
  private struct Health: Decodable { let navidrome: String?; let nzbget: String?; let indexers: Int? }

  func search(_ q: String) async throws -> BBRSearchResult {
    let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
    return try await send("/api/search?q=\(enc)")
  }

  func album(_ id: String) async throws -> BBRAlbum { try await send("/api/album/\(id)") }
  func artist(_ id: String) async throws -> BBRArtist { try await send("/api/artist/\(id)") }
  func requests() async throws -> [BBRRequest] { try await send("/api/requests") }

  @discardableResult
  func request(kind: String, id: String, replace: Bool = false) async throws -> BBRRequest {
    try await send("/api/requests", method: "POST",
                   body: ["kind": kind, "id": id, "requestedBy": "Blackbox iOS", "replace": replace ? "true" : "false"])
  }

  func retry(_ id: Int) async throws { let _: BBRRequest = try await send("/api/requests/\(id)/retry", method: "POST") }
  func delete(_ id: Int) async throws { let _: OK = try await send("/api/requests/\(id)", method: "DELETE") }

  private struct DiscoverResponse: Decodable {
    struct Section: Decodable {
      let id: String
      let title: String
      let kind: String
      let items: [Item]
    }
    /// Album oder Interpret – je nach Abschnitt
    struct Item: Decodable {
      let album: BBRAlbum?
      let artist: BBRArtist?
      init(from decoder: Decoder) throws {
        album = try? BBRAlbum(from: decoder)
        artist = album == nil ? try? BBRArtist(from: decoder) : nil
      }
    }
    let sections: [Section]
  }

  func discover(refresh: Bool = false) async throws -> [BBRDiscoverSection] {
    let r: DiscoverResponse = try await send("/api/discover" + (refresh ? "?refresh=true" : ""))
    return r.sections.map { s in
      BBRDiscoverSection(
        id: s.id, title: s.title, kind: s.kind,
        albums: s.kind == "albums" ? s.items.compactMap(\.album) : [],
        artists: s.kind == "artists" ? s.items.compactMap(\.artist) : []
      )
    }
  }

  func genres() async throws -> [BBRGenre] { try await send("/api/genres") }
  func genre(_ id: String) async throws -> BBRGenreResult { try await send("/api/genre/\(id)") }

  struct Events: Decodable, Sendable {
    struct Item: Decodable, Sendable {
      let id: Int
      let title: String
      let artist: String
      let cover: String?
    }
    let now: Double
    let available: [Item]
  }

  func events(since: Double) async throws -> Events { try await send("/api/events?since=\(since)") }

  func health() async throws -> String {
    let h: Health = try await send("/api/health")
    return "Navidrome: \(h.navidrome ?? "–") · NZBGet: \(h.nzbget ?? "–") · Indexer: \(h.indexers ?? 0)"
  }
}

// MARK: Bausteine

struct BBRCover: View {
  let url: String?
  var size: CGFloat = 56
  var round = false

  var body: some View {
    AsyncImage(url: URL(string: url ?? "")) { phase in
      if let image = phase.image {
        image.resizable().scaledToFill()
      } else {
        ZStack {
          Color(uiColor: .secondarySystemFill)
          Image(systemName: round ? "music.mic" : "music.note").foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : size * 0.12, style: .continuous))
    .accessibilityHidden(true)
  }
}

struct BBRStateLabel: View {
  let inLibrary: Bool
  let request: BBRStatus?
  var partial: (have: Int, total: Int)? = nil

  var body: some View {
    let busy = ["pending", "searching", "downloading", "importing"].contains(request?.status ?? "")
    if let p = partial, !busy {
      Label(T("Teilweise (\(p.have) von \(p.total))"), systemImage: "circle.lefthalf.filled").foregroundStyle(.orange)
    } else if inLibrary {
      Label(T("In der Mediathek"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    } else if let r = request {
      if r.status == "downloading", let p = r.progress, p > 0 {
        Label("\(BBRStatusText.text(r.status)) \(Int(p * 100)) %", systemImage: "arrow.down.circle")
          .foregroundStyle(.secondary)
      } else {
        Label(BBRStatusText.text(r.status), systemImage: r.status == "available" ? "checkmark.circle.fill" : "clock")
          .foregroundStyle(BBRStatusText.color(r.status))
      }
    }
  }
}

// MARK: Suche (eigener Bildschirm)

@MainActor
final class BBRSearchModel: ObservableObject {
  @Published var query = ""
  @Published var result = BBRSearchResult.empty
  @Published var isLoading = false
  @Published var error: String?
  private var task: Task<Void, Never>?

  func search(_ q: String, debounce: Bool = true) {
    task?.cancel()
    let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
    query = q
    guard q.count >= 2, BlackboxRequestConfig.isConfigured else {
      result = .empty
      isLoading = false
      return
    }
    task = Task { [weak self] in
      if debounce { try? await Task.sleep(nanoseconds: 500_000_000) }
      guard !Task.isCancelled, let self else { return }
      self.isLoading = true
      do {
        let r = try await BlackboxRequestClient().search(q)
        guard !Task.isCancelled else { return }
        self.result = r
        self.error = nil
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
      self.isLoading = false
    }
  }

  func refresh() { search(query, debounce: false) }
}

struct BlackboxRequestSearchView: View {
  enum Scope: String, CaseIterable, Identifiable {
    case all = "Alle", songs = "Songs", artists = "Interpreten", albums = "Alben", genres = "Genres"
    var id: String { rawValue }
  }

  @StateObject private var model = BBRSearchModel()
  @StateObject private var discover = BBRDiscoverModel()
  @State private var text: String
  @State private var scope: Scope = .all
  @Environment(\.dismiss) private var dismiss
  private let showsDiscover: Bool

  init(initialQuery: String = "", showsDiscover: Bool = false) {
    _text = State(initialValue: initialQuery)
    self.showsDiscover = showsDiscover
  }

  private var isSearching: Bool { model.query.count >= 2 }

  var body: some View {
    NavigationStack {
      List {
        if !BlackboxRequestConfig.isConfigured {
          Text(T("Trage unter Einstellungen → Musik anfragen die Adresse deines Blackbox-Request-Servers ein."))
            .foregroundStyle(.secondary)
        }
        if let error = model.error, isSearching {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
        if scope == .genres {
          genreSection
        } else if isSearching {
          resultSections
        } else if showsDiscover {
          discoverSections
        }
      }
      .listStyle(.insetGrouped)
      .overlay {
        if isSearching, scope != .genres, model.isLoading, model.result.artists.isEmpty, model.result.albums.isEmpty {
          ProgressView()
        } else if isSearching, scope != .genres, !model.isLoading, model.error == nil,
                  model.result.artists.isEmpty, model.result.albums.isEmpty, model.result.songs.isEmpty {
          ContentUnavailableView.search(text: model.query)
        } else if !isSearching, showsDiscover, scope != .genres, discover.isLoading, discover.sections.isEmpty {
          ProgressView()
        }
      }
      .navigationTitle(showsDiscover ? "Musik hinzufügen" : "Musik anfragen")
      .navigationBarTitleDisplayMode(.large)
      .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                  prompt: T("Songs, Interpreten, Alben, Genres"))
      .searchScopes($scope, activation: .onSearchPresentation) {
        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
      }
      .onChange(of: text) { _, newValue in model.search(newValue) }
      .onAppear {
        if !text.isEmpty, model.query.isEmpty { model.search(text, debounce: false) }
        if showsDiscover { discover.load() }
      }
      .refreshable { if showsDiscover { discover.load(refresh: true) } }
      .navigationDestination(for: BBRRoute.self) { route in
        switch route {
        case let .album(id): BBRAlbumDetailView(albumId: id, onChange: model.refresh)
        case let .artist(id): BBRArtistDetailView(artistId: id, onChange: model.refresh)
        case .requests: BlackboxRequestsListView()
        case let .genre(id, name): BBRGenreView(genreId: id, name: name)
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(T("Fertig")) { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          NavigationLink(value: BBRRoute.requests) {
            Label(T("Meine Anfragen"), systemImage: "tray.full")
          }
        }
      }
    }
  }

  // MARK: Suchergebnisse

  @ViewBuilder
  private var resultSections: some View {
    if (scope == .all || scope == .artists), !model.result.artists.isEmpty {
      Section(T("Interpreten")) {
        ForEach(model.result.artists) { a in
          NavigationLink(value: BBRRoute.artist(a.id)) { BBRArtistRow(artist: a) }
        }
      }
    }
    if (scope == .all || scope == .albums), !model.result.albums.isEmpty {
      Section(T("Alben")) {
        ForEach(model.result.albums) { a in
          NavigationLink(value: BBRRoute.album(a.id)) { BBRAlbumRow(album: a) }
        }
      }
    }
    if (scope == .all || scope == .songs), !model.result.songs.isEmpty {
      Section {
        ForEach(model.result.songs) { s in
          NavigationLink(value: BBRRoute.album(s.album.id)) {
            HStack(spacing: 12) {
              BBRCover(url: s.album.coverSmall, size: 48)
              VStack(alignment: .leading, spacing: 2) {
                Text(s.title).lineLimit(1)
                Text("\(s.artist) · \(s.album.title)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                BBRStateLabel(inLibrary: s.album.inLibrary == true, request: s.album.request,
                              partial: s.album.partialInfo).font(.caption)
              }
            }
          }
        }
      } header: {
        Text(T("Songs"))
      } footer: {
        Text(T("Angefragt wird immer das ganze Album."))
      }
    }
  }

  // MARK: Genres

  @ViewBuilder
  private var genreSection: some View {
    let q = text.trimmingCharacters(in: .whitespaces).lowercased()
    let list = discover.genres.filter { q.isEmpty || $0.name.lowercased().contains(q) }
    Section(T("Genres")) {
      if discover.genres.isEmpty {
        ProgressView().frame(maxWidth: .infinity).onAppear { discover.loadGenres() }
      }
      ForEach(list) { g in
        NavigationLink(value: BBRRoute.genre(g.id, g.name)) {
          HStack(spacing: 12) {
            BBRCover(url: g.picture, size: 44)
            Text(g.name)
          }
        }
      }
    }
  }

  // MARK: Vorschläge

  @ViewBuilder
  private var discoverSections: some View {
    if let error = discover.error {
      Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
    }
    ForEach(discover.sections) { sec in
      Section {
        BBRShelf(section: sec)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
      } header: {
        Text(sec.title).font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
      }
    }
    if !discover.sections.isEmpty {
      Section {
        Button {
          scope = .genres
          discover.loadGenres()
        } label: {
          Label(T("Nach Genre stöbern"), systemImage: "square.grid.2x2")
        }
      }
    }
  }
}

struct BBRArtistRow: View {
  let artist: BBRArtist

  var body: some View {
    HStack(spacing: 12) {
      BBRCover(url: artist.picture, size: 48, round: true)
      VStack(alignment: .leading, spacing: 2) {
        Text(artist.name)
        if artist.inLibrary == true {
          Text(T("In deiner Mediathek")).font(.footnote).foregroundStyle(.green)
        } else if let r = artist.request {
          Text(BBRStatusText.text(r.status)).font(.footnote).foregroundStyle(BBRStatusText.color(r.status))
        } else if let n = artist.albums {
          Text(T("\(n) Alben")).font(.footnote).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// horizontale Reihe mit Alben oder Interpreten (Vorschläge)
struct BBRShelf: View {
  let section: BBRDiscoverSection

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(alignment: .top, spacing: 14) {
        if section.kind == "artists" {
          ForEach(section.artists) { a in
            NavigationLink(value: BBRRoute.artist(a.id)) {
              VStack(spacing: 6) {
                BBRCover(url: a.picture, size: 120, round: true)
                Text(a.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
              }
              .frame(width: 120)
            }
            .buttonStyle(.plain)
          }
        } else {
          ForEach(section.albums) { a in
            NavigationLink(value: BBRRoute.album(a.id)) {
              VStack(alignment: .leading, spacing: 3) {
                BBRCover(url: a.coverSmall ?? a.cover, size: 140)
                Text(a.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Text(a.request.map { BBRStatusText.text($0.status) } ?? a.artist)
                  .font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              .frame(width: 140)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
    }
  }
}

struct BBRGenreView: View {
  let genreId: String
  let name: String
  @State private var albums: [BBRAlbum] = []
  @State private var artists: [BBRArtist] = []
  @State private var error: String?
  @State private var loaded = false

  var body: some View {
    List {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
      if !artists.isEmpty {
        Section {
          BBRShelf(section: BBRDiscoverSection(id: "a", title: "", kind: "artists", albums: [], artists: artists))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
          Text(T("Interpreten")).font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
        }
      }
      if !albums.isEmpty {
        Section(T("Top-Alben")) {
          ForEach(albums) { a in
            NavigationLink(value: BBRRoute.album(a.id)) { BBRAlbumRow(album: a) }
          }
        }
      }
    }
    .overlay { if !loaded { ProgressView() } }
    .navigationTitle(name)
    .task {
      do {
        let g = try await BlackboxRequestClient().genre(genreId)
        albums = g.albums
        artists = g.artists.filter { $0.inLibrary != true }
      } catch {
        self.error = error.localizedDescription
      }
      loaded = true
    }
  }
}

struct BBRGenre: Codable, Hashable, Identifiable, Sendable {
  let id: String
  let name: String
  let picture: String?
}

struct BBRGenreResult: Codable, Sendable {
  let albums: [BBRAlbum]
  let artists: [BBRArtist]
}

struct BBRDiscoverSection: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let kind: String
  let albums: [BBRAlbum]
  let artists: [BBRArtist]
}

@MainActor
final class BBRDiscoverModel: ObservableObject {
  @Published var sections: [BBRDiscoverSection] = []
  @Published var genres: [BBRGenre] = []
  @Published var isLoading = false
  @Published var error: String?

  func load(refresh: Bool = false) {
    guard BlackboxRequestConfig.isConfigured, !isLoading, refresh || sections.isEmpty else { return }
    isLoading = true
    Task {
      do {
        sections = try await BlackboxRequestClient().discover(refresh: refresh)
        error = nil
      } catch {
        self.error = error.localizedDescription
      }
      isLoading = false
    }
  }

  func loadGenres() {
    guard BlackboxRequestConfig.isConfigured, genres.isEmpty else { return }
    Task {
      genres = (try? await BlackboxRequestClient().genres()) ?? []
    }
  }
}

enum BBRRoute: Hashable {
  case album(String), artist(String), requests, genre(String, String)
}

struct BBRAlbumRow: View {
  let album: BBRAlbum

  var body: some View {
    HStack(spacing: 12) {
      BBRCover(url: album.coverSmall ?? album.cover, size: 56)
      VStack(alignment: .leading, spacing: 2) {
        Text(album.title).lineLimit(1)
        Text([album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
          .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        BBRStateLabel(inLibrary: album.inLibrary == true, request: album.request, partial: album.partialInfo).font(.caption)
      }
    }
  }
}

// MARK: Album / Interpret

struct BBRAlbumDetailView: View {
  let albumId: String
  var onChange: () -> Void = {}
  @State private var album: BBRAlbum?
  @State private var error: String?
  @State private var sending = false
  @State private var confirmReplace = false
  @State private var redirected = false

  var body: some View {
    List {
      if let a = album {
        Section {
          VStack(spacing: 12) {
            BBRCover(url: a.cover, size: 220)
              .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            VStack(spacing: 4) {
              Text(a.title).font(.title2.bold()).multilineTextAlignment(.center)
              Text(a.artist).font(.title3).foregroundStyle(Color.accentColor)
              Text([a.recordType?.capitalized, a.year.map(String.init), a.tracks.map { "\($0) Titel" },
                    a.genres?.first].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary)
            }
            actionButton(a)
          }
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
        }
        if let tracks = a.tracklist, !tracks.isEmpty {
          Section {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
              HStack {
                Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 26, alignment: .trailing)
                Text(t.title ?? "")
                  .foregroundStyle(showsAvailability && t.available != true ? .secondary : .primary)
                Spacer()
                if showsAvailability {
                  Image(systemName: t.available == true ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(t.available == true ? Color.green : Color.secondary)
                    .accessibilityLabel(t.available == true ? "In der Mediathek" : "Fehlt")
                } else if let d = t.duration {
                  Text(String(format: "%d:%02d", d / 60, d % 60)).foregroundStyle(.secondary).monospacedDigit()
                }
              }
            }
          } header: {
            Text(T("Titel"))
          } footer: {
            if showsAvailability, let have = a.libraryTracks {
              Text(T("\(have) von \(tracks.count) Titeln sind in deiner Mediathek."))
            }
          }
        }
      } else if let error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
    }
    .confirmationDialog(T("Ganzes Album neu laden?"), isPresented: $confirmReplace, titleVisibility: .visible) {
      Button(T("Neu laden und ersetzen")) { if let a = album { Task { await send(a, replace: true) } } }
      Button(T("Abbrechen"), role: .cancel) {}
    } message: {
      Text(T("Das komplette Album wird heruntergeladen. Die vorhandenen Dateien dieses Albums werden danach ersetzt."))
    }
    .overlay { if album == nil, error == nil { ProgressView() } }
    .navigationTitle(album?.title ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  private var showsAvailability: Bool { (album?.libraryTracks ?? 0) > 0 }

  @ViewBuilder
  private func actionButton(_ a: BBRAlbum) -> some View {
    if a.isBusy, let r = a.request {
      VStack(spacing: 6) {
        BBRStateLabel(inLibrary: false, request: r).font(.headline)
        if let m = r.message { Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
      }
      .padding(.top, 4)
    } else if a.partial == true {
      VStack(spacing: 8) {
        Label(T("\(a.libraryTracks ?? 0) von \(a.tracks ?? 0) Titeln in deiner Mediathek"), systemImage: "circle.lefthalf.filled")
          .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
        if let lib = a.libraryId {
          Button(T("Vorhandene Titel in der Mediathek öffnen")) { BlackboxLibraryNav.openAlbum(id: lib) }
            .font(.subheadline)
        }
        Button {
          confirmReplace = true
        } label: {
          Label(sending ? "Wird angefragt …" : "Ganzes Album neu laden", systemImage: "arrow.down.circle.fill")
            .font(.headline)
            .frame(maxWidth: 280, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(sending)
      }
      .padding(.top, 4)
    } else if a.inLibrary == true {
      VStack(spacing: 8) {
        Label(T("In deiner Mediathek"), systemImage: "checkmark.circle.fill")
          .font(.headline).foregroundStyle(.green)
        if let lib = a.libraryId {
          Button(T("In der Mediathek öffnen")) { BlackboxLibraryNav.openAlbum(id: lib) }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
      }
      .padding(.top, 4)
    } else if let r = a.request {
      VStack(spacing: 6) {
        BBRStateLabel(inLibrary: false, request: r).font(.headline)
        if let m = r.message { Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
      }
      .padding(.top, 4)
    } else {
      Button {
        Task { await send(a) }
      } label: {
        Label(sending ? "Wird angefragt …" : "Album anfragen", systemImage: "arrow.down.circle.fill")
          .font(.headline)
          .frame(maxWidth: 280, minHeight: 44)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .disabled(sending)
      .padding(.top, 4)
    }
  }

  private func load() async {
    do { album = try await BlackboxRequestClient().album(albumId); error = nil } catch { self.error = error.localizedDescription }
    // komplett in der Mediathek -> direkt zum Album der Mediathek
    if let a = album, a.inLibrary == true, !a.isBusy, let lib = a.libraryId, !redirected {
      redirected = true
      BlackboxLibraryNav.openAlbum(id: lib)
    }
  }

  private func send(_ a: BBRAlbum, replace: Bool = false) async {
    sending = true
    defer { sending = false }
    do {
      try await BlackboxRequestClient().request(kind: "album", id: a.id, replace: replace)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      await load()
      onChange()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct BBRArtistDetailView: View {
  let artistId: String
  var onChange: () -> Void = {}
  @State private var artist: BBRArtist?
  @State private var error: String?
  @State private var sending = false
  @State private var confirm = false

  private var missing: [BBRAlbum] {
    (artist?.discography ?? []).filter { $0.inLibrary != true && $0.request == nil && ($0.recordType ?? "album") == "album" }
  }

  var body: some View {
    List {
      if let a = artist {
        Section {
          VStack(spacing: 12) {
            BBRCover(url: a.picture, size: 160, round: true)
            Text(a.name).font(.title2.bold())
            if let r = a.request {
              BBRStateLabel(inLibrary: false, request: r).font(.headline)
            } else if !missing.isEmpty {
              Button {
                confirm = true
              } label: {
                Label(T("\(missing.count) fehlende Alben anfragen"), systemImage: "arrow.down.circle.fill")
                  .font(.headline).frame(maxWidth: 280, minHeight: 44)
              }
              .buttonStyle(.borderedProminent)
              .buttonBorderShape(.capsule)
              .disabled(sending)
            } else {
              Label(T("Alle Alben vorhanden"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
          }
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
        }
        ForEach(BBRAlbumGroup.groups(a.discography ?? [])) { group in
          Section(group.title) {
            ForEach(group.albums) { al in
              NavigationLink(value: BBRRoute.album(al.id)) { BBRAlbumRow(album: al) }
            }
          }
        }
      } else if let error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
    }
    .overlay { if artist == nil, error == nil { ProgressView() } }
    .navigationTitle(artist?.name ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Alle fehlenden Alben von \(artist?.name ?? "") anfragen?", isPresented: $confirm,
                        titleVisibility: .visible) {
      Button(T("\(missing.count) Alben anfragen")) { Task { await send() } }
      Button(T("Abbrechen"), role: .cancel) {}
    }
    .task { await load() }
  }

  private func load() async {
    do { artist = try await BlackboxRequestClient().artist(artistId); error = nil } catch { self.error = error.localizedDescription }
  }

  private func send() async {
    sending = true
    defer { sending = false }
    do {
      try await BlackboxRequestClient().request(kind: "artist", id: artistId)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      await load()
      onChange()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

// MARK: Meine Anfragen

struct BlackboxRequestsListView: View {
  @State private var items: [BBRRequest] = []
  @State private var error: String?
  @State private var loaded = false

  var body: some View {
    List {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
      ForEach(items) { r in
        HStack(spacing: 12) {
          BBRCover(url: r.cover, size: 56, round: r.kind == "artist")
          VStack(alignment: .leading, spacing: 3) {
            Text(r.title).lineLimit(1)
            Text(r.kind == "artist" ? "Interpret" : [r.artist, r.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
              .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            if r.status == "downloading", r.kind == "album" {
              ProgressView(value: r.progress ?? 0).tint(.accentColor)
            }
            if let m = r.message, !m.isEmpty {
              Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
          }
          Spacer(minLength: 8)
          Text(BBRStatusText.text(r.status))
            .font(.caption.weight(.semibold))
            .foregroundStyle(BBRStatusText.color(r.status))
        }
        .swipeActions(edge: .trailing) {
          Button(role: .destructive) {
            Task { try? await BlackboxRequestClient().delete(r.id); await load() }
          } label: { Label(T("Entfernen"), systemImage: "trash") }
          if r.status == "failed" || r.status == "notfound" {
            Button {
              Task { try? await BlackboxRequestClient().retry(r.id); await load() }
            } label: { Label(T("Erneut"), systemImage: "arrow.clockwise") }
              .tint(.orange)
          }
        }
      }
    }
    .overlay {
      if !loaded { ProgressView() } else if items.isEmpty, error == nil {
        ContentUnavailableView(T("Keine Anfragen"), systemImage: "tray",
                               description: Text(T("Angefragte Alben und Interpreten erscheinen hier.")))
      }
    }
    .navigationTitle(T("Meine Anfragen"))
    .refreshable { await load() }
    .task {
      // Fortschritt live aktualisieren, solange die Liste sichtbar ist
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
      }
    }
  }

  private func load() async {
    do { items = try await BlackboxRequestClient().requests(); error = nil } catch { self.error = error.localizedDescription }
    loaded = true
  }
}

// MARK: Einstellungen

struct BlackboxRequestSettingsSection: View {
  @State private var url = BlackboxRequestConfig.url
  @State private var apiKey = BlackboxRequestConfig.apiKey
  @State private var testResult: String?
  @State private var showSearch = false
  @State private var showRequests = false

  var body: some View {
    SettingsSection(content: {
      SettingsRow(title: T("Adresse")) {
        TextField("http://192.168.30.145:8686", text: $url)
          .multilineTextAlignment(.trailing)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onChange(of: url) { _, v in
            BlackboxRequestConfig.url = v
            if !v.isEmpty { BlackboxRequestNotifier.requestPermission() }
          }
      }
      SettingsRow(title: T("API-Key")) {
        SecureField("optional", text: $apiKey)
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.never)
          .onChange(of: apiKey) { _, v in BlackboxRequestConfig.apiKey = v }
      }
      Button(T("Verbindung testen")) {
        testResult = "Teste …"
        Task {
          do { testResult = try await BlackboxRequestClient().health() } catch { testResult = error.localizedDescription }
        }
      }
      .disabled(url.isEmpty)
      if let testResult {
        Text(testResult).font(.footnote).foregroundStyle(.secondary)
      }
      Button(T("Musik suchen & anfragen")) { showSearch = true }
        .disabled(url.isEmpty)
      Button(T("Meine Anfragen")) { showRequests = true }
        .disabled(url.isEmpty)
    }, footer: T("Fehlende Alben und Interpreten über deinen Blackbox-Request-Server (NAS) laden. In der Suche erscheint dann „Nicht in deiner Mediathek“."),
    header: T("Musik anfragen"))
    .sheet(isPresented: $showSearch) { BlackboxRequestSearchView() }
    .sheet(isPresented: $showRequests) {
      NavigationStack {
        BlackboxRequestsListView()
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button(T("Fertig")) { showRequests = false } } }
      }
    }
  }
}

// MARK: Inline in der normalen Suche: „Nicht in deiner Mediathek“

struct BlackboxRequestInlineView: View {
  @ObservedObject var model: BBRSearchModel
  var onOpenAll: (String) -> Void
  var onOpenAlbum: (String) -> Void

  var body: some View {
    let missing = model.result.missingAlbums
    VStack(alignment: .leading, spacing: 10) {
      if model.query.count >= 2 {
        HStack(alignment: .firstTextBaseline) {
          Text(T("Nicht in deiner Mediathek")).font(.title3.bold())
          Spacer()
          Button(T("Alle")) { onOpenAll(model.query) }
            .font(.body)
        }
        .padding(.horizontal, 16)
        if missing.isEmpty {
          Group {
            if model.isLoading {
              ProgressView()
            } else if let error = model.error {
              Text(error)
            } else {
              Text(T("Keine fehlenden Alben gefunden."))
            }
          }
          .font(.footnote).foregroundStyle(.secondary)
          .padding(.horizontal, 16)
        } else {
          ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
              ForEach(missing.prefix(20)) { a in
                Button { onOpenAlbum(a.id) } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    BBRCover(url: a.coverSmall ?? a.cover, size: 140)
                    Text(a.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                    if let r = a.request {
                      Text(BBRStatusText.text(r.status)).font(.caption).foregroundStyle(BBRStatusText.color(r.status))
                    } else {
                      Text(a.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                  }
                  .frame(width: 140)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(a.title) von \(a.artist), anfragen")
              }
            }
            .padding(.horizontal, 16)
          }
        }
      }
    }
    .padding(.vertical, 12)
  }
}

struct BBRAlbumGroup: Identifiable {
  let title: String
  let albums: [BBRAlbum]
  var id: String { title }

  static func groups(_ all: [BBRAlbum]) -> [BBRAlbumGroup] {
    [("Alben", "album"), ("EPs", "ep"), ("Singles", "single"), ("Compilations", "compile")]
      .map { title, type in BBRAlbumGroup(title: title, albums: all.filter { ($0.recordType ?? "album") == type }) }
      .filter { !$0.albums.isEmpty }
  }
}

/// Album aus der normalen Suche als Sheet (mit eigener Navigation für „Fertig“)
struct BBRAlbumSheet: View {
  let albumId: String
  var onChange: () -> Void = {}
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      BBRAlbumDetailView(albumId: albumId, onChange: onChange)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button(T("Fertig")) { dismiss() } }
        }
    }
  }
}


// MARK: - Mitteilung, wenn ein angefragtes Album verfügbar ist

@MainActor
enum BlackboxRequestNotifier {
  private static let lastKey = "blackbox.request.lastEvent"
  private static var pollTask: Task<Void, Never>?
  private static var checking = false

  /// prüft jede Minute, solange die App läuft (auch im Hintergrund während Musik spielt)
  static func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { @MainActor in
      while !Task.isCancelled {
        await check()
        try? await Task.sleep(nanoseconds: 60_000_000_000)
      }
    }
  }

  static func requestPermission() {
    Task {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
  }

  static func check() async {
    guard BlackboxRequestConfig.isConfigured, !checking else { return }
    checking = true
    defer { checking = false }
    let since = UserDefaults.standard.double(forKey: lastKey)
    guard let ev = try? await BlackboxRequestClient().events(since: since == 0 ? Date().timeIntervalSince1970 - 3600 : since)
    else { return }
    UserDefaults.standard.set(ev.now, forKey: lastKey)
    for item in ev.available {
      await post(item)
    }
  }

  private static func post(_ item: BlackboxRequestClient.Events.Item) async {
    let content = UNMutableNotificationContent()
    content.title = T("Neu in deiner Mediathek")
    content.body = "„\(item.title)“ von \(item.artist) ist jetzt verfügbar."
    content.sound = .default
    content.threadIdentifier = "blackbox-request"
    if let cover = item.cover, let url = URL(string: cover),
       let data = try? await URLSession.shared.data(from: url).0 {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("bbr-\(item.id).jpg")
      if (try? data.write(to: file)) != nil,
         let att = try? UNNotificationAttachment(identifier: "cover", url: file) {
        content.attachments = [att]
      }
    }
    let req = UNNotificationRequest(identifier: "bbr-available-\(item.id)", content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(req)
  }
}

// MARK: - Navidrome-Bibliothek scannen

@MainActor
enum NavidromeScanner {
  struct Status: Sendable {
    let scanning: Bool
    let count: Int?
  }

  enum ScanError: LocalizedError {
    case noAccount, failed(String)
    var errorDescription: String? {
      switch self {
      case .noAccount: return T("Kein Konto aktiv.")
      case let .failed(m): return m
      }
    }
  }

  private static func call(_ action: String, _ query: [URLQueryItem] = []) async throws -> Status {
    let delegate = UIApplication.shared.delegate as! AppDelegate
    guard let info = delegate.storage.settings.accounts.active else { throw ScanError.noAccount }
    let api = delegate.getMeta(info).backendApi
    let url = try await api.generateUrl(forAction: action, query: [URLQueryItem(name: "f", value: "json")] + query)
    var req = URLRequest(url: url, timeoutInterval: 30)
    for (k, v) in api.httpHeaders { req.setValue(v, forHTTPHeaderField: k) }
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let resp = json["subsonic-response"] as? [String: Any] else { throw ScanError.failed("Ungültige Antwort") }
    if resp["status"] as? String != "ok" {
      let msg = (resp["error"] as? [String: Any])?["message"] as? String ?? "Fehler"
      throw ScanError.failed(msg.contains("admin") || msg.contains("authorized") ? "Scannen ist nur mit einem Admin-Konto möglich." : msg)
    }
    let st = resp["scanStatus"] as? [String: Any] ?? [:]
    return Status(scanning: st["scanning"] as? Bool ?? false, count: st["count"] as? Int)
  }

  static func start(full: Bool) async throws -> Status {
    try await call("startScan", full ? [URLQueryItem(name: "fullScan", value: "true")] : [])
  }

  static func status() async throws -> Status { try await call("getScanStatus") }
}

struct NavidromeScanSection: View {
  @State private var running = false
  @State private var message: String?

  var body: some View {
    SettingsSection(content: {
      Button {
        scan(full: false)
      } label: {
        HStack {
          Text(T("Mediathek scannen"))
          Spacer()
          if running { ProgressView() }
        }
      }
      .disabled(running)
      Button(T("Vollständigen Scan starten")) { scan(full: true) }
        .disabled(running)
      if let message {
        Text(message).font(.footnote).foregroundStyle(.secondary)
      }
    }, footer: T("Navidrome sucht nach neuen und geänderten Dateien. Der vollständige Scan liest alle Tags neu ein (dauert länger)."),
    header: "Navidrome")
  }

  private func scan(full: Bool) {
    running = true
    message = "Scan gestartet …"
    Task {
      do {
        var st = try await NavidromeScanner.start(full: full)
        while st.scanning {
          message = "Scanne … \(st.count.map { "\($0) Titel" } ?? "")"
          try await Task.sleep(nanoseconds: 2_000_000_000)
          st = try await NavidromeScanner.status()
        }
        message = "Fertig – \(st.count.map { "\($0) Titel in der Mediathek" } ?? "Mediathek aktuell")."
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      } catch {
        message = error.localizedDescription
      }
      running = false
    }
  }
}

// MARK: - Interpreten-Seite (Blackbox): Infos, Top-Songs, Top-Alben, Alben/Singles quer scrollbar

@MainActor
final class BlackboxArtistModel: ObservableObject {
  struct AlbumInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let year: Int?
    let cover: URL?
    let playCount: Int
    let songCount: Int
    let releaseTypes: [String]
  }

  struct TopSong: Identifiable, Hashable {
    let id: String
    let title: String
    let album: String
    let cover: URL?
  }

  struct Similar: Identifiable, Hashable {
    let id: String
    let name: String
    let image: URL?
  }

  let artist: Artist
  let account: Account
  @Published var bio: String?
  @Published var image: URL?
  @Published var albums: [AlbumInfo] = []
  @Published var topSongs: [TopSong] = []
  @Published var similar: [Similar] = []
  @Published var loaded = false

  private var delegate: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

  init(artist: Artist, account: Account) {
    self.artist = artist
    self.account = account
  }

  private func call(_ action: String, _ query: [URLQueryItem]) async -> [String: Any]? {
    let api = delegate.getMeta(account.info).backendApi
    guard let url = try? await api.generateUrl(forAction: action, query: [URLQueryItem(name: "f", value: "json")] + query)
    else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 20)
    for (k, v) in api.httpHeaders { req.setValue(v, forHTTPHeaderField: k) }
    guard let data = try? await URLSession.shared.data(for: req).0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let resp = json["subsonic-response"] as? [String: Any], resp["status"] as? String == "ok"
    else { return nil }
    return resp
  }

  private func cover(_ id: String?) async -> URL? {
    guard let id, !id.isEmpty else { return nil }
    return try? await delegate.getMeta(account.info).backendApi.generateUrl(forArtworkId: id)
  }

  func load() async {
    guard !loaded else { return }
    // Alben/Songs des Interpreten in die lokale Datenbank holen (für Wiedergabe und Album-Seiten)
    Task {
      try? await artist.fetch(
        storage: delegate.storage,
        librarySyncer: delegate.getMeta(account.info).librarySyncer,
        playableDownloadManager: delegate.getMeta(account.info).playableDownloadManager
      )
    }
    let id = artist.id
    if let a = await call("getArtist", [URLQueryItem(name: "id", value: id)])?["artist"] as? [String: Any] {
      var list: [AlbumInfo] = []
      for al in a["album"] as? [[String: Any]] ?? [] {
        guard let aid = al["id"] as? String else { continue }
        list.append(AlbumInfo(
          id: aid, name: al["name"] as? String ?? "", year: al["year"] as? Int, cover: await cover(al["coverArt"] as? String),
          playCount: al["playCount"] as? Int ?? 0, songCount: al["songCount"] as? Int ?? 0,
          releaseTypes: (al["releaseTypes"] as? [String] ?? []).map { $0.lowercased() }
        ))
      }
      albums = list.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }
    if let info = await call("getArtistInfo2", [URLQueryItem(name: "id", value: id), URLQueryItem(name: "count", value: "15")])?["artistInfo2"] as? [String: Any] {
      if let b = info["biography"] as? String {
        let plain = b.replacingOccurrences(of: "<a[^>]*>.*?</a>", with: "", options: .regularExpression)
          .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
          .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        bio = plain.isEmpty ? nil : plain
      }
      if let s = (info["largeImageUrl"] as? String) ?? (info["mediumImageUrl"] as? String), !s.isEmpty,
         !s.contains("2a96cbd8b46e442fc41c2b86b821562f") { // Last.fm-Platzhalterbild
        image = URL(string: s)
      }
      var sims: [Similar] = []
      for s in info["similarArtist"] as? [[String: Any]] ?? [] {
        guard let sid = s["id"] as? String, !sid.isEmpty, sid != "-1" else { continue }
        var img = (s["artistImageUrl"] as? String).flatMap(URL.init(string:))
        if img == nil { img = await cover(s["coverArt"] as? String) }
        sims.append(Similar(id: sid, name: s["name"] as? String ?? "", image: img))
      }
      similar = sims
    }
    if image == nil, let first = albums.first { image = first.cover }
    // Top-Songs: Last.fm über Navidrome, sonst die meistgespielten Songs aus der eigenen Mediathek
    var songs: [[String: Any]] = (await call("getTopSongs", [URLQueryItem(name: "artist", value: artist.name), URLQueryItem(name: "count", value: "20")])?["topSongs"] as? [String: Any])?["song"] as? [[String: Any]] ?? []
    if songs.isEmpty {
      let found = (await call("search3", [URLQueryItem(name: "query", value: artist.name), URLQueryItem(name: "songCount", value: "200"),
                                          URLQueryItem(name: "albumCount", value: "0"), URLQueryItem(name: "artistCount", value: "0")])?["searchResult3"] as? [String: Any])?["song"] as? [[String: Any]] ?? []
      songs = found.filter { ($0["artistId"] as? String) == id || ($0["artist"] as? String)?.lowercased() == artist.name.lowercased() }
        .sorted { ($0["playCount"] as? Int ?? 0) > ($1["playCount"] as? Int ?? 0) }
    }
    var tops: [TopSong] = []
    var seenTitles = Set<String>()
    for s in songs {
      guard let sid = s["id"] as? String, let title = s["title"] as? String, !seenTitles.contains(title.lowercased()) else { continue }
      seenTitles.insert(title.lowercased())
      tops.append(TopSong(id: sid, title: title, album: s["album"] as? String ?? "", cover: await cover(s["coverArt"] as? String)))
      if tops.count == 12 { break }
    }
    topSongs = tops
    loaded = true
  }

  /// Song-Objekte für die Wiedergabe (fehlende Alben werden nachgeladen)
  func playables(for ids: [String]) async -> [AbstractPlayable] {
    let lib = delegate.storage.main.library
    var result: [Song] = []
    for sid in ids {
      if let s = lib.getSong(for: account, id: sid) {
        result.append(s)
      }
    }
    if result.count < ids.count {
      try? await artist.fetch(
        storage: delegate.storage,
        librarySyncer: delegate.getMeta(account.info).librarySyncer,
        playableDownloadManager: delegate.getMeta(account.info).playableDownloadManager
      )
      for al in artist.albums where al.songs.isEmpty {
        try? await delegate.getMeta(account.info).librarySyncer.sync(album: al)
      }
      result = ids.compactMap { lib.getSong(for: account, id: $0) }
    }
    return result
  }

  func playTop(from index: Int) {
    let ids = topSongs.map(\.id)
    Task {
      let songs = await playables(for: ids)
      guard !songs.isEmpty else { return }
      let start = songs.firstIndex { $0.id == ids[index] } ?? 0
      delegate.player.play(context: PlayContext(name: "Top-Songs: \(artist.name)", index: start, playables: songs))
    }
  }

  func playAll(shuffled: Bool) {
    Task {
      try? await artist.fetch(
        storage: delegate.storage,
        librarySyncer: delegate.getMeta(account.info).librarySyncer,
        playableDownloadManager: delegate.getMeta(account.info).playableDownloadManager
      )
      var songs = artist.playables.filterSongs()
      if songs.isEmpty {
        for al in artist.albums { try? await delegate.getMeta(account.info).librarySyncer.sync(album: al) }
        songs = artist.playables.filterSongs()
      }
      guard !songs.isEmpty else { return }
      let ctx = PlayContext(containable: artist, playables: songs.sortByAlbum())
      shuffled ? delegate.player.playShuffled(context: ctx) : delegate.player.play(context: ctx)
    }
  }
}

struct BlackboxArtistView: View {
  @ObservedObject var model: BlackboxArtistModel
  var openAlbum: (String) -> Void
  var openArtist: (String) -> Void
  var openAllSongs: () -> Void
  @State private var bioExpanded = false

  private var topAlbums: [BlackboxArtistModel.AlbumInfo] {
    Array(model.albums.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(10))
  }

  private func isSingle(_ a: BlackboxArtistModel.AlbumInfo) -> Bool {
    if !a.releaseTypes.isEmpty { return a.releaseTypes.contains("single") || a.releaseTypes.contains("ep") }
    return a.songCount > 0 && a.songCount <= 4
  }

  private func isCompilation(_ a: BlackboxArtistModel.AlbumInfo) -> Bool {
    a.releaseTypes.contains("compilation")
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        header
        if !model.topSongs.isEmpty { topSongsShelf }
        if topAlbums.count >= 2 { albumShelf("Top-Alben", topAlbums) }
        let regular = model.albums.filter { !isSingle($0) && !isCompilation($0) }
        if !regular.isEmpty { albumShelf("Alben", regular) }
        let singles = model.albums.filter(isSingle)
        if !singles.isEmpty { albumShelf("Singles & EPs", singles) }
        let comps = model.albums.filter(isCompilation)
        if !comps.isEmpty { albumShelf("Compilations", comps) }
        aboutSection
        if !model.similar.isEmpty { similarShelf }
        Button(action: openAllSongs) {
          Label(T("Alle Titel und Alben als Liste"), systemImage: "list.bullet")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
      }
    }
    .overlay { if !model.loaded, model.albums.isEmpty { ProgressView() } }
    .task { await model.load() }
  }

  // MARK: Kopf mit Bild, Name, Abspielen/Zufall

  private var header: some View {
    ZStack(alignment: .bottomLeading) {
      GeometryReader { geo in
        AsyncImage(url: model.image) { phase in
          if let img = phase.image {
            img.resizable().scaledToFill()
          } else {
            Color(uiColor: .secondarySystemFill)
          }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
      }
      LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
      HStack(alignment: .bottom) {
        Text(model.artist.name)
          .font(.largeTitle.bold())
          .foregroundStyle(.white)
          .lineLimit(2)
          .minimumScaleFactor(0.6)
        Spacer()
        Button { model.playAll(shuffled: true) } label: {
          Image(systemName: "shuffle").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityLabel("Zufallswiedergabe")
        Button { model.playAll(shuffled: false) } label: {
          Image(systemName: "play.fill").font(.title2.weight(.semibold)).frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .background(Color.white, in: Circle())
        .accessibilityLabel("Abspielen")
      }
      .padding(16)
    }
    .frame(height: 340)
    .clipped()
  }

  private func sectionTitle(_ t: String) -> some View {
    Text(t).font(.title2.bold()).padding(.horizontal, 16)
  }

  // MARK: Top-Songs: 4 Zeilen, seitlich weiterblättern

  private var topSongsShelf: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionTitle("Top-Songs")
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 4), count: min(4, model.topSongs.count)), spacing: 16) {
          ForEach(Array(model.topSongs.enumerated()), id: \.element.id) { i, s in
            Button { model.playTop(from: i) } label: {
              HStack(spacing: 12) {
                AsyncImage(url: s.cover) { p in
                  if let img = p.image { img.resizable().scaledToFill() } else { Color(uiColor: .secondarySystemFill) }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("\(i + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                  Text(s.title).foregroundStyle(.primary).lineLimit(1)
                  Text(s.album).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
              }
              .containerRelativeFrame(.horizontal, alignment: .leading) { w, _ in w * 0.82 }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .scrollTargetLayout()
        .padding(.horizontal, 16)
      }
      .scrollTargetBehavior(.viewAligned)
    }
  }

  private func albumShelf(_ title: String, _ items: [BlackboxArtistModel.AlbumInfo]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionTitle(title)
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 14) {
          ForEach(items) { a in
            Button { openAlbum(a.id) } label: {
              VStack(alignment: .leading, spacing: 3) {
                AsyncImage(url: a.cover) { p in
                  if let img = p.image { img.resizable().scaledToFill() } else { Color(uiColor: .secondarySystemFill) }
                }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(a.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Text(a.year.map(String.init) ?? " ").font(.caption).foregroundStyle(.secondary)
              }
              .frame(width: 150, alignment: .leading)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }

  @ViewBuilder
  private var aboutSection: some View {
    let songs = model.albums.reduce(0) { $0 + $1.songCount }
    VStack(alignment: .leading, spacing: 8) {
      sectionTitle("Über \(model.artist.name)")
      VStack(alignment: .leading, spacing: 8) {
        Text("\(model.albums.count) \(model.albums.count == 1 ? "Album" : "Alben") · \(songs) Songs in deiner Mediathek")
          .font(.subheadline.weight(.semibold))
        if let bio = model.bio {
          Text(bio)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(bioExpanded ? nil : 5)
          Button(bioExpanded ? "Weniger" : "Mehr") { withAnimation { bioExpanded.toggle() } }
            .font(.subheadline.weight(.semibold))
        } else if model.loaded {
          Text(T("Keine Biografie verfügbar (in Navidrome einen Last.fm-API-Key hinterlegen)."))
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .padding(.horizontal, 16)
    }
  }

  private var similarShelf: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionTitle("Ähnliche Interpreten")
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 14) {
          ForEach(model.similar) { s in
            Button { openArtist(s.id) } label: {
              VStack(spacing: 6) {
                AsyncImage(url: s.image) { p in
                  if let img = p.image { img.resizable().scaledToFill() } else {
                    ZStack { Color(uiColor: .secondarySystemFill); Image(systemName: "music.mic").foregroundStyle(.secondary) }
                  }
                }
                .frame(width: 110, height: 110)
                .clipShape(Circle())
                Text(s.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
              }
              .frame(width: 110)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }
}

final class BlackboxArtistVC: UIHostingController<BlackboxArtistView> {
  private let artist: Artist
  private let account: Account

  init(account: Account, artist: Artist) {
    self.artist = artist
    self.account = account
    let model = BlackboxArtistModel(artist: artist, account: account)
    weak var weakSelf: BlackboxArtistVC?
    super.init(rootView: BlackboxArtistView(
      model: model,
      openAlbum: { id in weakSelf?.openAlbum(id) },
      openArtist: { id in weakSelf?.openArtist(id) },
      openAllSongs: { weakSelf?.openList() }
    ))
    weakSelf = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var delegate: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = artist.name
    navigationItem.largeTitleDisplayMode = .never
    let options = UIBarButtonItem.createOptionsBarButton()
    options.menu = UIMenu.lazyMenu { [weak self] in
      guard let self else { return [] }
      return EntityPreviewActionBuilder(container: self.artist, on: self).createMenuActions()
    }
    navigationItem.rightBarButtonItem = options
  }

  private func openAlbum(_ id: String) {
    let lib = delegate.storage.main.library
    if let album = lib.getAlbum(for: account, id: id, isDetailFaultResolution: true) {
      navigationController?.pushViewController(AppStoryboard.Main.segueToAlbumDetail(account: account, album: album), animated: true)
      return
    }
    Task {
      try? await artist.fetch(
        storage: delegate.storage,
        librarySyncer: delegate.getMeta(account.info).librarySyncer,
        playableDownloadManager: delegate.getMeta(account.info).playableDownloadManager
      )
      if let album = lib.getAlbum(for: account, id: id, isDetailFaultResolution: true) {
        navigationController?.pushViewController(AppStoryboard.Main.segueToAlbumDetail(account: account, album: album), animated: true)
      }
    }
  }

  private func openArtist(_ id: String) {
    guard let other = delegate.storage.main.library.getArtist(for: account, id: id) else { return }
    navigationController?.pushViewController(AppStoryboard.Main.segueToArtistDetail(account: account, artist: other), animated: true)
  }

  private func openList() {
    navigationController?.pushViewController(ArtistDetailVC(account: account, artist: artist), animated: true)
  }
}

// MARK: - Radio (wie bei Spotify): zu einem Song eine temporäre Liste mit passenden Titeln

@MainActor
enum BlackboxRadio {
  static func start(seed song: Song) async {
    let delegate = UIApplication.shared.delegate as! AppDelegate
    guard let account = song.account else { return }
    let meta = delegate.getMeta(account.info)
    var similar: [Song] = []
    // 1. ähnliche Titel über Navidrome (Last.fm/ListenBrainz-Agenten)
    if let found = try? await meta.librarySyncer.requestSimilarSongs(song: song, count: 80) {
      similar = found.filter { $0.id != song.id }
    }
    // 2. zu wenig? -> Titel des Interpreten dazu
    if similar.count < 15, let artist = song.artist {
      try? await artist.fetch(
        storage: delegate.storage, librarySyncer: meta.librarySyncer,
        playableDownloadManager: meta.playableDownloadManager
      )
      let own = artist.playables.filterSongs().filter { $0.id != song.id && !similar.contains($0) }.shuffled()
      similar += own.prefix(max(0, 40 - similar.count))
    }
    if similar.isEmpty {
      delegate.eventLogger.info(topic: "Radio", message: BBL("Keine passenden Titel gefunden.", en: "No matching songs found."), displayPopup: true)
      return
    }
    let songs = [song] + similar.shuffled()
    delegate.player.play(context: PlayContext(name: "Radio: \(song.title)", playables: songs))
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }
}


// MARK: - Aus „Musik hinzufügen“ in die Mediathek springen

@MainActor
enum BlackboxLibraryNav {
  static func openAlbum(id: String) {
    let delegate = UIApplication.shared.delegate as! AppDelegate
    guard let info = delegate.storage.settings.accounts.active else { return }
    let library = delegate.storage.main.library
    let account = library.getAccount(info: info)
    func show(_ album: Album) {
      let vc = AppStoryboard.Main.segueToAlbumDetail(account: account, album: album)
      // alle Sheets schließen, dann im Mediathek-Tab anzeigen
      let root = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
      if let root, root.presentedViewController != nil {
        root.dismiss(animated: true) { delegate.displayInLibraryTab(vc: vc) }
      } else {
        delegate.displayInLibraryTab(vc: vc)
      }
    }
    if let album = library.getAlbum(for: account, id: id, isDetailFaultResolution: true) {
      show(album)
      return
    }
    // noch nicht lokal bekannt (gerade erst geladen): Bibliothek kurz abgleichen
    Task { @MainActor in
      try? await delegate.getMeta(info).librarySyncer.syncNewestAlbums(offset: 0, count: 50)
      if let album = library.getAlbum(for: account, id: id, isDetailFaultResolution: true) {
        show(album)
      } else {
        delegate.eventLogger.info(topic: "Mediathek", message: BBL("Album ist noch nicht in der App – bitte Mediathek aktualisieren.", en: "Album is not in the app yet – please refresh the library."), displayPopup: true)
      }
    }
  }
}
