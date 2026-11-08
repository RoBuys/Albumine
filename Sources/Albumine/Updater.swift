import AppKit
import CryptoKit
import Foundation

/// Automatic updates from the GitHub releases of RoBuys/Albumine.
///
/// 1. Reads the latest release (GitHub API) and compares its version with the running one.
/// 2. Downloads `Albumine-<version>.zip` and its `.sig`, and checks the Ed25519 signature
///    with the public key below (the private key stays in the author's Keychain): an archive
///    that was not signed by the author is refused, even if it comes from GitHub.
/// 3. Unzips it, checks the bundle identifier, version and code signature.
/// 4. A small helper script waits for Albumine to quit, swaps the app bundle and relaunches it.
///    The user's data (~/Library/Application Support/Albumine) is never touched.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    /// Public key matching the private key used by `Resources/update-key.swift`.
    static let publicKey = "azE8lcoSyjreasyaTB4qJ1CqL0NzdQ3MQul63jnIVLc="
    static let feedURL = URL(string: "https://api.github.com/repos/RoBuys/Albumine/releases/latest")!

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let archive: URL
        let signature: URL?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var available: Release?
    /// Shows the update window (set when an update is found, or after a manual check).
    var showSheet = false
    /// Result of a manual check, shown in the window when no update is available.
    private(set) var upToDateMessage: String?
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "updateLastCheck") as? Date

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "updateAutomatic") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateAutomatic") }
    }

    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateSkipped") }
        set { UserDefaults.standard.set(newValue, forKey: "updateSkipped") }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: Checking

    /// At launch: at most once a day, silently.
    func checkAtLaunch() {
        if Self.isLocalTestFeed {
            // Local test (file:// feed): no daily limit, optional automatic install.
            Task {
                await check(manual: false)
                if ProcessInfo.processInfo.environment["ALBUMINE_TEST_AUTOINSTALL"] != nil, let r = available {
                    await install(r)
                }
            }
            return
        }
        guard automatic else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 20 * 3600 { return }
        Task { await check(manual: false) }
    }

    /// Test mode: feed read from a local file instead of GitHub.
    static var isLocalTestFeed: Bool {
        ProcessInfo.processInfo.environment["ALBUMINE_UPDATE_FEED"]?.hasPrefix("file://") == true
    }

    func check(manual: Bool) async {
        guard phase != .checking, phase != .downloading, phase != .installing else { return }
        phase = .checking
        upToDateMessage = nil
        defer { if phase == .checking { phase = .idle } }
        do {
            let release = try await fetchLatest()
            Debug.log("mise à jour : dernière version \(release.version), installée \(Self.currentVersion)")
            if !Self.isLocalTestFeed {
                lastCheck = Date()
                UserDefaults.standard.set(lastCheck, forKey: "updateLastCheck")
            }
            if Self.isNewer(release.version, than: Self.currentVersion),
               manual || release.version != skippedVersion {
                available = release
                showSheet = true
            } else if manual {
                available = nil
                upToDateMessage = "Albumine \(Self.currentVersion) est la version la plus récente."
                showSheet = true
            }
        } catch {
            Debug.log("mise à jour : vérification impossible — \(error)")
            if manual {
                phase = .failed("Impossible de vérifier les mises à jour : \(error.localizedDescription)")
                showSheet = true
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        let feed = ProcessInfo.processInfo.environment["ALBUMINE_UPDATE_FEED"].flatMap(URL.init(string:)) ?? Self.feedURL
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Albumine/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError("réponse \(http.statusCode) du serveur")
        }
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct GitHubRelease: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let r = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        guard let zip = r.assets.first(where: { $0.name == "Albumine-\(version).zip" }) else {
            throw UpdateError("la version \(version) ne contient pas d'archive installable")
        }
        let sig = r.assets.first { $0.name == zip.name + ".sig" }
        return Release(version: version, notes: r.body ?? "", page: r.html_url,
                       archive: zip.browser_download_url, signature: sig?.browser_download_url)
    }

    /// "1.10" > "1.9" > "1.0.1" > "1.0"
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func skip(_ release: Release) {
        skippedVersion = release.version
        showSheet = false
    }

    // MARK: Installing

    func install(_ release: Release) async {
        Debug.log("mise à jour : installation de \(release.version)")
        phase = .downloading
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("albumine-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            Debug.log("mise à jour : dossier \(work.path)")
            let zip = try await download(release.archive, to: work.appendingPathComponent("Albumine.zip"))
            Debug.log("mise à jour : archive téléchargée")

            // 1. Signature from the author (Ed25519).
            guard let sigURL = release.signature else { throw UpdateError("archive non signée : installation refusée") }
            let (sigData, _) = try await URLSession.shared.data(from: sigURL)
            let sigText = String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let signature = Data(base64Encoded: sigText),
                  let keyData = Data(base64Encoded: Self.trustedPublicKey),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  key.isValidSignature(signature, for: try Data(contentsOf: zip)) else {
                throw UpdateError("la signature de l'archive est invalide : installation refusée")
            }

            Debug.log("mise à jour : signature valide")
            // 2. Unzip and check what it contains.
            phase = .installing
            let extracted = work.appendingPathComponent("extracted")
            try await Self.runTool("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
            let newApp = extracted.appendingPathComponent("Albumine.app")
            guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info["CFBundleShortVersionString"] as? String == release.version else {
                throw UpdateError("l'archive ne contient pas Albumine \(release.version)")
            }
            try await Self.runTool("/usr/bin/codesign", ["--verify", "--deep", newApp.path])

            Debug.log("mise à jour : archive vérifiée")
            // 3. Swap the bundle once Albumine has quit, then relaunch.
            let target = Bundle.main.bundleURL
            let parent = target.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                NSWorkspace.shared.activateFileViewerSelecting([newApp])
                throw UpdateError("pas le droit d'écrire dans « \(parent.path) ». La nouvelle version est affichée dans le Finder : glissez-la vous-même dans Applications.")
            }
            let script = work.appendingPathComponent("install.sh")
            try """
            #!/bin/sh
            # Waits for Albumine to quit, swaps the application, relaunches it.
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
            TARGET="\(target.path)"
            rm -rf "$TARGET.previous"
            if mv "$TARGET" "$TARGET.previous" && mv "\(newApp.path)" "$TARGET"; then
              rm -rf "$TARGET.previous"
            else
              [ -d "$TARGET.previous" ] && [ ! -d "$TARGET" ] && mv "$TARGET.previous" "$TARGET"
            fi
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
            /usr/bin/open "$TARGET"
            rm -rf "\(work.path)"
            """.write(to: script, atomically: true, encoding: .utf8)
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
            launcher.arguments = ["-c", "nohup /bin/sh '\(script.path)' >/dev/null 2>&1 &"]
            try launcher.run()
            launcher.waitUntilExit()
            Debug.log("mise à jour : script lancé, fermeture")
            quitForUpdate()
        } catch {
            Debug.log("mise à jour : échec — \(error)")
            phase = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    /// Saves the library immediately, closes the update window and quits. An open sheet can
    /// keep AppKit from terminating, so the process exits by itself if it is still alive 3 s later
    /// (everything has been saved by then).
    private func quitForUpdate() {
        NotificationCenter.default.post(name: .albumineWillQuitForUpdate, object: nil)
        showSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    /// Public key used for verification (overridable in debug builds, for tests only).
    private static var trustedPublicKey: String {
        #if DEBUG
        if let k = ProcessInfo.processInfo.environment["ALBUMINE_UPDATE_PUBKEY"] { return k }
        #endif
        return publicKey
    }

    private func download(_ url: URL, to destination: URL) async throws -> URL {
        if url.isFileURL { // tests
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        }
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError("téléchargement impossible (réponse \(http.statusCode))")
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    private static func runTool(_ path: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw UpdateError("vérification de l'archive échouée (\((path as NSString).lastPathComponent))") }
        }.value
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

extension Notification.Name {
    /// Posted just before Albumine quits to install an update: pending data must be saved now.
    static let albumineWillQuitForUpdate = Notification.Name("albumineWillQuitForUpdate")
}
