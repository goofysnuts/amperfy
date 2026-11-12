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
      Button("FireTV fernsteuern") {
        let nav = UINavigationController(rootViewController: FireTVRemoteVC())
        topViewController()?.present(nav, animated: true)
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
