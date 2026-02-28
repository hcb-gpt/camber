import Foundation

enum AppConfig {
    /// The owner/operator name displayed throughout the app.
    /// Reads from UserDefaults key "ownerName", falling back to "Zack".
    static var ownerName: String {
        UserDefaults.standard.string(forKey: "ownerName") ?? "Zack"
    }
}
