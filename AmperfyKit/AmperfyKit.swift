//
//  AmperfyKit.swift
//  AmperfyKit
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

import AudioStreaming
import Foundation
import MediaPlayer
import os.log

@MainActor
public class AmperKit {
  static let name = "Amperfy"
  static var version: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
  }

  static var buildNumber: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
  }

  nonisolated public static let newestElementsFetchCount = 50
  public static let shared = AmperKit()

  public lazy var log = {
    OSLog(subsystem: "Amperfy", category: "AppDelegate")
  }()

  public lazy var networkMonitor: NetworkMonitorFacade = {
    let monitor = NetworkMonitor(notificationHandler: notificationHandler)
    monitor.start()
    return monitor
  }()

  private var metaManager = [AccountInfo: MetaManager]()
  public func getMeta(_ accountInfo: AccountInfo) -> MetaManager {
    if let manager = metaManager[accountInfo] {
      return manager
    } else {
      let account = storage.main.library.getAccount(info: accountInfo)
      let newManager = MetaManager(
        storage: storage,
        account: account,
        networkMonitor: networkMonitor,
        performanceMonitor: threadPerformanceMonitor,
        eventLogger: eventLogger,
        notificationHandler: notificationHandler,
        localNotificationManager: localNotificationManager
      )
      metaManager[accountInfo] = newManager
      return newManager
    }
  }

  public var allActiveMetas: [AccountInfo: MetaManager] {
    metaManager
  }

  public func resetMeta(_ accountInfo: AccountInfo) {
    metaManager[accountInfo] = nil
  }

  public lazy var threadPerformanceMonitor: ThreadPerformanceMonitor = {
    ThreadPerformanceObserver.shared
  }()

  public lazy var coreDataManager = {
    CoreDataPersistentManager()
  }()

  public lazy var storage = {
    PersistentStorage(coreDataManager: coreDataManager)
  }()

  public var settings: AmperfySettings {
    storage.settings
  }

  public var asyncStorage: AsyncCoreDataAccessWrapper {
    storage.async
  }

  @MainActor
  public lazy var eventLogger = {
    EventLogger(storage: storage)
  }()

  public lazy var notificationHandler: EventNotificationHandler = {
    EventNotificationHandler()
  }()

  @MainActor
  public lazy var player: PlayerFacade = {
    createPlayer()
  }()

  // internal player helper classes that interact only via player callbacks
  private var playerDownloadPreparationHandler: PlayerDownloadPreparationHandler?
  private var playerAudioSessionHandler: AudioSessionHandler?
  private var playerNowPlayingInfoCenterHandler: NowPlayingInfoCenterHandler?
  private var playerRemoteCommandCenterHandler: RemoteCommandCenterHandler?
  private var playerNotificationAdapter: PlayerNotificationAdapter?

  @MainActor
  private func createPlayer() -> PlayerFacade {
    playerAudioSessionHandler = AudioSessionHandler()
    let backendAudioPlayer = BackendAudioPlayer(
      createAudioStreamingPlayerCB: { AudioStreamingPlayer() },
      audioSessionHandler: playerAudioSessionHandler!,
      eventLogger: eventLogger,
      getBackendApiCB: { accountInfo in
        self.getMeta(accountInfo).backendApi
      },
      networkMonitor: networkMonitor,
      getPlayableDownloaderCB: { accountInfo in
        self.getMeta(accountInfo).playableDownloadManager
      },
      cacheProxy: storage.main.library,
      userStatistics: userStatistics
    )

    backendAudioPlayer.setStreamingMaxBitrates(to: StreamingMaxBitrates(
      wifi: storage.settings.user.streamingMaxBitrateWifiPreference,
      cellular: storage.settings.user.streamingMaxBitrateCellularPreference
    ))
    backendAudioPlayer.setStreamingTranscodings(to: StreamingTranscodings(
      wifi: storage.settings.user.streamingFormatWifiPreference,
      cellular: storage.settings.user.streamingFormatCellularPreference
    ))

    let playerData = storage.main.library.getPlayerData()
    let queueHandler = PlayQueueHandler(playerData: playerData)
    let curPlayer = AudioPlayer(
      coreData: playerData,
      queueHandler: queueHandler,
      backendAudioPlayer: backendAudioPlayer,
      settings: storage.settings,
      userStatistics: userStatistics
    )
    playerAudioSessionHandler!.musicPlayer = curPlayer
    playerAudioSessionHandler!.eventLogger = eventLogger
    playerAudioSessionHandler!.configureObserverForAudioSessionInterruption()
    backendAudioPlayer.triggerReinsertPlayableCB = curPlayer.play
    curPlayer.autoplayCB = { [weak self] song in
      guard let self, let accountInfo = song.account?.info else { return [] }
      return try await getMeta(accountInfo).librarySyncer.requestSimilarSongs(
        song: song,
        count: 99
      )
    }
    backendAudioPlayer.updateEqualizerEnabled(isEnabled: storage.settings.user.isEqualizerEnabled)
    backendAudioPlayer
      .updateEqualizerSetting(eqSetting: storage.settings.user.activeEqualizerSetting)
    backendAudioPlayer.updateReplayGainEnabled(isEnabled: storage.settings.user.isReplayGainEnabled)
    backendAudioPlayer.volume = storage.settings.user.playerVolume

    playerDownloadPreparationHandler = PlayerDownloadPreparationHandler(
      playerStatus: playerData,
      queueHandler: queueHandler,
      getPlayableDownloaderCB: { accountInfo in
        self.getMeta(accountInfo).playableDownloadManager
      }
    )
    curPlayer.addNotifier(notifier: playerDownloadPreparationHandler!)

    let facadeImpl = PlayerFacadeImpl(
      playerStatus: playerData,
      queueHandler: queueHandler,
      musicPlayer: curPlayer,
      library: storage.main.library,
      backendAudioPlayer: backendAudioPlayer,
      userStatistics: userStatistics
    )
    facadeImpl.isOfflineMode = storage.settings.user.isOfflineMode

    playerNowPlayingInfoCenterHandler = NowPlayingInfoCenterHandler(
      musicPlayer: curPlayer,
      backendAudioPlayer: backendAudioPlayer,
      nowPlayingInfoCenter: MPNowPlayingInfoCenter.default(),
      storage: storage, notificationHandler: notificationHandler,
      getArtworkDownloaderCB: { accountInfo in
        self.getMeta(accountInfo).artworkDownloadManager
      },
      getPlayableDownloaderCB: { accountInfo in
        self.getMeta(accountInfo).playableDownloadManager
      }
    )
    curPlayer.addNotifier(notifier: playerNowPlayingInfoCenterHandler!)
    playerRemoteCommandCenterHandler = RemoteCommandCenterHandler(
      musicPlayer: facadeImpl,
      backendAudioPlayer: backendAudioPlayer,
      getLibrarySyncerCB: { accountInfo in
        self.getMeta(accountInfo).librarySyncer
      },
      eventLogger: eventLogger,
      remoteCommandCenter: MPRemoteCommandCenter.shared()
    )
    playerRemoteCommandCenterHandler?.configureRemoteCommands()
    curPlayer.addNotifier(notifier: playerRemoteCommandCenterHandler!)
    playerNotificationAdapter = PlayerNotificationAdapter(notificationHandler: notificationHandler)
    curPlayer.addNotifier(notifier: playerNotificationAdapter!)

    return facadeImpl
  }

  @MainActor
  public lazy var libraryUpdater = {
    LibraryUpdater(storage: storage)
  }()

  public lazy var userStatistics = {
    storage.main.library.getUserStatistics(appVersion: Self.version)
  }()

  @MainActor
  public lazy var localNotificationManager = {
    LocalNotificationManager(userStatistics: userStatistics, storage: storage)
  }()
}

