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
import Collections

struct TopNewsWidget: Widget {
  var supportedFamilies: [WidgetFamily] {
    if #available(iOS 16.0, *) {
      return [.systemSmall, .accessoryRectangular]
    } else {
      return [.systemSmall]
    }
  }
  
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "TopNewsWidget", provider: TopNewsWidgetProvider()) { entry in
      TopNewsView(entry: entry)
    }
    .supportedFamilies(supportedFamilies)
    .configurationDisplayName("Top News")
    .description("Top News")
  }
}

private struct TopNewsEntry: TimelineEntry {
  var date: Date
  var topic: NewsTopic?
}

private struct TopNewsWidgetProvider: TimelineProvider {
  func getSnapshot(in context: Context, completion: @escaping (TopNewsEntry) -> Void) {
    Task {
      let topics = try await fetchNewsTopics(limit: 1)
      completion(.init(date: Date(), topic: topics.first))
    }
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<TopNewsEntry>) -> Void) {
    Task {
      do {
        let topics = try await fetchNewsTopics()
        os_log("Downloaded topics: \(topics.count, privacy: .public)")
        let entries: [TopNewsEntry] = zip(topics, topics.indices).map({ topic, index in
            .init(date: Date().addingTimeInterval(TimeInterval(5*index)), topic: topic)
        })
        os_log("Topics entries: \(String(describing: entries), privacy: .public)")
        completion(.init(entries: entries, policy: .after(Date().addingTimeInterval(60*60))))
      } catch {
        os_log("Failed to download topics: \(error.localizedDescription, privacy: .public)")
        completion(.init(entries: [], policy: .after(Date().addingTimeInterval(60*60))))
      }
    }
  }
  func placeholder(in context: Context) -> TopNewsEntry {
    .init(date: Date(), topic: nil)
  }
}

private struct TopNewsView: View {
  @Environment(\.widgetFamily) private var widgetFamily
  var entry: TopNewsEntry
  
  var body: some View {
    if #available(iOS 16.0, *) {
      if widgetFamily == .accessoryRectangular {
        LockScreenTopNewsView(entry: entry)
      } else {
        WidgetTopNewsView(entry: entry)
      }
    } else {
      WidgetTopNewsView(entry: entry)
    }
  }
}

private struct LockScreenTopNewsView: View {
  var entry: TopNewsEntry
  
  var body: some View {
    if let topic = entry.topic {
      VStack(alignment: .leading, spacing: 2) {
        Text(topic.title)
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .lineSpacing(0)
          .layoutPriority(2)
          .multilineTextAlignment(.leading)
        HStack(spacing: 3) {
          Image(braveSystemName: "brave.logo")
            .foregroundColor(.orange)
            .font(.system(size: 12))
            .padding(.trailing, -1)
          Divider()
            .frame(height: 11)
          Text("\(topic.publisherName)")
            .lineLimit(1)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.secondary)
            .minimumScaleFactor(0.75)
        }
        .foregroundColor(.secondary)
      }
      .allowsTightening(true)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
//      .background(Color.black.opacity(0.2))
      .widgetURL(topic.url)
    } else {
      Text("")
    }
  }
}

private struct WidgetTopNewsView: View {
  var entry: TopNewsEntry
  
  var body: some View {
    if let topic = entry.topic {
      VStack(alignment: .leading) {
        HStack() {
          Image(braveSystemName: "brave.logo")
            .font(.footnote)
            .imageScale(.large)
            .foregroundColor(Color(.braveOrange))
            .padding(4)
            .background(Color(.white).clipShape(Circle()).shadow(color: .black.opacity(0.2), radius: 2, y: 1))
        }
        Spacer()
        VStack(alignment: .leading, spacing: 4) {
          Text(topic.title)
            .shadow(radius: 2, y: 1)
            .lineLimit(3)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .allowsTightening(true)
          Text(topic.publisherName)
            .shadow(radius: 2, y: 1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.95))
        }
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .background(
        Group {
          if let image = topic.image {
            Image(uiImage: image)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .overlay(
                LinearGradient(
                  colors: [.black.opacity(0.0), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom
                )
              )
          } else {
            LinearGradient(braveGradient: .darkGradient01)
          }
        }
      )
      .widgetURL(topic.url)
    } else {
      Text("Failed to load")
    }
  }
}

extension JSONDecoder {
  static var topicsDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .formatted({
      let df = DateFormatter()
      df.dateFormat = "yyyy-MM-dd HH:mm:ss"
      return df
    }())
    return decoder
  }
}

