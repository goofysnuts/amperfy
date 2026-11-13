//
//  LibraryElementDetailTableHeaderView.swift
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
import UIKit

typealias GetInfoCallback = () -> String

// MARK: - PlayShuffleInfoConfiguration

struct PlayShuffleInfoConfiguration {
  var infoCB: GetInfoCallback?
  var playContextCb: GetPlayContextCallback?
  var player: PlayerFacade
  let isInfoAlwaysHidden: Bool
  var customPlayName: String?
  var isShuffleHidden = false
  var isShuffleOnContextNeccessary: Bool = true
  var shuffleContextCb: GetPlayContextCallback?
  var isEmbeddedInOtherView: Bool = false
}

// MARK: - LibraryElementDetailTableHeaderView

class LibraryElementDetailTableHeaderView: UIView {
  @IBOutlet
  weak var playAllButton: UIButton!
  @IBOutlet
  weak var playShuffledButton: UIButton!
  @IBOutlet
  weak var infoContainerView: UIView!
  @IBOutlet
  weak var infoLabel: UILabel!

  static let frameHeight: CGFloat = 40.0 + margin.top + margin.bottom
  static let margin = UIView.defaultMarginMiddleElement

  private var config: PlayShuffleInfoConfiguration?

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = UIEdgeInsets(
      top: 0.0,
      left: UIView.defaultMarginX,
      bottom: 0.0,
      right: UIView.defaultMarginX
    )

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refresh()
      }
    )
  }

  public static func createTableHeader(
    rootView: BasicTableViewController,
    configuration: PlayShuffleInfoConfiguration
  )
    -> LibraryElementDetailTableHeaderView? {
    rootView.tableView.tableHeaderView = UIView(frame: CGRect(
      x: 0,
      y: 0,
      width: rootView.view.bounds.size.width,
      height: Self.frameHeight
    ))
    let genericDetailTableHeaderView = ViewCreator<LibraryElementDetailTableHeaderView>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: rootView.view.bounds.size.width,
        height: Self.frameHeight
      ))!
    genericDetailTableHeaderView.prepare(configuration: configuration)
    rootView.tableView.tableHeaderView?.addSubview(genericDetailTableHeaderView)
    return genericDetailTableHeaderView
  }

  func refresh() {
    guard let config = config else { return }
    if config.isEmbeddedInOtherView {
      layoutMargins = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
    } else {
      if traitCollection.horizontalSizeClass == .compact {
        layoutMargins = UIEdgeInsets(
          top: 0.0,
          left: UIView.defaultMarginCellX,
          bottom: 0.0,
          right: UIView.defaultMarginCellX
        )
      } else {
        layoutMargins = UIEdgeInsets(
          top: 0.0,
          left: UIView.defaultMarginX,
          bottom: 0.0,
          right: UIView.defaultMarginX
        )
      }
    }
    infoContainerView.isHidden = config
      .isInfoAlwaysHidden || (traitCollection.horizontalSizeClass == .compact)
    infoLabel.text = config.infoCB?() ?? ""
  }

  @IBAction
  func playAllButtonPressed(_ sender: Any) {
    Haptics.success.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    play(isShuffled: false)
  }

  @IBAction
  func addAllShuffledButtonPressed(_ sender: Any) {
    Haptics.success.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    shuffle()
  }

  private func play(isShuffled: Bool) {
    guard let playContext = config?.playContextCb?(), let player = config?.player else { return }
    isShuffled ? player.playShuffled(context: playContext) : player.play(context: playContext)
  }

  private func shuffle() {
    guard let player = config?.player else { return }
    if let shuffleContext = config?.shuffleContextCb?() {
      if config?.isShuffleOnContextNeccessary ?? true {
        player.playShuffled(context: shuffleContext)
      } else {
        player.play(context: shuffleContext)
      }
    } else {
      play(isShuffled: true)
    }
  }

  /// isShuffleOnContextNeccessary: In AlbumsVC the albums are shuffled, keep the order when shuffle button is pressed
  func prepare(configuration: PlayShuffleInfoConfiguration) {
    config = configuration
    playAllButton.setTitle(config?.customPlayName ?? "Play", for: .normal)
    playAllButton.layer.cornerRadius = 10.0
    playShuffledButton.setTitle(
      configuration.isShuffleOnContextNeccessary ? "Shuffle" : "Random",
      for: .normal
    )
    playShuffledButton.layer.cornerRadius = 10.0
    playShuffledButton.isHidden = configuration.isShuffleHidden
    if configuration.isEmbeddedInOtherView { applyBlackboxStyle() }
    activate()
    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refresh()
      }
    )
  }

  // MARK: Blackbox – round shuffle, white Play pill, round download (album/playlist details)

  private var blackboxRow: UIStackView?

  private func applyBlackboxStyle() {
    guard blackboxRow == nil, let container = playAllButton.superview?.superview else { return }
    playAllButton.superview?.isHidden = true
    infoContainerView.isHidden = true

    func round(_ name: String, label: String, action: @escaping () -> ()) -> UIButton {
      var c = UIButton.Configuration.filled()
      c.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold))
      c.baseBackgroundColor = UIColor.black.withAlphaComponent(0.35)
      c.baseForegroundColor = .white
      c.cornerStyle = .capsule
      let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
      b.accessibilityLabel = label
      b.widthAnchor.constraint(equalToConstant: 38).isActive = true
      b.heightAnchor.constraint(equalToConstant: 38).isActive = true
      return b
    }
    let shuffle = round("shuffle", label: T("Zufällig")) { [weak self] in
      guard let self else { return }
      Haptics.success.vibrate(isHapticsEnabled: self.appDelegate.storage.settings.user.isHapticsEnabled)
      self.shuffle()
    }
    var pc = UIButton.Configuration.filled()
    pc.title = config?.customPlayName ?? "Play"
    pc.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
    pc.imagePadding = 8
    pc.baseBackgroundColor = .white
    pc.baseForegroundColor = .black
    pc.cornerStyle = .capsule
    pc.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
      var a = a
      a.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
      return a
    }
    let play = UIButton(configuration: pc, primaryAction: UIAction { [weak self] _ in
      guard let self else { return }
      Haptics.success.vibrate(isHapticsEnabled: self.appDelegate.storage.settings.user.isHapticsEnabled)
      self.play(isShuffled: false)
    })
    play.heightAnchor.constraint(equalToConstant: 38).isActive = true
    let download = round("arrow.down", label: T("Herunterladen")) { [weak self] in
      guard let self, let context = self.config?.playContextCb?(),
            let info = context.playables.first?.account?.info else { return }
      self.appDelegate.getMeta(info).playableDownloadManager.download(objects: context.playables)
      Haptics.success.vibrate(isHapticsEnabled: self.appDelegate.storage.settings.user.isHapticsEnabled)
    }
    let row = UIStackView(arrangedSubviews: [shuffle, play, download])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 18
    row.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(row)
    NSLayoutConstraint.activate([
      row.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      play.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.42),
    ])
    blackboxRow = row
    // keep references for activate/deactivate
    blackboxPlay = play
    blackboxShuffle = shuffle
  }

  private weak var blackboxPlay: UIButton?
  private weak var blackboxShuffle: UIButton?

  func activate() {
    blackboxPlay?.isEnabled = true
    blackboxShuffle?.isEnabled = true
    playAllButton.isEnabled = true
    playShuffledButton.isEnabled = !(config?.isShuffleOnContextNeccessary ?? true) || appDelegate
      .storage.settings.user.isPlayerShuffleButtonEnabled
  }

  func deactivate() {
    blackboxPlay?.isEnabled = false
    blackboxShuffle?.isEnabled = false
    playAllButton.isEnabled = false
    playShuffledButton.isEnabled = false
  }
}