// MARK: - Blackbox: Sprache (Deutsch/Englisch, in den Einstellungen umschaltbar)

public enum BlackboxLanguage: String, CaseIterable, Sendable {
  case system, de, en

  public var label: String {
    switch self {
    case .system: return BBL("Systemsprache", en: "System language")
    case .de: return "Deutsch"
    case .en: return "English"
    }
  }
}

public enum BBLocale {
  private static let key = "blackbox.language"

  public static var setting: BlackboxLanguage {
    get { BlackboxLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
  }

  /// Einstellung zum Zeitpunkt des App-Starts
  public static let startSetting: BlackboxLanguage = setting

  /// beim Start festgelegt – ein Wechsel wird nach dem Neustart der App aktiv
  public static let isGerman: Bool = {
    switch startSetting {
    case .de: return true
    case .en: return false
    case .system: return Locale.preferredLanguages.first?.lowercased().hasPrefix("de") ?? false
    }
  }()
}

/// Text in beiden Sprachen direkt im Code
public func BBL(_ de: String, en: String) -> String { BBLocale.isGerman ? de : en }

/// Übersetzbarer Text mit Platzhaltern: T("\(n) Alben") -> Schlüssel "%@ Alben"
public struct BBText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
  public let key: String
  public let args: [String]

  public init(stringLiteral value: String) {
    key = value
    args = []
  }

  public init(stringInterpolation: Interpolation) {
    key = stringInterpolation.key
    args = stringInterpolation.args
  }

  public struct Interpolation: StringInterpolationProtocol, Sendable {
    var key = ""
    var args: [String] = []
    public init(literalCapacity: Int, interpolationCount: Int) {}
    public mutating func appendLiteral(_ literal: String) { key += literal }
    public mutating func appendInterpolation<V>(_ value: V) {
      key += "%@"
      args.append("\(value)")
    }
  }
}

/// Übersetzt deutsche bzw. englische Texte in die eingestellte Sprache
public func T(_ text: BBText) -> String {
  let table = BBLocale.isGerman ? BBTranslations.toGerman : BBTranslations.toEnglish
  var result = table[text.key] ?? text.key
  for arg in text.args {
    guard let range = result.range(of: "%@") else { break }
    result.replaceSubrange(range, with: arg)
  }
  return result
}

/// wie T(), für Texte in Variablen
public func TV(_ text: String) -> String {
  let table = BBLocale.isGerman ? BBTranslations.toGerman : BBTranslations.toEnglish
  return table[text] ?? text
}

public enum BBTranslations {
  /// (Deutsch, Englisch)
  static let pairs: [(String, String)] = BBTranslationTable.pairs
  public static let toGerman: [String: String] = {
    var d = [String: String]()
    for (de, en) in pairs where d[en] == nil { d[en] = de }
    return d
  }()

  public static let toEnglish: [String: String] = {
    var d = [String: String]()
    for (de, en) in pairs where d[de] == nil { d[de] = en }
    return d
  }()
}

