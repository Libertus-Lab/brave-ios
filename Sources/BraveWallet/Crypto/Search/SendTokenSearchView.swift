// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI
import BraveCore
import Strings

struct SendTokenSearchView: View {
  @ObservedObject var sendTokenStore: SendTokenStore
  
  @Environment(\.presentationMode) @Binding private var presentationMode
  
  var network: BraveWallet.NetworkInfo
  
  var body: some View {
    TokenList(tokens: sendTokenStore.userAssets) { token in
      Button(action: {
        sendTokenStore.selectedSendToken = token
        presentationMode.dismiss()
      }) {
        TokenView(token: token, network: network)
      }
    }
    .navigationTitle(Strings.Wallet.searchTitle)
  }
}
