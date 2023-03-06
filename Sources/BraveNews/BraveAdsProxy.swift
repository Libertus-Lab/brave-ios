// Copyright 2023 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

/// A set of Ads related APIs that News needs to handle
public struct BraveAdsProxy {
  public var initialize: @Sendable () async -> Void
  public var isAdsServiceRunning: () -> Bool
  public var purgeOrphanedInlineAdEvents: @Sendable () async -> Void
  public var fetchInlineContentAd: @Sendable () async -> InlineContentAd?
  
  public init(
    initialize: @escaping @Sendable () async -> Void,
    isAdsServiceRunning: @escaping () -> Bool,
    purgeOrphanedInlineAdEvents: @escaping @Sendable () async -> Void,
    fetchInlineContentAd: @escaping @Sendable () async -> BraveAdsProxy.InlineContentAd?
  ) {
    self.initialize = initialize
    self.isAdsServiceRunning = isAdsServiceRunning
    self.purgeOrphanedInlineAdEvents = purgeOrphanedInlineAdEvents
    self.fetchInlineContentAd = fetchInlineContentAd
  }
}

extension BraveAdsProxy {
  public struct InlineContentAd: Hashable {
    public var placementId: String
    public var creativeInstanceId: String
    public var title: String
    public var message: String
    public var imageURL: String
    public var dimensions: String
    public var ctaText: String
    public var targetURL: String
    
    public init(
      placementId: String,
      creativeInstanceId: String,
      title: String,
      message: String,
      imageURL: String,
      dimensions: String,
      ctaText: String,
      targetURL: String
    ) {
      self.placementId = placementId
      self.creativeInstanceId = creativeInstanceId
      self.title = title
      self.message = message
      self.imageURL = imageURL
      self.dimensions = dimensions
      self.ctaText = ctaText
      self.targetURL = targetURL
    }
  }
}