enum BBTranslationTable {
  static let pairs: [(String, String)] = [
    ("Player-Fenster öffnen", "Open Player Window"),
    ("Player-Fenster schließen", "Close Player Window"),
    ("Mediathek/Mini-Player wechseln", "Switch Library/Mini Player"),
    ("Einstellungen …", "Settings…"),
    ("Steuerung", "Controls"),
    ("Problem auf GitHub melden", "Report an issue on GitHub"),
    ("Nächster Titel", "Next Track"),
    ("Vorheriger Titel", "Previous Track"),
    ("Vorspulen: ", "Skip Forward: "),
    ("Zurückspulen: ", "Skip Backward: "),
    ("Zum aktuellen Song", "Go to Current Song"),
    ("Wiedergabegeschwindigkeit", "Playback Rate"),
    ("Wiederholen", "Repeat"),
    ("Zufall", "Shuffle"),
    ("An", "On"),
    ("Aus", "Off"),
    ("Musik-/Podcast-Modus wechseln", "Switch Music/Podcast mode"),
    ("Schlaftimer", "Sleep Timer"),
    ("Pause um: %@", "Pause at: %@"),
    ("Pause am Ende von %@", "Pause at end of %@"),
    ("Ende des Songs oder der Podcast-Folge", "End of Song or Podcast Episode"),
    ("5 Minuten", "5 Minutes"),
    ("10 Minuten", "10 Minutes"),
    ("15 Minuten", "15 Minutes"),
    ("30 Minuten", "30 Minutes"),
    ("45 Minuten", "45 Minutes"),
    ("1 Stunde", "1 Hour"),
    ("2 Stunden", "2 Hours"),
    ("4 Stunden", "4 Hours"),
    ("Der Schlaftimer hat die Wiedergabe pausiert.", "Sleep Timer paused playback."),
    ("Wiedergabe/Pause", "Toggle Play and Pause"),
    ("Vorherigen spielen", "Play Previous"),
    ("Nächsten spielen", "Play Next"),
    ("Suche", "Search"),
    ("Zwischen Musik- und Podcast-Modus wechseln", "Switch between Music and Podcast mode"),
    ("Player öffnen/schließen", "Open/Close Player"),
    ("Als Nächstes", "Next in Queue"),
    ("Als Nächstes aus: %@", "Next from: %@"),
    ("Mediathek", "Library"),
    ("Zufällig abspielen", "Play Random"),
    ("Schnellaktionen", "Quick Actions"),
    ("Nicht verbunden", "Disconnected"),
    ("Playlists", "Playlists"),
    ("Home", "Home"),
    ("Geladen", "Cached"),
    ("Konto wechseln", "Switch Account"),
    ("Podcasts", "Podcasts"),
    ("Geladene Podcasts", "Cached Podcasts"),
    ("Genres", "Genres"),
    ("Geladene Genres", "Cached Genres"),
    ("Interpreten", "Artists"),
    ("Geladene Interpreten", "Cached Artists"),
    ("Lieblingsinterpreten", "Favorite Artists"),
    ("Geladene Lieblingsinterpreten", "Favorite Cached Artists"),
    ("Alben", "Albums"),
    ("Geladene Alben", "Cached Albums"),
    ("Lieblingsalben", "Favorite Albums"),
    ("Geladene Lieblingsalben", "Favorite Cached Albums"),
    ("Neueste Alben", "Newest Albums"),
    ("Neueste geladene Alben", "Newest Cached Albums"),
    ("Zuletzt gespielte Alben", "Recently Played Albums"),
    ("Zuletzt gespielte geladene Alben", "Recently Played Cached Albums"),
    ("Lieblingssongs", "Favorite Songs"),
    ("Geladene Lieblingssongs", "Favorite Cached Songs"),
    ("Radios", "Radios"),
    ("Geladene Mediathek", "Cached Library"),
    ("Geladene zufällig abspielen", "Play Random Cached"),
    ("Version", "Version"),
    ("Build-Nummer", "Build Number"),
    ("Offline-Modus", "Offline Mode"),
    ("Bildschirmsperre verhindern", "Prevent Screen Lock"),
    ("Allgemein", "General"),
    ("Einstellungen", "Settings"),
    ("Lizenzen", "Licenses"),
    ("Aktion: %@", "Action: %@"),
    ("Beispiel-URLs:", "Example URLs:"),
    ("Parameter:", "Parameters:"),
    ("Typ: %@", "Type: %@"),
    ("Beschreibung: %@", "Description: %@"),
    ("Standard: %@", "Default: %@"),
    ("X-Callback-URL-Dokumentation", "X-Callback-URL Documentation"),
    ("Standard-Cover erzeugen", "Generate Default Artworks"),
    ("Entwickler", "Developer"),
    ("Podcast-Folgen", "Podcast Episodes"),
    ("Erstsynchronisation", "Initial Sync"),
    ("Songs im Hintergrund synchronisieren", "Background song sync"),
    ("Geladene Songs", "Cached Songs"),
    ("Geladene Podcast-Folgen", "Cached Podcast Episodes"),
    ("Gesamtgröße des Caches", "Complete Cache Size"),
    ("Cache-Größenlimit", "Cache Size Limit"),
    ("Alle Songs der Mediathek laden", "Download all songs in library"),
    ("OK", "OK"),
    ("Geladene Songs und Podcast-Folgen löschen", "Delete downloaded songs and podcast episodes"),
    ("Cache löschen", "Delete Cache"),
    ("Löschen", "Delete"),
    ("Cache", "Cache"),
    ("Cover", "Artworks"),
    ("Nicht geprüfte Cover", "Not checked Artworks"),
    ("Geladene Cover", "Cached Artworks"),
    ("Größe des Cover-Caches", "Artwork Cache Size"),
    ("Alle Cover der Mediathek laden", "Download all artworks in library"),
    ("Alle geladenen Cover löschen", "Delete all downloaded artworks"),
    ("Cover-Download", "Artwork Download Settings"),
    ("Cover-Anzeige", "Artwork Display Settings"),
    ("Cover", "Artwork"),
    ("Cover-Download", "Artwork Download"),
    ("Cover-Anzeige", "Artwork Display"),
    ("Fehler und andere Ereignisse werden hier aufgelistet.", "Errors and other events will be listed here."),
    ("Ereignisprotokoll", "Event Log"),
    ("Problem oder Feedback an den Entwickler senden", "Send issue or feedback to developer"),
    ("E-Mail ist nicht eingerichtet oder kann nicht gesendet werden.", "Email is not configured in settings app or Amperfy is not able to send an email."),
    ("Protokoll exportieren", "Export log"),
    ("Support", "Support"),
    ("In die Zwischenablage kopieren", "Copy to Clipboard"),
    ("Erscheinungsbild", "Appearance"),
    ("System", "System"),
    ("Hell", "Light"),
    ("Dunkel", "Dark"),
    ("Haptisches Feedback", "Haptic Feedback"),
    ("Mini-Player immer im Vordergrund", "Mini Player Always on Top"),
    ("Spul-Tasten im Musik-Player", "Music Player Skip Buttons"),
    ("Songtext weich scrollen", "Lyrics Smooth Scrolling"),
    ("Detaillierte Informationen", "Detailed Information"),
    ("Songdauer", "Song Duration"),
    ("Albumdauer", "Album Duration"),
    ("Interpretendauer", "Artist Duration"),
    ("Sternebewertung anzeigen", "Show Star Rating"),
    ("Zufallstaste im Player ausblenden", "Disable Player Shuffle Button"),
    ("Toolbar-Player einklappen", "Collapse Toolbar Player"),
    ("Darstellung", "Display"),
    ("%@: Textgröße in Listen und Album-Rastern.", "%@: Size of the text in lists and album grids."),
    ("Die App nutzt die Textgröße aus den iOS-Einstellungen.", "Amperfy uses the text size from the iOS settings."),
    ("%@: Textgröße in der App.", "%@: Size of the text in Amperfy."),
    ("Systemtextgröße verwenden", "Use System Text Size"),
    ("Textgröße", "Text Size"),
    ("Standard", "Default"),
    ("Türkis", "Teal"),
    ("Grün", "Green"),
    ("Gelb", "Yellow"),
    ("Orange", "Orange"),
    ("Rot", "Red"),
    ("Pink", "Pink"),
    ("Lila", "Purple"),
    ("Blau", "Blue"),
    ("Icon-Familie", "Icon Family"),
    ("App-Icon", "App Icon"),
    ("App-Icon konnte nicht geändert werden", "Unable to Change App Icon"),
    ("%@-Wischaktion hinzufügen", "Add %@ swipe"),
    ("Abbrechen", "Cancel"),
    ("Nach rechts wischen", "Leading"),
    ("Nach links wischen", "Trailing"),
    ("Wischaktionen", "Swipe"),
    ("Equalizer aktivieren", "Enable Equalizer"),
    ("Aktiver Equalizer", "Active Equalizer"),
    ("Equalizer", "Equalizer"),
    ("Neuen Equalizer anlegen", "Create new Equalizer"),
    ("Name", "Name"),
    ("Sichern", "Save"),
    ("Equalizer löschen", "Delete Equalizer"),
    ("Equalizer bearbeiten", "Equalizer Editor"),
    ("ReplayGain aktivieren", "Enable ReplayGain"),
    ("Gleicht die Lautstärke anhand der ReplayGain-Informationen an.", "Automatically normalize track volume based on replay gain information for consistent loudness."),
    ("Gespielte Titel speichern und kommende vorab laden", "Auto-cache played tracks and download upcoming ones"),
    ("Gespielte Titel werden automatisch gespeichert. Die nächsten %@ Titel werden vorab geladen.", "Played tracks (songs and podcast episodes) are cached automatically. The next %@ tracks are downloaded in advance."),
    ("Song-Wiedergabe fortsetzen", "Song Playback Resume"),
    ("Merkt sich die Position, damit die Wiedergabe dort weitergeht.", "Keeps track of song progress so playback continues from the previously saved position."),
    ("Manuelle Wiedergabe", "Manual Playback"),
    ("Wiedergabe startet erst, wenn „Abspielen“ gedrückt wird.", "Enable to start playback only when the Play button is pressed."),
    ("Automatisch weiterspielen", "Autoplay After End"),
    ("Wenn die Warteschlange endet, laufen ähnliche Titel weiter (Radio).", "When the queue ends, automatically continue playback using Instant Mix to find similar songs."),
    ("Mobilfunk-Streaming\nFormat (Transcoding)", "Cellular Streaming\nFormat (Transcoding)"),
    ("Format für das Streaming über Mobilfunk. Transcoding wird für bessere Kompatibilität empfohlen.", "Select a transcoding format for streaming while using Cellular. Transcoding is recommended for better compatibility."),
    ("Mobilfunk-Streaming\nBitraten-Limit", "Cellular Streaming\nBitrate Limit"),
    ("Maximale Bitrate über Mobilfunk.", "Set the maximum streaming bitrate for Cellular."),
    ("WLAN-Streaming\nFormat (Transcoding)", "WiFi Streaming\nFormat (Transcoding)"),
    ("Format für das Streaming im WLAN. Transcoding wird für bessere Kompatibilität empfohlen.", "Select a transcoding format for streaming while on WiFi. Transcoding is recommended for better compatibility."),
    ("WLAN-Streaming\nBitraten-Limit", "WiFi Streaming\nBitrate Limit"),
    ("Maximale Bitrate im WLAN.", "Set the maximum streaming bitrate for WiFi."),
    ("Cache\nFormat (Transcoding)", "Cache\nFormat (Transcoding)"),
    ("Player & Stream", "Player & Stream"),
    ("Header hinzufügen", "Add Header"),
    ("Cloudflare-Access-Token hinzufügen", "Add Cloudflare Access Token"),
    ("Eigene HTTP-Header", "Custom HTTP Headers"),
    ("URL", "URL"),
    ("Benutzername", "Username"),
    ("Akzentfarbe", "Theme Color"),
    ("Neueste Songs", "Newest Songs"),
    ("Neueste Podcast-Folgen", "Newest Podcast Episodes"),
    ("Automatisch laden", "Auto Cache"),
    ("Gestreamte Songs scrobbeln", "Scrobble streamed Songs"),
    ("Alle gestreamten Songs melden, auch wenn der Server sie schon als gespielt markiert.", "Enable to scrobble all streamed songs, even if the server already marks them as played."),
    ("Server-API", "Backend API"),
    ("Server-API-Version", "Server API Version"),
    ("Client-API-Version", "Client API Version"),
    ("Server-Adressen verwalten", "Manage Server URLs"),
    ("Passwort ändern", "Update Password"),
    ("Mediathek neu synchronisieren", "Resync Library"),
    ("Neu synchronisieren", "Resync"),
    ("Abmelden", "Logout"),
    ("Konto", "Account"),
    ("Server-Adressen", "Server URLs"),
    ("Alternative Adresse hinzufügen", "Add alternative URL"),
    ("Hinzufügen", "Add"),
    ("In „Mediathek“ suchen", "Search in \"Library\""),
    ("Leeren", "Clear"),
    ("Kein Suchverlauf", "No Search History"),
    ("In „Podcasts“ suchen", "Search in \"Podcasts\""),
    ("Keine Podcasts", "No Podcasts"),
    ("Keine Podcast-Folgen", "No Podcast Episodes"),
    ("Podcasts nach Name", "Podcasts sorted by name"),
    ("Folgen nach Datum", "Episodes sorted by release date"),
    ("Bearbeiten", "Edit"),
    ("In „%@“ suchen", "Search in \"%@\""),
    ("Keine Playlists", "No Playlists"),
    ("Zuletzt gespielt", "Last time played"),
    ("Änderungsdatum", "Change date"),
    ("Dauer", "Duration"),
    ("Sortieren", "Sort"),
    ("Alle Playlists synchronisieren", "Sync All Playlists"),
    ("Alle Playlists wurden synchronisiert.", "All playlists have been synced."),
    ("Optionen", "Options"),
    ("In „Album“ suchen", "Search in \"Album\""),
    ("CD %@", "Disc %@"),
    ("Keine Radios", "No Radios"),
    ("Der Offline-Modus ist aktiv.", "Offline Mode is active."),
    ("Bisher", "Previous"),
    ("Als Nächstes", "Next from Queue"),
    ("Bewertung", "Rating"),
    ("Interpret", "Artist"),
    ("Jahr", "Year"),
    ("Liste", "Table"),
    ("Raster", "Grid"),
    ("Rastergröße ändern", "Change Grid Size"),
    ("Darstellung", "Style"),
    ("%@ laden", "Download %@"),
    ("Viele Songs", "Many Songs"),
    ("%@ Songs aus „%@“ wirklich herunterladen?", "Are you sure to add %@ songs from \"%@\" to download queue?"),
    ("Konto hinzufügen", "Add Account"),
    ("In „Genres“ suchen", "Search in \"Genres\""),
    ("Keine Genres", "No Genres"),
    ("Nicht bewertet", "Not rated"),
    ("In „Podcast“ suchen", "Search in \"Podcast\""),
    ("Passwort", "Password"),
    ("Anmelden", "Login"),
    ("Fertig", "Done"),
    ("Schließen", "Close"),
    ("Keine Server-Adresse angegeben!", "No server URL given!"),
    ("Bitte die Server-Adresse mit „https://“ oder „http://“ angeben.", "Please provide either 'https://' or 'http://' in your server URL."),
    ("Kein Benutzername angegeben!", "No username given!"),
    ("Kein Passwort angegeben!", "No password given!"),
    ("Konto ist schon vorhanden!", "Account already added!"),
    ("Anmeldung nicht möglich!", "Not able to login!"),
    ("Anmeldung fehlgeschlagen", "Login failed"),
    ("API wählen", "Select API"),
    ("Beschreibung", "Description"),
    ("Songtext", "Lyrics"),
    ("Der Songtext ist nicht mehr verfügbar.", "Lyrics are not available anymore."),
    ("Player-Info", "Player Info"),
    ("Fertige Downloads entfernen", "Clear finished downloads"),
    ("Fehlgeschlagene Downloads wiederholen", "Retry failed downloads"),
    ("Alle Downloads abbrechen", "Cancel all downloads"),
    ("In „Ordner“ suchen", "Search in \"Directories\""),
    ("Ordner", "Directories"),
    ("Keine Ordner", "No Directories"),
    ("Alben und Songs", "Albums and Songs"),
    ("Zufallsauswahl neu laden", "Refresh Randoms"),
    ("Synchronisation überspringen", "Skip Sync"),
    ("Ohne Erstsynchronisation ist die Mediathek unvollständig. Fehlendes wird später über Suche und Aktualisieren nachgeladen.", "Skipping initial sync results in an incomplete library. Missing library elements can later be synced via various search/update functionalities."),
    ("Überspringen", "Skip"),
    ("Keine Songs", "No Songs"),
    ("Favorisiert am", "Starred date"),
    ("Hinzugefügt am", "Date Added"),
    ("Auswählen", "Select"),
    ("Alle", "All"),
    ("Albuminterpreten", "Album Artists"),
    ("Filter", "Filter"),
    ("Interpreten, Alben und Songs", "Artists, Albums and Songs"),
    ("Ordner und Songs", "Directories and Songs"),
    ("Keine Ordner oder Songs", "No Directories or Songs"),
    ("In „Playlists“ suchen", "Search in \"Playlists\""),
    ("Einige Songs sind schon in dieser Playlist.", "Some Songs are already in this Playlist."),
    ("Duplikate hinzufügen", "Add Duplicates"),
    ("Duplikate überspringen", "Skip Duplicates"),
    ("Abspielen", "Play"),
    ("Musik-Warteschlange", "Music Queue"),
    ("Als Nächstes einfügen", "Insert Context Queue"),
    ("Ans Ende anhängen", "Append Context Queue"),
    ("In Benutzer-Warteschlange einfügen", "Insert User Queue"),
    ("An Benutzer-Warteschlange anhängen", "Append User Queue"),
    ("Als nächste Folge", "Insert Podcast Queue"),
    ("Folge anhängen", "Append Podcast Queue"),
    ("Kein Favorit mehr", "Unmark favorite"),
    ("Favorit", "Favorite"),
    ("Keine Bewertung", "No Rating"),
    ("1 Stern", "1 Star"),
    ("2 Sterne", "2 Stars"),
    ("3 Sterne", "3 Stars"),
    ("4 Sterne", "4 Stars"),
    ("5 Sterne", "5 Stars"),
    ("Bewertung: %@", "Rating: %@"),
    ("Zur Playlist", "Add to Playlist"),
    ("Album anzeigen", "Show Album"),
    ("Laden", "Download"),
    ("Auf dem Server löschen", "Delete on Server"),
    ("Die Podcast-Folge wirklich auf dem Server löschen?", "Are you sure to delete the podcast episode on the server?"),
    ("Teilen", "Share"),
    ("Website öffnen", "Go to Site"),
    ("Podcast-Beschreibung", "Show Podcast Description"),
    ("Folgen-Beschreibung", "Show Episode Description"),
    ("Songtext anzeigen", "Show Lyrics"),
    ("ID kopieren", "Copy ID to Clipboard"),
    ("%@ Songs zu „%@“ hinzufügen", "Add %@ Songs to \"%@\""),
    ("Songs zu „%@“ hinzufügen", "Add Songs to \"%@\""),
    ("Dieser Song ist schon in der Playlist.", "This Song is already in your Playlist."),
    ("Trotzdem hinzufügen", "Add Duplicate"),
    ("Die Playlist „%@“ wurde mit dem Server synchronisiert.", "The Playlist \"%@\" has been successfully synced to the server."),
    ("%@ Songs hinzuzufügen kann die Synchronisation verlangsamen.", "Adding %@ Songs to this Playlist may cause performance issues during server synchronization."),
    ("Trotzdem hinzufügen", "Add Songs Anyway"),
    ("Abbrechen", "Abort"),
    ("Player-Optionen", "Player Options"),
    ("Keine Musik", "No music playing"),
    ("Kein Podcast", "No podcast playing"),
    ("Visualizer-Stil", "Visualizer Style"),
    ("Player leeren", "Clear Player"),
    ("Benutzer-Warteschlange leeren", "Clear User Queue"),
    ("Songtext ausblenden", "Hide Lyrics"),
    ("Visualizer anzeigen", "Show Audio Visualizer"),
    ("Visualizer ausblenden", "Hide Audio Visualizer"),
    ("Warteschlange als Playlist sichern", "Add Context Queue to Playlist"),
    ("Zum aktuellen Titel", "Scroll to currently playing"),
    ("Automatisch erkennen", "Auto-Detect"),
    ("Einmal pro Sitzung laden (Änderungen erkennen)", "Download once per session (change detection)"),
    ("Nur einmal laden", "Download only once"),
    ("Nie", "Never"),
    ("Nur Cover aus den Tags", "Only ID3 tag artworks"),
    ("Nur Server-Cover", "Only server artworks"),
    ("Server-Cover bevorzugen", "Prefer server artwork over ID3 tag"),
    ("Cover aus den Tags bevorzugen", "Prefer ID3 tag over server artwork"),
    ("Immer", "Always"),
    ("Beim Laden", "When connected to charger"),
    ("Kein Limit (Standard)", "No Limit (default)"),
    ("Original", "Raw/Original"),
    ("Server wählt das Format", "Server chooses Codec"),
    ("Mehr Bass", "Increased Bass"),
    ("Weniger Bass", "Reduced Bass"),
    ("Mehr Höhen", "Increased Treble"),
    ("Abgeschlossen", "Completed"),
    ("Übersprungen", "Skipped"),
    ("Abgebrochen", "Aborted"),
    ("Ring", "Ring"),
    ("Wellenform", "Waveform"),
    ("Spektrum", "Spectrum Bars"),
    ("Generative Kunst", "Generative Art"),
    ("Kompakt", "Compact"),
    ("Groß", "Large"),
    ("Zufällige Alben", "Random Albums"),
    ("Zuletzt gespielte Playlists", "Recently Played Playlists"),
    ("Zufällige Interpreten", "Random Artists"),
    ("Zufällige Songs", "Random Songs"),
    ("Oft gespielte Alben", "Frequently Played Albums"),
    ("Aus dem Speicher entfernen", "Remove from Cache"),
    ("Zufällig abspielen", "Play shuffled"),
    ("In Benutzer-Warteschlange einfügen", "Insert in User Queue"),
    ("An Benutzer-Warteschlange anhängen", "Append to User Queue"),
    ("Als Nächstes einfügen", "Insert in Context Queue"),
    ("Ans Ende der Warteschlange", "Append to Context Queue"),
    ("Als nächste Folge", "Insert in Podcast Queue"),
    ("Folge anhängen", "Append to Podcast Queue"),
    ("Als Favorit markieren", "Mark as Favorite"),
    ("Downloads", "Downloads"),
    ("Fehler", "Error"),
    ("Info", "Info"),
    ("Verfügbar", "Available"),
    ("Auf dem Server gelöscht", "Deleted on server"),
    ("Podcast-Folge", "Podcast Episode"),
    ("Als Nächstes", "Next"),
    ("Download fehlgeschlagen", "Download failed"),
    ("Der Download hat zu lange gedauert. Bitte erneut versuchen.", "The download took too long. Please try again."),
    ("Keine Verbindung", "No Connectivity"),
    ("Ungültige Adresse", "Invalid URL"),
    ("Schon geladen", "Already Downloaded"),
    ("Laden fehlgeschlagen", "Fetch Failed"),
    ("Datei ist leer", "File is empty"),
    ("Synchronisiere", "Syncing"),
    ("Aktualisiere", "Updating"),
    ("Überspringen ›", "Skip >"),
    ("Als Nächstes aus:", "Next from:"),
    ("Name der neuen Playlist", "New playlist name"),
    ("Erstellen", "Create"),
    ("Genre", "Genre"),
    ("Zuletzt gespielt", "Recently Played"),
    ("Home-Überschrift", "Home heading"),
    ("Eigene Akzentfarbe", "Custom accent color"),
    ("Home-Bereiche bearbeiten", "Edit Home sections"),
    ("Ohne eigene Akzentfarbe gilt die Theme-Farbe des Kontos.", "Without a custom accent color, the account's theme color is used."),
    ("Konto hinzufügen", "Add Account"),
    ("Konten", "Accounts"),
    ("Wartet", "Waiting"),
    ("Suche Release", "Searching release"),
    ("Lädt", "Downloading"),
    ("Importiert", "Importing"),
    ("Verfügbar", "Available"),
    ("Nicht gefunden", "Not found"),
    ("Fehlgeschlagen", "Failed"),
    ("Abgebrochen", "Cancelled"),
    ("Blackbox Request ist nicht eingerichtet (Einstellungen → Musik anfragen).", "Blackbox Request is not set up (Settings → Request Music)."),
    ("API-Key fehlt oder ist falsch.", "API key is missing or wrong."),
    ("Teilweise (%@ von %@)", "Partial (%@ of %@)"),
    ("In der Mediathek", "In Library"),
    ("Trage unter Einstellungen → Musik anfragen die Adresse deines Blackbox-Request-Servers ein.", "Enter the address of your Blackbox Request server under Settings → Request Music."),
    ("Songs, Interpreten, Alben, Genres", "Songs, artists, albums, genres"),
    ("Fertig", "Done"),
    ("Meine Anfragen", "My Requests"),
    ("Interpreten", "Artists"),
    ("Alben", "Albums"),
    ("Songs", "Songs"),
    ("Angefragt wird immer das ganze Album.", "The whole album is always requested."),
    ("Nach Genre stöbern", "Browse by genre"),
    ("In deiner Mediathek", "In your library"),
    ("%@ Alben", "%@ albums"),
    ("Top-Alben", "Top Albums"),
    ("Titel", "Tracks"),
    ("%@ von %@ Titeln sind in deiner Mediathek.", "%@ of %@ tracks are in your library."),
    ("Ganzes Album neu laden?", "Reload entire album?"),
    ("Neu laden und ersetzen", "Reload and replace"),
    ("Abbrechen", "Cancel"),
    ("Das komplette Album wird heruntergeladen. Die vorhandenen Dateien dieses Albums werden danach ersetzt.", "The complete album will be downloaded. The existing files of this album will be replaced afterwards."),
    ("%@ von %@ Titeln in deiner Mediathek", "%@ of %@ tracks in your library"),
    ("Vorhandene Titel in der Mediathek öffnen", "Open available tracks in library"),
    ("In der Mediathek öffnen", "Open in Library"),
    ("%@ fehlende Alben anfragen", "Request %@ missing albums"),
    ("Alle Alben vorhanden", "All albums available"),
    ("%@ Alben anfragen", "Request %@ albums"),
    ("Entfernen", "Remove"),
    ("Erneut", "Retry"),
    ("Keine Anfragen", "No Requests"),
    ("Angefragte Alben und Interpreten erscheinen hier.", "Requested albums and artists appear here."),
    ("Adresse", "Address"),
    ("API-Key", "API key"),
    ("Verbindung testen", "Test connection"),
    ("Musik suchen & anfragen", "Search & request music"),
    ("Fehlende Alben und Interpreten über deinen Blackbox-Request-Server (NAS) laden. In der Suche erscheint dann „Nicht in deiner Mediathek“.", "Download missing albums and artists via your Blackbox Request server (NAS). Search then shows “Not in your library”."),
    ("Musik anfragen", "Request Music"),
    ("Nicht in deiner Mediathek", "Not in your library"),
    ("Alle", "All"),
    ("Keine fehlenden Alben gefunden.", "No missing albums found."),
    ("Neu in deiner Mediathek", "New in your library"),
    ("Kein Konto aktiv.", "No active account."),
    ("Mediathek scannen", "Scan library"),
    ("Vollständigen Scan starten", "Start full scan"),
    ("Navidrome sucht nach neuen und geänderten Dateien. Der vollständige Scan liest alle Tags neu ein (dauert länger).", "Navidrome looks for new and changed files. A full scan re-reads all tags (takes longer)."),
    ("Alle Titel und Alben als Liste", "All tracks and albums as a list"),
    ("Keine Biografie verfügbar (in Navidrome einen Last.fm-API-Key hinterlegen).", "No biography available (add a Last.fm API key in Navidrome)."),
    ("Zuletzt gesucht", "Recent searches"),
    ("Top-Treffer", "Top results"),
    ("Mehr anzeigen …", "Show more …"),
    ("Keine Spotify-Mixes", "No Spotify mixes"),
    ("Keine Mixes", "No mixes"),
    ("Schließen", "Close"),
    ("Deine Top-Interpreten", "Your Top Artists"),
    ("Deine Top-Songs", "Your Top Songs"),
    ("Deine Top-Alben", "Your Top Albums"),
    ("Playlist abspielen", "Play playlist"),
    ("Musik hinzufügen", "Add Music"),
    ("„%@“ wird als Nächstes gespielt.", "“%@” plays next."),
    ("  Jetzt ansehen ›  ", "  View now ›  "),
    ("Rückblick %@. %@", "Recap %@. %@"),
    ("Song des Tages", "Song of the Day"),
    ("Als Nächstes spielen", "Play Next"),
    ("Abspielen", "Play"),
    ("Song des Tages: %@ von %@", "Song of the day: %@ by %@"),
    ("FireTV suchen …", "Searching FireTV …"),
    ("Zurück", "Back"),
    ("Wiedergabe", "Play/Pause"),
    ("Weiter", "Next"),
    ("iPhone-Wiedergabe auf FireTV übertragen", "Transfer iPhone playback to FireTV"),
    ("Der FireTV muss an sein (FireLauncher) oder Blackbox geöffnet (gleiches WLAN).", "The FireTV must be on (FireLauncher) or Blackbox open (same Wi-Fi)."),
    ("IP-Adresse eingeben …", "Enter IP address …"),
    ("FireTV wählen", "Choose FireTV"),
    ("„%@“ ist nicht erreichbar.", "“%@” is not reachable."),
    ("FireTV-Adresse", "FireTV address"),
    ("IP-Adresse des FireTV, z. B. 192.168.30.21", "FireTV IP address, e.g. 192.168.30.21"),
    ("Verbinden", "Connect"),
    ("Verbunden", "Connected"),
    ("FireTV nicht erreichbar – ist er an und im selben WLAN?", "FireTV not reachable – is it on and in the same Wi-Fi?"),
    ("Wiedergabe läuft jetzt auf dem FireTV.", "Now playing on the FireTV."),
    ("Übertragung fehlgeschlagen.", "Transfer failed."),
    ("Wiedergabe auf dem FireTV fehlgeschlagen.", "Playback on the FireTV failed."),
    ("Öffnet das Album", "Opens the album"),
    ("Öffnet den Interpreten", "Opens the artist"),
    ("Favorit", "Favorite"),
    ("Mehr", "More"),
    ("Wiedergabegerät", "Playback device"),
    ("Schnelleinstellungen", "Quick settings"),
    ("Songtext", "Lyrics"),
    ("Wiedergabeliste", "Queue"),
    ("Schlaftimer", "Sleep Timer"),
    ("Zufall", "Shuffle"),
    ("Wiederholen", "Repeat"),
    ("Blackbox im Netzwerk", "Blackbox on the network"),
    ("AirPlay- oder Bluetooth-Gerät wählen", "Choose AirPlay or Bluetooth device"),
    ("Steht auf dem FireTV in Blackbox unter Einstellungen.", "Shown on the FireTV in Blackbox under Settings."),
    ("Scrobbeln", "Scrobble"),
    ("Gestreamte Titel an den Server melden (Wiedergabezähler, Rückblicke).", "Report streamed tracks to the server (play counts, recaps)."),
    ("Lautstärke anhand der Metadaten angleichen.", "Normalize volume based on metadata."),
    ("Fortlaufende Wiedergabe", "Autoplay"),
    ("Wenn die Warteschlange endet, laufen ähnliche Titel weiter (Radio).", "When the queue ends, similar tracks keep playing (radio)."),
    ("Wiedergabeliste geräteübergreifend synchronisieren", "Sync queue across devices"),
    ("Wiedergabe von anderem Gerät fortsetzen", "Resume playback from other device"),
    ("Speichert Warteschlange und Position auf dem Server (auch der FireTV nutzt das), damit du auf einem anderen Gerät weiterhören kannst.", "Saves queue and position on the server (the FireTV uses it too), so you can keep listening on another device."),
    ("WLAN", "Wi-Fi"),
    ("Mobilfunk", "Cellular"),
    ("Vom Server nicht unterstützt.", "Not supported by the server."),
    ("Keine gespeicherte Wiedergabeliste gefunden.", "No saved queue found."),
    ("Die Titel sind in der Mediathek noch nicht synchronisiert.", "The tracks are not synced to the library yet."),
    ("Fortgesetzt: %@%@", "Resumed: %@%@"),
    ("Zufällig", "Shuffle"),
    ("Herunterladen", "Download"),
    ("Schnellzugriff", "Quick access"),
    ("Spotify-Mixes", "Spotify Mixes"),
    ("Deine Mixes", "Your Mixes"),
    ("Deine Rückblicke", "Your Recaps"),
    ("Radio starten", "Start Radio"),
    ("Radio: %@", "Radio: %@"),
    ("Sprache", "Language"),
    ("Systemsprache", "System language"),
    ("Deutsch", "German"),
    ("Die Sprache wird nach einem Neustart der App vollständig übernommen.", "The language is fully applied after restarting the app."),
    ("Hörbücher", "Audiobooks"),
    ("Deine Playlists", "Your Playlists"),
  ]
}
