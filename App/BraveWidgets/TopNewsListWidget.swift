// Copyright 2023 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import WidgetKit
import SwiftUI
import CodableHelpers
import SDWebImageSwiftUI
import Shared
import DesignSystem
import os
import AVFoundation
import BraveWidgetsModels

struct TopNewsListWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "TopNewsListWidget", provider: TopNewsListWidgetProvider()) { entry in
      TopNewsListView(entry: entry)
    }
    .supportedFamilies([.systemMedium, .systemLarge])
    .configurationDisplayName("Top News")
    .description("Top News")
  }
}

private struct TopNewsListEntry: TimelineEntry {
  var date: Date
  var topics: [NewsTopic]?
}

private struct TopNewsListWidgetProvider: TimelineProvider {
  func getSnapshot(in context: Context, completion: @escaping (TopNewsListEntry) -> Void) {
    Task {
      let topics = try await fetchNewsTopics()
      Logger().warning("Got snapshot: \(topics.count, privacy: .public)")
      completion(.init(date: Date(), topics: topics))
    }
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<TopNewsListEntry>) -> Void) {
    Task {
      do {
        let grouping = context.family == .systemMedium ? 2 : 5
        var topics = try await fetchNewsTopics().splitEvery(grouping)
//        topics.removeAll(where: { $0.count != grouping })
        let entries: [TopNewsListEntry] = zip(topics, topics.indices).map({ topics, index in
            .init(date: Date().addingTimeInterval(TimeInterval(5*index)), topics: topics)
        })
        completion(.init(entries: entries, policy: .after(Date().addingTimeInterval(60*60))))
        Logger().warning("[News] Timeline success: \(topics.count, privacy: .public), context: \(context.family, privacy: .public)")
      } catch {
        completion(.init(entries: [], policy: .after(Date().addingTimeInterval(60*60))))
        Logger().error("[News] Timeline failure: \(error.localizedDescription, privacy: .public), context: \(context.family, privacy: .public)")
      }
    }
  }
  func placeholder(in context: Context) -> TopNewsListEntry {
    .init(date: Date(), topics: nil)
  }
}

private struct TopNewsListView: View {
  @Environment(\.pixelLength) var pixelLength
  @Environment(\.widgetFamily) var widgetFamily
  var entry: TopNewsListEntry
  
  var body: some View {
    if let topics = entry.topics, !topics.isEmpty {
      VStack(alignment: .leading, spacing: widgetFamily == .systemLarge ? 12 : 8) {
        HStack {
          HStack(spacing: 4) {
            Image(braveSystemName: "brave.logo")
              .font(.system(size: 12))
              .imageScale(.large)
              .foregroundColor(Color(.braveOrange))
            Text("Brave News")
              .foregroundColor(Color(.braveLabel))
              .font(.system(size: 14, weight: .bold, design: .rounded))
          }
          Spacer()
          Link(destination: URL(string: "\(BraveUX.appURLScheme)://shortcut?path=\(WidgetShortcut.braveNews.rawValue)")!) {
            Text("Read More")
              .foregroundColor(Color(.braveBlurpleTint))
              .font(.system(size: 13, weight: .semibold, design: .rounded))
          }
        }
        .padding(.horizontal)
        .padding(.vertical, widgetFamily == .systemLarge ? 12 : 8)
        .background(Color(.braveGroupedBackground))
        VStack(alignment: .leading, spacing: 8) {
          ForEach(topics.prefix(widgetFamily == .systemLarge ? 5 : 2)) { topic in
            HStack {
              Link(destination: topic.url) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(topic.title)
                    .lineLimit(widgetFamily == .systemLarge ? 3 : 2)
                    .font(.system(size: widgetFamily == .systemLarge ? 14 : 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                  Text(topic.publisherName)
                    .lineLimit(1)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                }
              }
              if let image = topic.image {
                Spacer()
                Color.clear
                  .aspectRatio(1, contentMode: .fit)
                  .frame(maxHeight: 50)
                  .overlay(
                    Image(uiImage: image)
                      .resizable()
                      .aspectRatio(contentMode: .fill)
                  )
                  .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                  .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.3), lineWidth: pixelLength))
              }
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal)
      }
      .padding(.bottom)
    } else {
      EmptyView()
    }
  }
}

import UIKit
import BraveShared

#if DEBUG
struct TopNewsListView_PreviewProvider: PreviewProvider {
  static let mockData: [NewsTopic] = {
    let data = try! Data(contentsOf: Bundle.main.url(forResource: "topics_news.en_US", withExtension: "json", subdirectory: nil)!)
    return prepareNewsTopics(data, limit: 5).map {
      var copy = $0
      let size: CGSize = .init(width: 200, height: 200)
      copy.image = UIGraphicsImageRenderer(size: size).image(actions: { context in
        context.cgContext.setFillColor(UIColor.orange.cgColor)
        context.fill(CGRect(size: size))
      })
      return copy
    }
  }()
  
  static var previews: some View {
    TopNewsListView(
      entry: .init(
        date: Date(),
        topics: mockData
      )
    )
    .previewContext(WidgetPreviewContext(family: .systemLarge))
    TopNewsListView(
      entry: .init(
        date: Date(),
        topics: Array(mockData.prefix(2))
      )
    )
    .previewContext(WidgetPreviewContext(family: .systemMedium))
  }
}
#endif
