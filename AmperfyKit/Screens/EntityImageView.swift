//
//  EntityImageView.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 20.02.22.
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

import Foundation
import UIKit

open class EntityImageView: UIView {
  @IBOutlet
  weak var singleImage: LibraryEntityImage!
  @IBOutlet
  weak var quadImage1: LibraryEntityImage!
  @IBOutlet
  weak var quadImage2: LibraryEntityImage!
  @IBOutlet
  weak var quadImage3: LibraryEntityImage!
  @IBOutlet
  weak var quadImage4: LibraryEntityImage!

  private var view: UIView!

  private var quadImages: [LibraryEntityImage] {
    [
      quadImage1,
      quadImage2,
      quadImage3,
      quadImage4,
    ]
  }

  required public init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    loadViewFromNib()
  }

  override public init(frame: CGRect) {
    super.init(frame: frame)
    loadViewFromNib()
  }

  public func loadViewFromNib() {
    let bundle = Bundle(for: type(of: self))
    let nib = UINib(nibName: String(describing: type(of: self)), bundle: bundle)
    let view = nib.instantiate(withOwner: self, options: nil).first as! UIView
    view.frame = bounds
    view.autoresizingMask = [
      UIView.AutoresizingMask.flexibleWidth,
      UIView.AutoresizingMask.flexibleHeight,
    ]
    addSubview(view)
    self.view = view

    backgroundColor = .clear

    layer.masksToBounds = true
    self.view.backgroundColor = .clear
    self.view.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    quadImages[0].layer.maskedCorners = [
      .layerMinXMinYCorner,
      .layerMaxXMinYCorner,
      .layerMinXMaxYCorner,
      .layerMaxXMaxYCorner,
    ]
    quadImages[0].layer.maskedCorners = [.layerMinXMinYCorner]
    quadImages[1].layer.maskedCorners = [.layerMaxXMinYCorner]
    quadImages[2].layer.maskedCorners = [.layerMinXMaxYCorner]
    quadImages[3].layer.maskedCorners = [.layerMaxXMaxYCorner]
  }

  public func display(
    theme: ThemePreference,
    container: PlayableContainable,
    cornerRadius: CornerRadius = .small
  ) {
    display(
      theme: theme,
      collection: container.getArtworkCollection(theme: theme),
      cornerRadius: cornerRadius
    )
    displayServerCoverIfAvailable(container: container)
  }

  // MARK: FireSonic – playlist covers from the server (Navidrome)

  private var coverOverlay: UIImageView?
  private var coverRequestKey: String?

  private func hideCoverOverlay() {
    coverRequestKey = nil
    coverOverlay?.isHidden = true
    coverOverlay?.image = nil
  }

  private func showCoverOverlay(_ image: UIImage) {
    let overlay: UIImageView
    if let coverOverlay {
      overlay = coverOverlay
    } else {
      overlay = UIImageView(frame: bounds)
      overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      overlay.contentMode = .scaleAspectFill
      overlay.clipsToBounds = true
      overlay.isUserInteractionEnabled = false
      addSubview(overlay)
      coverOverlay = overlay
    }
    bringSubviewToFront(overlay)
    overlay.image = image
    overlay.isHidden = false
  }

  private func displayServerCoverIfAvailable(container: PlayableContainable) {
    guard let playlist = container as? Playlist,
          let accountInfo = playlist.account?.info,
          let coverArtId = PlaylistCategoryRegistry.coverArtId(ofPlaylistId: playlist.id)
    else {
      hideCoverOverlay()
      return
    }
    let loader = PlaylistCoverLoader.shared
    if let cached = loader.cachedImage(coverArtId: coverArtId) {
      coverRequestKey = coverArtId
      showCoverOverlay(cached)
      return
    }
    hideCoverOverlay()
    coverRequestKey = coverArtId
    Task { @MainActor [weak self] in
      guard let image = await loader.image(coverArtId: coverArtId, accountInfo: accountInfo)
      else { return }
      guard let self, self.coverRequestKey == coverArtId else { return }
      self.showCoverOverlay(image)
    }
  }

  public func configureStyling(
    image: UIImage,
    imageSizeType: ArtworkIconSizeType,
    imageTintColor: UIColor,
    backgroundColor: UIColor
  ) {
    hideCoverOverlay()
    singleImage.tintColor = imageTintColor
    view.backgroundColor = backgroundColor
    view.layoutMargins = UIEdgeInsets(
      top: imageSizeType.rawValue,
      left: imageSizeType.rawValue,
      bottom: imageSizeType.rawValue,
      right: imageSizeType.rawValue
    )
    let modImage = image.withRenderingMode(.alwaysTemplate)
    singleImage.display(image: modImage)
  }

  private func display(
    theme: ThemePreference,
    collection: ArtworkCollection,
    cornerRadius: CornerRadius = .small
  ) {
    layer.cornerRadius = cornerRadius.asCGFloat
    quadImages.forEach { $0.isHidden = true }
    singleImage.isHidden = false

    if let quadEntities = collection.quadImageEntity {
      if quadEntities.count > 1 {
        // check if all images are the same
        if Set(quadEntities.compactMap { $0.artwork?.id }).count == 1 {
          singleImage.displayAndUpdate(entity: quadEntities.first!)
        } else {
          singleImage.isHidden = true
          quadImages.forEach {
            $0.display(image: UIImage.getGeneratedArtwork(theme: theme, artworkType: .song))
            $0.isHidden = false
          }
          for (index, entity) in quadEntities.enumerated() {
            guard index < quadImages.count else { break }
            quadImages[index].display(entity: entity)
          }
        }
      } else if let firstEntity = quadEntities.first {
        singleImage.displayAndUpdate(entity: firstEntity)
      } else {
        singleImage.display(artworkType: collection.defaultArtworkType)
      }
    } else if let singleEntity = collection.singleImageEntity {
      singleImage.displayAndUpdate(entity: singleEntity)
    } else {
      singleImage.display(artworkType: collection.defaultArtworkType)
    }
  }
}

