/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import CoreData
import Shared
func getDate(_ dayOffset: Int) -> Date {
  let calendar = Calendar(identifier: Calendar.Identifier.gregorian)
  let nowComponents = calendar.dateComponents([Calendar.Component.year, Calendar.Component.month, Calendar.Component.day], from: Date())
  let today = calendar.date(from: nowComponents)!
  return (calendar as NSCalendar).date(byAdding: NSCalendar.Unit.day, value: dayOffset, to: today, options: [])!
}

public final class History: NSManagedObject, WebsitePresentable, CRUD {

  @NSManaged public var title: String?
  @NSManaged public var url: String?
  @NSManaged public var visitedOn: Date?
  @NSManaged public var syncUUID: UUID?
  @NSManaged public var domain: Domain?
  @NSManaged public var sectionIdentifier: String?

  static let thisMonth = getDate(-31)
  // MARK: - Public interface

  public class func add(_ title: String, url: URL) {
    DataController.perform { context in
      var item = History.getExisting(url, context: context)
      if item == nil {
        item = History(entity: History.entity(context), insertInto: context)
        item?.domain = Domain.getOrCreateInternal(
          url, context: context,
          saveStrategy: .delayedPersistentStore)
        item?.url = url.absoluteString
      }
      item?.title = title
      item?.domain?.visits += 1
      item?.visitedOn = Date()
    }
  }

  public func delete() {
    delete(context: .new(inMemory: false))
  }

  public class func deleteAll(_ completionOnMain: @escaping () -> Void) {
    DataController.perform { context in
      History.deleteAll(context: .existing(context), includesPropertyValues: false)
      Domain.deleteNonBookmarkedAndClearSiteVisits() {
        completionOnMain()
      }
    }
  }

  /// Obtain the last N pages that were visited by the user
  public class func suffix(_ maxLength: Int) throws -> [History] {
    let fetchRequest = NSFetchRequest<History>()
    let context = DataController.viewContext

    fetchRequest.entity = History.entity(context)
    fetchRequest.fetchBatchSize = max(20, maxLength)
    fetchRequest.fetchLimit = maxLength
    fetchRequest.sortDescriptors = [NSSortDescriptor(key: "visitedOn", ascending: false)]

    return try context.fetch(fetchRequest)
  }

  /// Fetching the History items for migration
  /// The last month's data is being displayed to user
  /// so data in this period data fetched from old history for migration
  /// - Parameters:
  ///   - context: Managed Object Context
  /// - Returns: Return old history items from core data
  public class func fetchMigrationHistory(_ context: NSManagedObjectContext? = nil) -> [History] {
    let predicate = NSPredicate(format: "visitedOn >= %@", History.thisMonth as CVarArg)
    let sortDescriptors = [NSSortDescriptor(key: "visitedOn", ascending: false)]

    return all(where: predicate, sortDescriptors: sortDescriptors, context: context ?? DataController.viewContext) ?? []
  }
}

// MARK: - Internal implementations

extension History {
  // Currently required, because not `syncable`
  static func entity(_ context: NSManagedObjectContext) -> NSEntityDescription {
    return NSEntityDescription.entity(forEntityName: "History", in: context)!
  }

  class func getExisting(_ url: URL, context: NSManagedObjectContext) -> History? {
    let urlKeyPath = #keyPath(History.url)
    let predicate = NSPredicate(format: "\(urlKeyPath) == %@", url.absoluteString)

    return first(where: predicate, context: context)
  }
}