func fetchNewsTopics(limit: Int = 10) async throws -> [NewsTopic] {
  let url = URL(string: "https://brave-today-cdn.brave.software/news-topic-clustering/topics_news.en_US.json")!
  let (data, _): (Data, URLResponse) = try await withCheckedThrowingContinuation { c in
    URLSession(configuration: .ephemeral)
      .dataTask(with: URLRequest(url: url)) { data, response, error in
        if let data, let response {
          c.resume(returning: (data, response))
          return
        }
        if let error {
          c.resume(throwing: error)
        }
      }
      .resume()
  }
  return prepareNewsTopics(data, limit: limit)
}

func prepareNewsTopics(_ data: Data, limit: Int) -> [NewsTopic] {
  do {
    let topics = Dictionary(
      grouping: try JSONDecoder.topicsDecoder.decode([FailableDecodable<NewsTopic>].self, from: data).compactMap(\.wrappedValue).sorted(by: >),
      by: \.topicIndex
    )
    let maxCount = topics.values.map(\.count).max() ?? 0
    var articles: OrderedSet<NewsTopic> = .init()
    for i in 0..<maxCount {
      for key in topics.keys.sorted() {
        if let article = topics[key]?[safe: i] {
          articles.append(article)
        }
      }
    }
//    var articles = topics.reduce(into: OrderedSet<NewsTopic>(), {
//        if let value = $1.1.sorted(by: >).first {
//          $0.append(value)
//        }
//      })
//    if articles.count < 6 {
//      // Try and backfill
//
//    }
//    repeat {
//      for (index, inout topics) in topics {
//        topics.removeFirst()
//      }
//    } while articles.count < limit && !topics.isEmpty
    let articles2 = try articles
//      .sorted(by: >)
      .prefix(limit)
      .map {
        var copy = $0
        if let imageURL = $0.imageURL {
          // Download images
          if let image = UIImage(data: try Data(contentsOf: imageURL)) {
            let size = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(width: 400, height: 400)).size
            if #available(iOS 15.0, *) {
              copy.image = image.preparingThumbnail(of: size)
            } else {
              copy.image = image.scale(toSize: size)
            }
          }
        }
        return copy
      }
    Logger().warning("[News] Downloaded news topics: \(topics.count, privacy: .public)")
    return Array(articles2)
  } catch {
    Logger().error("[News] Failed to prepare news topics: \(error.localizedDescription, privacy: .public)")
    return []
  }
}

struct NewsTopic: Decodable, Comparable, Identifiable, Hashable {
  var topicIndex: Int
  var title: String
  var description: String
  var url: URL
  @URLString var imageURL: URL?
  var image: UIImage?
  var publisherName: String
  var date: Date
  var score: Double
  var category: String
  
  enum CodingKeys: String, CodingKey {
    case topicIndex = "topic_index"
    case title
    case description
    case url
    case imageURL = "img"
    case publisherName = "publisher_name"
    case date = "publish_time"
    case score
    case category
  }
  
  static func < (lhs: Self, rhs: Self) -> Bool {
    return lhs.score < rhs.score
  }
  
  var id: String {
    url.absoluteString
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(url)
  }
  
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.url == rhs.url
  }
}

#if DEBUG
struct TopNewsView_PreviewProvider: PreviewProvider {
  private static var entry: TopNewsEntry {
    .init(
      date: Date(),
      topic: .init(
        topicIndex: 0,
        title: "Jacinda Ardern resignation – live: Shock as New Zealand prime minister announces decision",
        description: "Ardern became the world’s youngest female head of government when she was elected prime minister at age 37 in 2017",
        url: URL(string: "https://www.independent.co.uk/news/world/australasia/jacinda-ardern-resignation-new-zealand-polls-prime-minister-b2265025.html")!,
        imageURL: URL(string: "https://static.independent.co.uk/2023/01/19/01/NUEVA_ZELANDA_ELECCIONES_98401.jpg?width=1200&auto=webp")!,
        publisherName: "The Independent World News",
        date: {
          let df = DateFormatter()
          df.dateFormat = "yyyy-MM-dd HH:mm:ss"
          return df.date(from: "2023-01-19 15:48:54")!
        }(),
        score: 3.94501334,
        category: "World News"
      )
    )
  }
  static var previews: some View {
    TopNewsView(
      entry: entry
    )
    .previewContext(WidgetPreviewContext(family: .systemSmall))
    if #available(iOS 16.0, *) {
      TopNewsView(entry: entry)
        .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
    }
  }
}
#endif
