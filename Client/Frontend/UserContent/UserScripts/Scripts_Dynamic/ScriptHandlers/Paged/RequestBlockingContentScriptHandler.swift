// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import Shared
import WebKit
import BraveCore
import BraveShared
import Data

class RequestBlockingContentScriptHandler: TabContentScript {
  private struct RequestBlockingDTO: Decodable {
    struct RequestBlockingDTOData: Decodable, Hashable {
      let resourceType: AdblockEngine.ResourceType
      let resourceURL: String
      let sourceURL: String
    }
    
    let securityToken: String
    let data: RequestBlockingDTOData
  }
  
  static let scriptName = "RequestBlockingScript"
  static let scriptId = UUID().uuidString
  static let messageHandlerName = "\(scriptName)_\(messageUUID)"
  static let scriptSandbox: WKContentWorld = .page
  static let userScript: WKUserScript? = {
    guard var script = loadUserScript(named: scriptName) else {
      return nil
    }
    
    return WKUserScript.create(source: secureScript(handlerName: messageHandlerName,
                                                    securityToken: scriptId,
                                                    script: script),
                               injectionTime: .atDocumentStart,
                               forMainFrameOnly: false,
                               in: scriptSandbox)
  }()
  
  private weak var tab: Tab?
  
  init(tab: Tab) {
    self.tab = tab
  }
  
  func userContentController(_ userContentController: WKUserContentController, didReceiveScriptMessage message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
    guard let tab = tab, let currentTabURL = tab.webView?.url else {
      assertionFailure("Should have a tab set")
      return
    }
    
    if !verifyMessage(message: message) {
      assertionFailure("Invalid security token. Fix the `RequestBlocking.js` script")
      replyHandler(false, nil)
      return
    }

    do {
      let data = try JSONSerialization.data(withJSONObject: message.body)
      let dto = try JSONDecoder().decode(RequestBlockingDTO.self, from: data)
      
      // Because javascript urls allow some characters that `URL` does not,
      // we use `NSURL(idnString: String)` to parse them
      guard let requestURL = NSURL(idnString: dto.data.resourceURL) as URL? else { return }
      guard let sourceURL = NSURL(idnString: dto.data.sourceURL) as URL? else { return }
      let isPrivateBrowsing = PrivateBrowsingManager.shared.isPrivateBrowsing
      
      Task { @MainActor in
        let domain = Domain.getOrCreate(forUrl: currentTabURL, persistent: !isPrivateBrowsing)
        guard let domainURLString = domain.url else { return }
        let shouldBlock = await AdBlockStats.shared.shouldBlock(requestURL: requestURL, sourceURL: sourceURL, resourceType: dto.data.resourceType)
        
        if shouldBlock, Preferences.PrivacyReports.captureShieldsData.value,
           let domainURL = URL(string: domainURLString),
           let blockedResourceHost = requestURL.baseDomain,
           !PrivateBrowsingManager.shared.isPrivateBrowsing {
          PrivacyReportsManager.pendingBlockedRequests.append((blockedResourceHost, domainURL, Date()))
        }

        if shouldBlock && !tab.contentBlocker.blockedRequests.contains(requestURL) {
          BraveGlobalShieldStats.shared.adblock += 1
          let stats = tab.contentBlocker.stats
          tab.contentBlocker.stats = stats.adding(adCount: 1)
          tab.contentBlocker.blockedRequests.insert(requestURL)
        }
        
        replyHandler(shouldBlock, nil)
      }
    } catch {
      assertionFailure("Invalid type of message. Fix the `RequestBlocking.js` script")
      replyHandler(false, nil)
    }
  }
}
