// Copyright 2023 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import BraveCore

public enum Web3Service: String {
  case solana
  case ethereum
  case ethereumOffchain
  
  public var id: String { rawValue }
}

@MainActor public class DecentralizedDNSHelper {
  
  private let rpcService: BraveWalletJsonRpcService
  private let ipfsApi: IpfsAPI?
  
  public init(
    rpcService: BraveWalletJsonRpcService,
    ipfsApi: IpfsAPI?
  ) {
    self.rpcService = rpcService
    self.ipfsApi = ipfsApi
  }
  
  public enum DNSLookupResult {
    case none
    case loadInterstitial(Web3Service)
    case load(URL)
  }
  
  public func lookup(domain: String) async -> DNSLookupResult {
    if domain.endsWithSupportedENSExtension {
      return await lookupENS(domain: domain)
    } else if domain.endsWithSupportedSNSExtension {
      return await lookupSNS(domain: domain)
    }
    return .none
  }
  
  /// Decentralized DNS lookup for an ENS domain
  private func lookupENS(domain: String) async -> DNSLookupResult {
    let ensResolveMethod = await rpcService.ensResolveMethod()
    switch ensResolveMethod {
    case .ask:
      return .loadInterstitial(.ethereum)
    case .enabled:
      let (contentHash, isOffchainConsentRequired, status, _) = await rpcService.ensGetContentHash(domain)
      if isOffchainConsentRequired {
        return .loadInterstitial(.ethereumOffchain)
      }
      if status == .success,
         !contentHash.isEmpty,
         let ipfsUrl = ipfsApi?.contentHashToCIDv1URL(for: contentHash) {
        return .load(ipfsUrl)
      }
      return .none
    case .disabled:
      return .none
    @unknown default:
      return .none
    }
  }
  
  /// Decentralized DNS lookup for an SNS domain
  private func lookupSNS(domain: String) async -> DNSLookupResult {
    let snsResolveMethod = await rpcService.snsResolveMethod()
    switch snsResolveMethod {
    case .ask:
      return .loadInterstitial(.solana)
    case .enabled:
      let (url, status, _) = await rpcService.snsResolveHost(domain)
      guard status == .success, let url else {
        return .none
      }
      return .load(url)
    case .disabled:
      return .none
    @unknown default:
      return .none
    }
  }
  
  public static func canHandle(domain: String) -> Bool {
    domain.endsWithSupportedENSExtension || domain.endsWithSupportedSNSExtension
  }
}
