import Cocoa
import Foundation

// MARK: - Update State

enum UpdateState {
    case idle
    case checking
    case available(String)
    case downloading
    case installing
    case upToDate
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return ""
        case .checking: return "Checking for updates..."
        case .available(let version): return "Update available: \(version)"
        case .downloading: return "Downloading update..."
        case .installing: return "Installing update..."
        case .upToDate: return "You're up to date!"
        case .error(let msg): return msg
        }
    }
}

// MARK: - AppUpdater

class AppUpdater {
    static let shared = AppUpdater()
    private let repoURL = "https://api.github.com/repos/iamshakibali/pin-top/releases/latest"
    private var stateHandler: ((UpdateState) -> Void)?

    var currentState: UpdateState = .idle {
        didSet { DispatchQueue.main.async { self.stateHandler?(self.currentState) } }
    }

    func checkForUpdates(onStateChange: ((UpdateState) -> Void)? = nil) {
        stateHandler = onStateChange
        currentState = .checking

        guard let url = URL(string: repoURL) else {
            currentState = .error("Invalid update URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                self.currentState = .error("Check failed: \(error.localizedDescription)")
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                self.currentState = .error("Couldn't parse release info")
                return
            }

            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

            guard Self.compareVersions(latestVersion, currentVersion) > 0 else {
                self.currentState = .upToDate
                return
            }

            // Find the .zip asset download URL
            guard let assets = json["assets"] as? [[String: Any]],
                  let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let downloadURLString = zipAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                self.currentState = .error("No download asset found")
                return
            }

            self.currentState = .available(latestVersion)
            self.downloadAndInstall(from: downloadURL)
        }
        task.resume()
    }

    // ponytail: simple semver compare — split on ".", compare each component as Int.
    // Doesn't handle pre-release tags (alpha/beta/rc), add when those become relevant.
    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va > vb ? 1 : -1 }
        }
        return 0
    }

    private func downloadAndInstall(from url: URL) {
        currentState = .downloading

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self else { return }

            if let error {
                self.currentState = .error("Download failed: \(error.localizedDescription)")
                return
            }

            guard let tempURL else {
                self.currentState = .error("Download returned no file")
                return
            }

            self.installUpdate(from: tempURL)
        }
        task.resume()
    }

    private func installUpdate(from zipURL: URL) {
        currentState = .installing

        // Extract zip to a temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pintop-update-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            currentState = .error("Couldn't create temp directory")
            return
        }

        // Use ditto to extract (handles macOS zip format reliably)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, tempDir.path]

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }

            guard proc.terminationStatus == 0 else {
                self.currentState = .error("Extraction failed")
                return
            }

            // Find the extracted .app bundle
            let fileManager = FileManager.default
            guard let contents = try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil),
                  let newAppURL = contents.first(where: { $0.pathExtension == "app" }) else {
                self.currentState = .error("No .app found in update")
                return
            }

            // Replace the running app: create a helper script that waits for
            // us to quit, swaps the bundle, and relaunches.
            guard let currentAppURL = Bundle.main.bundleURL as URL? else {
                self.currentState = .error("Couldn't locate current app bundle")
                return
            }

            let scriptPath = tempDir.appendingPathComponent("update.sh")
            let script = """
            #!/bin/bash
            sleep 2
            rm -rf "\(currentAppURL.path)"
            mv "\(newAppURL.path)" "\(currentAppURL.path)"
            open "\(currentAppURL.path)"
            rm -rf "\(tempDir.path)"
            """

            do {
                try script.write(to: scriptPath, atomically: true, encoding: .utf8)
                let fm = FileManager.default
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

                let launchTask = Process()
                launchTask.executableURL = URL(fileURLWithPath: "/bin/bash")
                launchTask.arguments = [scriptPath.path]
                try launchTask.run()

                // Quit the app so the script can replace it
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            } catch {
                self.currentState = .error("Install failed: \(error.localizedDescription)")
            }
        }

        do {
            try process.run()
        } catch {
            currentState = .error("Couldn't start extraction")
        }
    }
}
