import CryptoKit
import Foundation
import UIKit

enum RemotePatchConfiguration {
    static let baseURL = URL(string: "https://importantly-finally-curtis-brakes.trycloudflare.com")!
    static let syncToken = "3105-sync-v1-custom-2026"
    static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
}