// MARK: - PlaylistCoverLoader

/// FireSonic: loads playlist covers (getCoverArt with the playlist's coverArt id) and caches
/// them in memory and in the caches directory. Navidrome changes the coverArt id when the
/// image changes, so the id is a safe cache key.
@MainActor
public final class PlaylistCoverLoader {
  public static let shared = PlaylistCoverLoader()

  private let memory = NSCache<NSString, UIImage>()
  private var running = [String: Task<UIImage?, Never>]()
  private var failed = [String: Date]()

  private lazy var directory: URL = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("FireSonicPlaylistCovers", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  private func fileURL(coverArtId: String) -> URL {
    let safe = coverArtId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
    return directory.appendingPathComponent(String(safe) + ".img")
  }

  public func cachedImage(coverArtId: String) -> UIImage? {
    if let image = memory.object(forKey: coverArtId as NSString) { return image }
    if let data = try? Data(contentsOf: fileURL(coverArtId: coverArtId)),
       let image = UIImage(data: data) {
      memory.setObject(image, forKey: coverArtId as NSString)
      return image
    }
    return nil
  }

  public func image(coverArtId: String, accountInfo: AccountInfo) async -> UIImage? {
    if let cached = cachedImage(coverArtId: coverArtId) { return cached }
    if let failedAt = failed[coverArtId], Date().timeIntervalSince(failedAt) < 300 { return nil }
    if let task = running[coverArtId] { return await task.value }

    let api = AmperKit.shared.getMeta(accountInfo).backendApi
    let target = fileURL(coverArtId: coverArtId)
    let task = Task<UIImage?, Never> {
      guard let url = try? await api.generateUrl(forArtworkId: coverArtId) else { return nil }
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      var items = components?.queryItems ?? []
      if !items.contains(where: { $0.name == "size" }) {
        items.append(URLQueryItem(name: "size", value: "600"))
        components?.queryItems = items
      }
      var request = URLRequest(url: components?.url ?? url)
      request.timeoutInterval = 30
      for (key, value) in api.httpHeaders {
        request.setValue(value, forHTTPHeaderField: key)
      }
      guard let result = try? await URLSession.shared.data(for: request) else { return nil }
      let data = result.0
      let statusCode = (result.1 as? HTTPURLResponse)?.statusCode ?? 200
      guard statusCode < 300, let image = UIImage(data: data) else { return nil }
      try? data.write(to: target, options: .atomic)
      return await image.byPreparingForDisplay() ?? image
    }
    running[coverArtId] = task
    let image = await task.value
    running[coverArtId] = nil
    if let image {
      memory.setObject(image, forKey: coverArtId as NSString)
    } else {
      failed[coverArtId] = Date()
    }
    return image
  }
}
