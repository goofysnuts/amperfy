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

  /// beim Start festgelegt – ein Wechsel wird nach dem Neustart der App aktiv
  public static let isGerman: Bool = {
    switch setting {
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
  ]
}
