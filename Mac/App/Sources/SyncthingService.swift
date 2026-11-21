// Reuses or starts the local Syncthing engine independently of its GUI and adapts
// every REST interaction through the Rust core's syncthing.* actions.
// Discovery probes mirror Windows/App/SyncthingService.cs.
import Foundation

struct SyncthingConnection: Equatable, Sendable {
    var endpoint: String
    var apiKey: String
    var certificatePem: String

    var dict: JSON {
        ["endpoint": endpoint, "api_key": apiKey, "certificate_pem": certificatePem]
    }
}

@MainActor
final class SyncthingService {
    private(set) var connection: SyncthingConnection?
    private(set) var discoveryError: String?
    private var discovered = false
    private var ensuring: Task<SyncthingConnection, Error>?
    private var ensuringID = UUID()
    private var ensuringStamp = ""
    private var cachedStamp = ""
    private var cacheUntil = Date.distantPast

    private func configStamp() -> String {
        let pref = PrefStore.shared.preferences
        let path = pref.syncthingConfigPath.isEmpty ? (Self.findConfig() ?? "") : pref.syncthingConfigPath
        func stamp(_ path: String) -> String {
            let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)|\(modified)"
        }
        return path + "|" + stamp(path) + "|" + stamp((path as NSString).deletingLastPathComponent + "/https-cert.pem")
    }

    func invalidate() { cacheUntil = .distantPast; cachedStamp = ""; discovered = false }

    /// Loads the connection from the preferred config.xml. Results are cached
    /// until `rediscover()`. Automatic calls use the shared engine manager below.
    func discover(force: Bool = false) {
        if discovered && !force { return }
        discovered = true
        connection = nil
        discoveryError = nil

        let preferences = PrefStore.shared.preferences
        if preferences.syncthingManual {
            let key = Keychain.syncthingAPIKey()
            if key.isEmpty {
                discoveryError = "Enter the API key in Sync settings for a manual connection."
                return
            }
            connection = SyncthingConnection(endpoint: preferences.syncthingEndpoint,
                                             apiKey: key, certificatePem: "")
            return
        }

        let configPath = preferences.syncthingConfigPath.isEmpty
            ? SyncthingService.findConfig()
            : preferences.syncthingConfigPath
        guard let configPath, FileManager.default.fileExists(atPath: configPath) else {
            discoveryError = "Syncthing is being set up. Refresh Sync to finish connecting."
            return
        }
        do {
            let config = try ConfigXMLParser.parse(path: configPath)
            guard config.enabled else {
                discoveryError = "Syncthing's local GUI/API is disabled."
                return
            }
            guard !config.apiKey.isEmpty else {
                discoveryError = "This file does not contain Syncthing GUI settings."
                return
            }
            var address = config.address.isEmpty ? "127.0.0.1:8384" : config.address
            address = address
                .replacingOccurrences(of: "0.0.0.0:", with: "127.0.0.1:")
                .replacingOccurrences(of: "[::]:", with: "[::1]:")
            let scheme = config.tls ? "https" : "http"
            let endpoint = address.contains("://") ? address : "\(scheme)://\(address)/"
            var certificatePem = ""
            if config.tls {
                let certificate = URL(fileURLWithPath: (configPath as NSString).deletingLastPathComponent)
                    .appendingPathComponent("https-cert.pem")
                certificatePem = (try? String(contentsOf: certificate, encoding: .utf8)) ?? ""
            }
            connection = SyncthingConnection(endpoint: endpoint, apiKey: config.apiKey,
                                             certificatePem: certificatePem)
        } catch {
            discoveryError = error.localizedDescription
        }
    }

    func rediscover() {
        invalidate()
        discover()
    }

    nonisolated static func findConfig() -> String? {
        let candidates = [
            Paths.home.appendingPathComponent("Library/Application Support/Syncthing/config.xml").path,
            Paths.home.appendingPathComponent(".config/syncthing/config.xml").path,
            Paths.home.appendingPathComponent(".local/state/syncthing/config.xml").path,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private var lastEngineContact = Date.distantPast

    func call(_ action: String, payload: JSON = [:], timeout: TimeInterval = 45) async throws -> Any? {
        let connection = try await ensureRunning()
        do {
            let response = try await CoreBridge.shared.call(action: "syncthing." + action,
                                                request: ["syncthing": connection.dict,
                                                          "payload": payload,
                                                          "data_dir": Paths.dataDir.path],
                                                timeout: timeout)
            lastEngineContact = Date()
            return response
        }
        catch {
            if !(error is CancellationError) { invalidate() }
            throw error // Never automatically replay a mutation with an uncertain outcome.
        }
    }

    func checkBackgroundEngine() async {
        guard !PrefStore.shared.preferences.syncthingManual, ensuring == nil,
              Date().timeIntervalSince(lastEngineContact) >= 60 else { return }
        lastEngineContact = Date()
        _ = try? await ensureRunning(checkHealth: true)
    }

    private func ensureRunning(checkHealth: Bool = false) async throws -> SyncthingConnection {
        if PrefStore.shared.preferences.syncthingManual {
            discover()
            guard let connection else { throw CoreError(message: discoveryError ?? "Check the manual Syncthing connection.") }
            return connection
        }
        let stamp = configStamp()
        if !checkHealth, let connection, stamp == cachedStamp, Date() < cacheUntil { return connection }
        if let ensuring {
            let previousID = ensuringID, previousStamp = ensuringStamp
            let c = try await ensuring.value
            if ensuringID == previousID { self.ensuring = nil }
            if previousStamp == stamp, stamp == configStamp() {
                connection = c; cachedStamp = stamp; cacheUntil = Date().addingTimeInterval(300)
                return c
            }
            return try await ensureRunning()
        }
        let configPath = PrefStore.shared.preferences.syncthingConfigPath
        let task = Task<SyncthingConnection, Error> {
            guard let result = try await CoreBridge.shared.call(action: "engine.ensure",
                request: ["data_dir": Paths.dataDir.path, "payload": ["config_path": configPath]],
                timeout: 180) as? JSON else {
                throw CoreError(message: "Cannot read the background engine connection.")
            }
            let c = result.dict("connection")
            return SyncthingConnection(endpoint: c.str("endpoint"), apiKey: c.str("api_key"),
                                       certificatePem: c.str("certificate_pem"))
        }
        ensuring = task
        let requestID = UUID(); ensuringID = requestID; ensuringStamp = stamp
        defer { if ensuringID == requestID { ensuring = nil } }
        do {
            let c = try await task.value
            connection = c
            if stamp == configStamp() { cachedStamp = stamp; cacheUntil = Date().addingTimeInterval(300) }
            discoveryError = nil
            discovered = true
            return c
        } catch {
            discoveryError = error.localizedDescription
            throw error
        }
    }

    func snapshot(timeout: TimeInterval = 30) async throws -> Snapshot {
        guard let raw = try await call("snapshot", timeout: timeout) else {
            throw CoreError(message: "Syncthing returned an empty status.")
        }
        return Snapshot(from: raw)
    }
}

/// Minimal XMLParser for Syncthing's config.xml gui section.
final class ConfigXMLParser: NSObject, XMLParserDelegate {
    struct Result {
        var enabled = true
        var tls = false
        var address = ""
        var apiKey = ""
    }
    private var result = Result()
    private var insideGUI = false
    private var currentElement = ""

    static func parse(path: String) throws -> Result {
        guard let parser = XMLParser(contentsOf: URL(fileURLWithPath: path)) else {
            throw CoreError(message: "Cannot read Syncthing's config.xml.")
        }
        let delegate = ConfigXMLParser()
        parser.delegate = delegate
        guard parser.parse() else {
            throw CoreError(message: "Syncthing's config.xml could not be parsed. Pick a different config file in Settings.")
        }
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "gui" {
            insideGUI = true
            result.enabled = attributes["enabled"] != "false"
            result.tls = attributes["tls"] == "true"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideGUI else { return }
        switch currentElement {
        case "address": result.address += string
        case "apikey": result.apiKey += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        if elementName == "gui" { insideGUI = false }
        currentElement = ""
    }
}
