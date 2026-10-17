import Foundation

enum AppVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development" }
    static var label: String { "Real \(version)" }
    static var diagnosticLabel: String { "\(label) (\(build))" }
}
