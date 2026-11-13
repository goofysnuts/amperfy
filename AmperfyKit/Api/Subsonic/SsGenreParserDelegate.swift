//
//  SsGenreParserDelegate.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 25.04.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

import CoreData
import Foundation
import UIKit

class SsGenreParserDelegate: SsXmlLibParser {
  /// Blackbox: Genres ohne Songs (z. B. Reste gelöschter Dateien) nicht anzeigen
  private var currentSongCount: Int?

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )
    if elementName == "genre" {
      currentSongCount = attributeDict["songCount"].flatMap { Int($0) }
    }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    switch elementName {
    case "genre":
      let genreName = buffer
      if currentSongCount == 0 {
        if let empty = prefetch.prefetchedGenreDict[genreName] {
          library.deleteGenre(genre: empty)
          prefetch.prefetchedGenreDict[genreName] = nil
        }
      } else if prefetch.prefetchedGenreDict[genreName] != nil {
        // info already synced -> skip
      } else {
        let genre = library.createGenre(account: account)
        prefetch.prefetchedGenreDict[genreName] = genre
        genre.name = genreName
      }
      parsedCount += 1
    default:
      break
    }

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }
}
