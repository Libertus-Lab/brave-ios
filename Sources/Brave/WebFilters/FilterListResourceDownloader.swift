// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import Combine
import Data
import BraveCore
import Shared
import BraveShared
import os.log

/// An object responsible for fetching filer lists resources from multiple sources
public class FilterListResourceDownloader {
  /// A shared instance of this class
  ///
  /// - Warning: You need to wait for `DataController.shared.initializeOnce()` to be called before using this instance
  public static let shared = FilterListResourceDownloader()
  
  /// Object responsible for getting component updates
  private var adBlockService: AdblockService?
  /// The resource downloader that downloads our resources
  private let resourceDownloader: ResourceDownloader<BraveS3Resource>
  /// The filter list subscription
  private var filterListSubscription: AnyCancellable?
  /// Ad block service tasks per filter list UUID
  private var adBlockServiceTasks: [String: Task<Void, Error>]
  /// A marker that says if fetching has started
  private var startedFetching = false
  /// A list of loaded versions for the filter lists with the componentId as the key and version as the value
  private var loadedFilterListVersions: [String: String]
  
  /// A formatter that is used to format a version number
  private lazy var fileVersionDateFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "yyyy.MM.dd.HH.mm.ss"
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    return dateFormatter
  }()
  
  init(networkManager: NetworkManager = NetworkManager()) {
    self.resourceDownloader = ResourceDownloader(networkManager: networkManager)
    self.adBlockServiceTasks = [:]
    self.adBlockService = nil
    self.loadedFilterListVersions = [:]
  }
  
  public func loadCachedData() async {
    async let cachedFilterLists: Void = self.loadCachedFilterLists()
    async let cachedDefaultFilterList: Void = self.loadCachedDefaultFilterList()
    _ = await (cachedFilterLists, cachedDefaultFilterList)
  }
  
  @MainActor private func loadCachedFilterLists() async {
    FilterListStorage.shared.loadFilterListSettings()
    let filterListSettings = FilterListStorage.shared.allFilterListSettings
      
    await filterListSettings.asyncConcurrentForEach { setting in
      guard setting.isEnabled == true else { return }
      guard let componentId = setting.componentId else { return }
      
      // Try to load the filter list folder. We always have to compile this at start
      guard let folderURL = setting.folderURL, FileManager.default.fileExists(atPath: folderURL.path) else {
        return
      }
      
      await self.loadShields(
        fromComponentId: componentId, folderURL: folderURL, relativeOrder: setting.order?.intValue ?? 0
      )
    }
  }
  
  private func loadCachedDefaultFilterList() async {
    guard let folderURL = FilterListSetting.makeFolderURL(
      forFilterListFolderPath: Preferences.AppState.lastDefaultFilterListFolderPath.value
    ), FileManager.default.fileExists(atPath: folderURL.path) else {
      return
    }
    
    await loadShields(fromDefaultFilterListFolderURL: folderURL)
  }
  
  /// Start the resource subscriber.
  ///
  /// - Warning: You need to wait for `DataController.shared.initializeOnce()` to be called before invoking this method
  @MainActor public func start(with adBlockService: AdblockService) {
    self.adBlockService = adBlockService
    
    if let folderPath = adBlockService.shieldsInstallPath {
      didUpdateShieldComponent(folderPath: folderPath, adBlockFilterLists: adBlockService.regionalFilterLists ?? [])
    }
    
    adBlockService.shieldsComponentReady = { folderPath in
      guard let folderPath = folderPath else { return }
      
      Task { @MainActor in
        self.didUpdateShieldComponent(folderPath: folderPath, adBlockFilterLists: adBlockService.regionalFilterLists ?? [])
      }
    }
  }
  
  /// Invoked when shield components are loaded
  ///
  /// This function will start fetching data and subscribe publishers once if it hasn't already done so.
  @MainActor private func didUpdateShieldComponent(folderPath: String, adBlockFilterLists: [AdblockFilterListCatalogEntry]) {
    if !startedFetching && !adBlockFilterLists.isEmpty {
      startedFetching = true
      FilterListStorage.shared.loadFilterLists(from: adBlockFilterLists)
      
      self.subscribeToFilterListChanges()
      self.registerAllEnabledFilterLists()
    }
    
    // Store the folder path so we can load it from cache next time we launch quicker
    // than waiting for the component updater to respond, which may take a few seconds
    let folderURL = URL(fileURLWithPath: folderPath)
    let folderSubPath = FilterListSetting.extractFolderPath(fromFilterListFolderURL: folderURL)
    Preferences.AppState.lastDefaultFilterListFolderPath.value = folderSubPath
    
    Task {
      await self.loadShields(fromDefaultFilterListFolderURL: folderURL)
    }
  }
  
  /// Load shields with the given `AdblockService` folder `URL`
  private func loadShields(fromDefaultFilterListFolderURL folderURL: URL) async {
    let version = folderURL.lastPathComponent
    await AdBlockEngineManager.shared.set(scripletResourcesURL: folderURL.appendingPathComponent("resources.json"))
    
    // Lets add these new resources
    await AdBlockEngineManager.shared.add(
      resource: AdBlockEngineManager.Resource(type: .dat, source: .adBlock),
      fileURL: folderURL.appendingPathComponent("rs-ABPFilterParserData.dat"),
      version: version
    )
  }
  
  /// Subscribe to the UI changes on the `filterLists` so that we can save settings and register or unregister the filter lists
  private func subscribeToFilterListChanges() {
    // Subscribe to changes on the filter list states
    filterListSubscription = FilterListStorage.shared.$filterLists
      .sink { filterLists in
        DispatchQueue.main.async { [weak self] in
          for filterList in filterLists {
            self?.handleUpdate(to: filterList)
          }
        }
      }
  }
  
  /// Ensures settings are saved for the given filter list and that our publisher is aware of the changes
  @MainActor private func handleUpdate(to filterList: FilterList) {
    FilterListStorage.shared.handleUpdate(to: filterList)
    
    // Register or unregister the filter list depending on its toggle state
    if filterList.isEnabled {
      register(filterList: filterList)
    } else {
      unregister(filterList: filterList)
    }
  }
  
  /// Register all enabled filter lists
  @MainActor private func registerAllEnabledFilterLists() {
    for filterList in FilterListStorage.shared.filterLists {
      guard filterList.isEnabled else { continue }
      register(filterList: filterList)
    }
  }
  
  /// Register this filter list and start all additional resource downloads
  @MainActor private func register(filterList: FilterList) {
    guard adBlockServiceTasks[filterList.uuid] == nil else { return }
    guard let adBlockService = adBlockService else { return }
    guard let index = FilterListStorage.shared.filterLists.firstIndex(where: { $0.uuid == filterList.uuid }) else { return }

    adBlockServiceTasks[filterList.uuid] = Task { @MainActor in
      for await folderURL in await adBlockService.register(filterList: filterList) {
        guard let folderURL = folderURL else { continue }
        
        await self.loadShields(
          fromComponentId: filterList.entry.componentId, folderURL: folderURL, relativeOrder: index
        )
        
        // Save the downloaded folder for later (caching) purposes
        FilterListStorage.shared.set(folderURL: folderURL, forUUID: filterList.uuid)
      }
    }
  }
  
  /// Unregister, cancel all of its downloads and remove any `ContentBlockerManager` and `AdBlockEngineManager` resources for this filter list
  @MainActor private func unregister(filterList: FilterList) {
    adBlockServiceTasks[filterList.uuid]?.cancel()
    adBlockServiceTasks.removeValue(forKey: filterList.uuid)
    
    Task {
      await AdBlockEngineManager.shared.removeResources(
        for: .filterList(componentId: filterList.entry.componentId)
      )
    }
  }
  
  /// Handle the downloaded folder url for the given filter list. The folder URL should point to a `AdblockFilterList` resource
  /// This will also start fetching any additional resources for the given filter list given it is still enabled.
  private func loadShields(fromComponentId componentId: String, folderURL: URL, relativeOrder: Int) async {
    // Check if we're loading the new or old component. The new component has a file `list.txt`
    // Which we check the presence of.
    let filterListURL = folderURL.appendingPathComponent("list.txt", conformingTo: .text)
    guard FileManager.default.fileExists(atPath: filterListURL.relativePath) else {
      // We are loading the old component from cache. We don't want this file to be loaded.
      // When we download the new component we will then add it. We can scrap the old one.
      return
    }
    
    let version = folderURL.lastPathComponent
    let isModified = loadedFilterListVersions[componentId] != nil && loadedFilterListVersions[componentId] != version
    let hasCache = await ContentBlockerManager.shared.hasCache(for: .filterList(componentId: componentId))
    loadedFilterListVersions[componentId] = version
    
    // Compile this rule list if we haven't already or if the file has been modified
    if !hasCache || isModified {
      do {
        let filterSet = try String(contentsOf: filterListURL, encoding: .utf8)
        let jsonRules = AdblockEngine.contentBlockerRules(fromFilterSet: filterSet)
        
        try await ContentBlockerManager.shared.compile(
          encodedContentRuleList: jsonRules,
          for: .filterList(componentId: componentId),
          options: .all
        )
      } catch {
        ContentBlockerManager.log.error(
          "Failed to convert filter list `\(componentId)` to content blockers: \(error.localizedDescription)"
        )
      }
    }
      
    // Add or remove the filter list from the engine depending if it's been enabled or not
    if await FilterListStorage.shared.isEnabled(for: componentId) {
      await AdBlockEngineManager.shared.add(
        resource: AdBlockEngineManager.Resource(type: .ruleList, source: .filterList(componentId: componentId)),
        fileURL: filterListURL,
        version: folderURL.lastPathComponent, relativeOrder: relativeOrder
      )
    } else {
      await AdBlockEngineManager.shared.removeResources(for: .filterList(componentId: componentId))
    }
  }
}

/// Helpful extension to the AdblockService
private extension AdblockService {
  /// Register the filter list given by the uuid and streams its updates
  ///
  /// - Note: Cancelling this task will unregister this filter list from recieving any further updates
  @MainActor func register(filterList: FilterList) async -> AsyncStream<URL?> {
    return AsyncStream { continuation in
      registerFilterListComponent(filterList.entry, useLegacyComponent: false) { folderPath in
        guard let folderPath = folderPath else {
          continuation.yield(nil)
          return
        }
        
        let folderURL = URL(fileURLWithPath: folderPath)
        continuation.yield(folderURL)
      }
      
      continuation.onTermination = { @Sendable _ in
        self.unregisterFilterListComponent(filterList.entry, useLegacyComponent: true)
      }
    }
  }
}
