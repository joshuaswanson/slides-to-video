import Foundation
import Observation

/// Settings that belong to this Mac, not to a project.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    public var uvPath: String {
        didSet { defaults.set(uvPath, forKey: "uvPath") }
    }

    public var packageSource: String {
        didSet { defaults.set(packageSource, forKey: "packageSource") }
    }

    public var localDevice: String {
        didSet { defaults.set(localDevice, forKey: "localDevice") }
    }

    public var customEndpoint: CustomEndpoint {
        didSet { defaults.set(try? JSONEncoder().encode(customEndpoint), forKey: "customEndpoint") }
    }

    init() {
        uvPath = defaults.string(forKey: "uvPath") ?? WorkerLaunch.findUV(preferred: nil)?.path ?? ""
        packageSource = defaults.string(forKey: "packageSource") ?? WorkerLaunch.defaultSource()
        localDevice = defaults.string(forKey: "localDevice") ?? "mps"
        customEndpoint = defaults.data(forKey: "customEndpoint").flatMap { try? JSONDecoder().decode(CustomEndpoint.self, from: $0) } ?? CustomEndpoint()
    }

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Slides to Video")
    }
}
