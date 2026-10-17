import CryptoKit
import Foundation
import UIKit

enum RemotePatchConfiguration {
    // TODO: replace with your deployed remote-patch-site HTTPS URL
    static let baseURL = URL(string: "https://YOUR-REMOTE-SITE.example.com")!
    static let syncToken = "3105-sync-v1-custom-2026"
    static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
}
