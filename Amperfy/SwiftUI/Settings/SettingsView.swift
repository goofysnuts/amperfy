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
          SettingsRow(title: "Version") {
            SecondaryText(AppDelegate.version)
          }
          SettingsRow(title: "Build Number") {
            SecondaryText(AppDelegate.buildNumber)
          }
        }

        BlackboxSettingsSections()

        BlackboxRequestSettingsSection()

        NavidromeScanSection()

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: "Offline Mode", isOn: $settings.isOfflineMode)
          },
          footer:
          "Songs, podcasts, and artworks won’t download offline. Searches are limited to the device, and playlists won’t sync with the server."
        )

        SettingsSection {
          SettingsRow(title: "Prevent Screen Lock") {
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
      .navigationTitle("General")
      .navigationBarTitleDisplayMode(.inline)
    #else
      NavigationStack {
        list
          .navigationTitle("Settings")
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
      SettingsRow(title: "Home-Überschrift") {
        TextField("Home", text: $homeTitle)
          .multilineTextAlignment(.trailing)
          .submitLabel(.done)
          .onChange(of: homeTitle) { _, newValue in
            BlackboxAppearance.homeTitle = newValue
          }
      }
      SettingsCheckBoxRow(title: "Eigene Akzentfarbe", isOn: $useCustomAccent)
        .onChange(of: useCustomAccent) { _, _ in applyAccent() }
      if useCustomAccent {
        ColorPicker("Akzentfarbe", selection: $accent, supportsOpacity: false)
          .onChange(of: accent) { _, _ in applyAccent() }
      }
      Button("Home-Bereiche bearbeiten") {
        guard let active = delegate.storage.settings.accounts.active,
              let presenter = topViewController() else { return }
        HomeVC.presentSectionEditor(from: presenter, accountInfo: active)
      }
    }, footer: "Ohne eigene Akzentfarbe gilt die Theme-Farbe des Kontos.", header: "Blackbox")

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
              Text(creds?.username ?? "Unbekannt").foregroundStyle(Color.primary)
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
      Button("Konto hinzufügen") {
        let login = AppStoryboard.Main.segueToLogin()
        login.modalPresentationStyle = .formSheet
        topViewController()?.present(login, animated: true)
      }
    }, header: "Konten")
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
    case "pending": return "Wartet"
    case "searching": return "Suche Release"
    case "downloading": return "Lädt"
    case "importing": return "Importiert"
    case "available": return "Verfügbar"
    case "notfound": return "Nicht gefunden"
    case "failed": return "Fehlgeschlagen"
    case "cancelled": return "Abgebrochen"
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
      case .notConfigured: return "Blackbox Request ist nicht eingerichtet (Einstellungen → Musik anfragen)."
      case .unauthorized: return "API-Key fehlt oder ist falsch."
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
  func request(kind: String, id: String) async throws -> BBRRequest {
    try await send("/api/requests", method: "POST",
                   body: ["kind": kind, "id": id, "requestedBy": "Blackbox iOS"])
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

  var body: some View {
    if inLibrary {
      Label("In der Mediathek", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
          Text("Trage unter Einstellungen → Musik anfragen die Adresse deines Blackbox-Request-Servers ein.")
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
                  prompt: "Songs, Interpreten, Alben, Genres")
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
          Button("Fertig") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          NavigationLink(value: BBRRoute.requests) {
            Label("Meine Anfragen", systemImage: "tray.full")
          }
        }
      }
    }
  }

  // MARK: Suchergebnisse

  @ViewBuilder
  private var resultSections: some View {
    if (scope == .all || scope == .artists), !model.result.artists.isEmpty {
      Section("Interpreten") {
        ForEach(model.result.artists) { a in
          NavigationLink(value: BBRRoute.artist(a.id)) { BBRArtistRow(artist: a) }
        }
      }
    }
    if (scope == .all || scope == .albums), !model.result.albums.isEmpty {
      Section("Alben") {
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
                BBRStateLabel(inLibrary: s.album.inLibrary == true, request: s.album.request).font(.caption)
              }
            }
          }
        }
      } header: {
        Text("Songs")
      } footer: {
        Text("Angefragt wird immer das ganze Album.")
      }
    }
  }

  // MARK: Genres

  @ViewBuilder
  private var genreSection: some View {
    let q = text.trimmingCharacters(in: .whitespaces).lowercased()
    let list = discover.genres.filter { q.isEmpty || $0.name.lowercased().contains(q) }
    Section("Genres") {
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
          Label("Nach Genre stöbern", systemImage: "square.grid.2x2")
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
          Text("In deiner Mediathek").font(.footnote).foregroundStyle(.green)
        } else if let r = artist.request {
          Text(BBRStatusText.text(r.status)).font(.footnote).foregroundStyle(BBRStatusText.color(r.status))
        } else if let n = artist.albums {
          Text("\(n) Alben").font(.footnote).foregroundStyle(.secondary)
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
          Text("Interpreten").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
        }
      }
      if !albums.isEmpty {
        Section("Top-Alben") {
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
        BBRStateLabel(inLibrary: album.inLibrary == true, request: album.request).font(.caption)
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
          Section("Titel") {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
              HStack {
                Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 26, alignment: .trailing)
                Text(t.title ?? "")
                Spacer()
                if let d = t.duration {
                  Text(String(format: "%d:%02d", d / 60, d % 60)).foregroundStyle(.secondary).monospacedDigit()
                }
              }
            }
          }
        }
      } else if let error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
    }
    .overlay { if album == nil, error == nil { ProgressView() } }
    .navigationTitle(album?.title ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  @ViewBuilder
  private func actionButton(_ a: BBRAlbum) -> some View {
    if a.inLibrary == true {
      Label("In deiner Mediathek", systemImage: "checkmark.circle.fill")
        .font(.headline).foregroundStyle(.green).padding(.top, 4)
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
  }

  private func send(_ a: BBRAlbum) async {
    sending = true
    defer { sending = false }
    do {
      try await BlackboxRequestClient().request(kind: "album", id: a.id)
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
                Label("\(missing.count) fehlende Alben anfragen", systemImage: "arrow.down.circle.fill")
                  .font(.headline).frame(maxWidth: 280, minHeight: 44)
              }
              .buttonStyle(.borderedProminent)
              .buttonBorderShape(.capsule)
              .disabled(sending)
            } else {
              Label("Alle Alben vorhanden", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
      Button("\(missing.count) Alben anfragen") { Task { await send() } }
      Button("Abbrechen", role: .cancel) {}
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
          } label: { Label("Entfernen", systemImage: "trash") }
          if r.status == "failed" || r.status == "notfound" {
            Button {
              Task { try? await BlackboxRequestClient().retry(r.id); await load() }
            } label: { Label("Erneut", systemImage: "arrow.clockwise") }
              .tint(.orange)
          }
        }
      }
    }
    .overlay {
      if !loaded { ProgressView() } else if items.isEmpty, error == nil {
        ContentUnavailableView("Keine Anfragen", systemImage: "tray",
                               description: Text("Angefragte Alben und Interpreten erscheinen hier."))
      }
    }
    .navigationTitle("Meine Anfragen")
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
      SettingsRow(title: "Adresse") {
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
      SettingsRow(title: "API-Key") {
        SecureField("optional", text: $apiKey)
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.never)
          .onChange(of: apiKey) { _, v in BlackboxRequestConfig.apiKey = v }
      }
      Button("Verbindung testen") {
        testResult = "Teste …"
        Task {
          do { testResult = try await BlackboxRequestClient().health() } catch { testResult = error.localizedDescription }
        }
      }
      .disabled(url.isEmpty)
      if let testResult {
        Text(testResult).font(.footnote).foregroundStyle(.secondary)
      }
      Button("Musik suchen & anfragen") { showSearch = true }
        .disabled(url.isEmpty)
      Button("Meine Anfragen") { showRequests = true }
        .disabled(url.isEmpty)
    }, footer: "Fehlende Alben und Interpreten über deinen Blackbox-Request-Server (NAS) laden. In der Suche erscheint dann „Nicht in deiner Mediathek“.",
    header: "Musik anfragen")
    .sheet(isPresented: $showSearch) { BlackboxRequestSearchView() }
    .sheet(isPresented: $showRequests) {
      NavigationStack {
        BlackboxRequestsListView()
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showRequests = false } } }
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
          Text("Nicht in deiner Mediathek").font(.title3.bold())
          Spacer()
          Button("Alle") { onOpenAll(model.query) }
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
              Text("Keine fehlenden Alben gefunden.")
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
          ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
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
    content.title = "Neu in deiner Mediathek"
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
      case .noAccount: return "Kein Konto aktiv."
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
          Text("Mediathek scannen")
          Spacer()
          if running { ProgressView() }
        }
      }
      .disabled(running)
      Button("Vollständigen Scan starten") { scan(full: true) }
        .disabled(running)
      if let message {
        Text(message).font(.footnote).foregroundStyle(.secondary)
      }
    }, footer: "Navidrome sucht nach neuen und geänderten Dateien. Der vollständige Scan liest alle Tags neu ein (dauert länger).",
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
