import Foundation
import CryptoKit
import SQLite3
import CoreFoundation

enum NativeQuotaError: Error, Equatable { case configuration, response, expired, unavailable }

func boundedData(_ url: URL, limit: Int = 1048576) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber, size.intValue <= limit else { throw NativeQuotaError.configuration }
    let data = try Data(contentsOf: url)
    guard data.count <= limit else { throw NativeQuotaError.configuration }
    return data
}

func finiteNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
    return number.doubleValue
}

func scalarString(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("\"") {
        var escaped = false
        var closing: String.Index?
        for index in value.indices.dropFirst() {
            if escaped { escaped = false; continue }
            if value[index] == "\\" { escaped = true; continue }
            if value[index] == "\"" { closing = index; break }
        }
        guard let closing = closing else { throw NativeQuotaError.configuration }
        let tail = value[value.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else { throw NativeQuotaError.configuration }
        return try JSONDecoder().decode(String.self, from: Data(value[...closing].utf8))
    }
    if value.hasPrefix("'") {
        var result = ""
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            if value[index] == "'" {
                let next = value.index(after: index)
                if next < value.endIndex && value[next] == "'" { result += "'"; index = value.index(after: next); continue }
                let tail = value[next...].trimmingCharacters(in: .whitespaces)
                guard tail.isEmpty || tail.hasPrefix("#") else { throw NativeQuotaError.configuration }
                return result
            }
            result.append(value[index])
            index = value.index(after: index)
        }
        throw NativeQuotaError.configuration
    }
    let result = value.components(separatedBy: " #").first!.trimmingCharacters(in: .whitespaces)
    guard !result.isEmpty, !"[{&*!>|".contains(result.first!), !["null", "~", "true", "false"].contains(result) else { throw NativeQuotaError.configuration }
    return result
}

func nativeAuthDirectory(text: String, configURL: URL) throws -> URL {
    var inOAuth = false
    var childIndent: Int?
    var matches: [String] = []
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let indent = line.prefix(while: { $0 == " " }).count
        if indent == 0 {
            let head = trimmed.components(separatedBy: "#").first!.trimmingCharacters(in: .whitespaces)
            inOAuth = head == "oauth:"
            childIndent = nil
        } else if inOAuth && childIndent == nil { childIndent = indent }
        if (indent == 0 || (inOAuth && indent == childIndent)), let separator = trimmed.firstIndex(of: ":"),
           trimmed[..<separator].trimmingCharacters(in: .whitespaces) == "auth-dir" {
            matches.append(String(trimmed[trimmed.index(after: separator)...]))
        }
    }
    guard matches.count == 1 else { throw NativeQuotaError.configuration }
    let path = try scalarString(matches[0])
    guard !path.trimmingCharacters(in: .whitespaces).isEmpty, !path.contains("\n"), !path.contains("\r") else { throw NativeQuotaError.configuration }
    let expanded = (path as NSString).expandingTildeInPath
    return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : configURL.deletingLastPathComponent().appendingPathComponent(expanded)).standardizedFileURL
}

func nativeManagementKey(text: String) throws -> String {
    var matches: [String] = []
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") { break }
        guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "="),
              trimmed[..<separator].trimmingCharacters(in: .whitespaces) == "management-secret-key" else { continue }
        matches.append(String(trimmed[trimmed.index(after: separator)...]))
    }
    guard matches.count == 1 else { throw NativeQuotaError.configuration }
    let key = try scalarString(matches[0])
    guard !key.isEmpty, key.count <= 1024, !key.contains("\n"), !key.contains("\r") else { throw NativeQuotaError.configuration }
    return key
}

struct NativeCredential {
    let token: String
    let accountID: String
    let name: String
    let authIndex: String
    var cacheKey: String { accountID + ":" + authIndex + ":" + SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
}

func nativeCredential(url: URL) throws -> NativeCredential? {
    guard let payload = try JSONSerialization.jsonObject(with: boundedData(url)) as? [String: Any], payload["type"] as? String == "codex" else { return nil }
    if let disabled = payload["disabled"], !(disabled is NSNull) {
        if let number = disabled as? NSNumber { if number.boolValue { return nil } }
        else if let text = disabled as? String { if !text.isEmpty { return nil } }
        else { return nil }
    }
    guard let token = payload["access_token"] as? String, !token.isEmpty,
          let accountID = payload["account_id"] as? String, !accountID.isEmpty else { return nil }
    let email = payload["email"] as? String
    let index = SHA256.hash(data: Data(("codex:" + url.standardizedFileURL.path).utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
    return NativeCredential(token: token, accountID: accountID, name: email?.isEmpty == false ? email! : accountID, authIndex: String(index))
}

struct NativeUsageEvent {
    let timestamp: Double
    let identifier: Int64
    let authIndex: String
    let authType: String
    let provider: String
    let failed: Bool
    var cursor: String { "\(timestamp):\(identifier)" }
    var official: Bool { authType == "oauth" && provider == "codex" }
}

func nativeOpenUsageDatabase(database: URL) throws -> OpaquePointer {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        if let connection = connection { sqlite3_close(connection) }
        throw NativeQuotaError.configuration
    }
    sqlite3_busy_timeout(connection, 2000)
    guard let opened = connection else { throw NativeQuotaError.configuration }
    guard sqlite3_exec(opened, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
        sqlite3_close(opened)
        throw NativeQuotaError.configuration
    }
    return opened
}

func nativeLatestEvent(database: URL, officialOnly: Bool = false) throws -> NativeUsageEvent? {
    let connection = try nativeOpenUsageDatabase(database: database)
    defer { sqlite3_close(connection) }
    let filter = officialOnly ? " AND auth_type='oauth' AND provider='codex'" : ""
    let sql = "SELECT timestamp_ms,id,auth_index,auth_type,provider,failed FROM usage_events WHERE generate=1" + filter + " ORDER BY timestamp_ms DESC,id DESC LIMIT 1"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw NativeQuotaError.configuration }
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW else { throw NativeQuotaError.configuration }
    func column(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    return NativeUsageEvent(timestamp: sqlite3_column_double(statement, 0), identifier: sqlite3_column_int64(statement, 1),
        authIndex: column(2), authType: column(3), provider: column(4), failed: sqlite3_column_int(statement, 5) != 0)
}

struct NativeResolution {
    let resolution: String
    let source: String
    let observedAt: Double?
    let credential: NativeCredential?
    let cursor: String?
    var eventTargetsCredential: Bool = false
}

struct NativeAccountChoice {
    let name: String
    let authIndex: String
}

func nativeCredentials(cpaHome: URL, authDirectory: URL? = nil) throws -> [NativeCredential] {
    let configURL = cpaHome.appendingPathComponent("cpa-core/config.yaml")
    let directory: URL
    if let configured = authDirectory { directory = configured.standardizedFileURL }
    else if FileManager.default.fileExists(atPath: configURL.path) {
        guard let config = String(data: try boundedData(configURL), encoding: .utf8) else { throw NativeQuotaError.configuration }
        directory = try nativeAuthDirectory(text: config, configURL: configURL)
    } else { directory = cpaHome.appendingPathComponent("oauth") }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }.compactMap { try? nativeCredential(url: $0) }
        .sorted { $0.name < $1.name }
}

func resolveNativeQuota(cpaHome: URL, authDirectory: URL? = nil, selectedAuthIndex: String? = nil, credentials: [NativeCredential]? = nil) throws -> NativeResolution {
    let candidates = try credentials ?? nativeCredentials(cpaHome: cpaHome, authDirectory: authDirectory)
    let database = cpaHome.appendingPathComponent("usage-records/usage.db")
    let latest: NativeUsageEvent?
    if FileManager.default.fileExists(atPath: database.path) {
        latest = selectedAuthIndex == nil ? try nativeLatestEvent(database: database) : try? nativeLatestEvent(database: database)
    } else { latest = nil }
    if let selected = selectedAuthIndex {
        guard let credential = candidates.first(where: { $0.authIndex == selected }) else { throw NativeQuotaError.configuration }
        return NativeResolution(resolution: "selected-account", source: "手动选择的 Codex OAuth 账号（非当前模型用量）", observedAt: nil, credential: credential, cursor: latest?.cursor,
            eventTargetsCredential: latest?.official == true && latest?.authIndex == credential.authIndex)
    }
    let event = latest?.official == false ? try nativeLatestEvent(database: database, officialOnly: true) : latest
    if latest != nil && event == nil {
        return NativeResolution(resolution: "third-party", source: "最近请求为第三方通道，尚无 Codex OAuth 请求记录", observedAt: latest?.timestamp, credential: nil, cursor: latest?.cursor)
    }
    if let event = event {
        let matches = candidates.filter { $0.authIndex == event.authIndex }
        guard matches.count == 1 else { throw NativeQuotaError.configuration }
        let retained = latest?.official == false
        return NativeResolution(resolution: retained ? "last-official-request" : "recent-request",
            source: retained ? "CPA 最近 Codex OAuth 账号额度（最近请求为第三方通道）" : "CPA 最近 Codex OAuth 请求" + (event.failed ? "（失败，不代表一定消耗额度）" : ""),
            observedAt: event.timestamp, credential: matches[0], cursor: latest?.cursor, eventTargetsCredential: !retained)
    }
    return NativeResolution(resolution: candidates.count == 1 ? "single-account" : (candidates.isEmpty ? "unavailable" : "ambiguous"),
        source: candidates.count == 1 ? "CPA 唯一 Codex OAuth 账号（尚无生成请求记录）" : "无法确定 Codex OAuth 账号", observedAt: nil,
        credential: candidates.count == 1 ? candidates[0] : nil, cursor: nil)
}

func normalizeNativeUsage(data: Data) throws -> QuotaUsage {
    guard data.count <= 1048576, let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rate = payload["rate_limit"] as? [String: Any] else { throw NativeQuotaError.response }
    var windows: [QuotaWindow] = []
    for key in ["primary_window", "secondary_window"] {
        guard let window = rate[key] as? [String: Any] else { continue }
        let minutes = finiteNumber(window["window_minutes"] ?? window["window_duration_mins"] ?? window["windowDurationMins"])
        let duration = finiteNumber(window["limit_window_seconds"] ?? window["limitWindowSeconds"]) ?? minutes.map { $0 * 60 }
        let used = finiteNumber(window["used_percent"] ?? window["usedPercent"])
        windows.append(QuotaWindow(used_percent: used.flatMap { (0...100).contains($0) ? $0 : nil }, limit_window_seconds: duration,
            reset_at: finiteNumber(window["reset_at"] ?? window["resetAt"]), reset_after_seconds: finiteNumber(window["reset_after_seconds"] ?? window["resetAfterSeconds"])))
    }
    windows.sort { ($0.limit_window_seconds ?? .infinity) < ($1.limit_window_seconds ?? .infinity) }
    let status = (rate["limit_reached"] as? Bool == true) ? "limit_reached" : ((rate["allowed"] as? Bool == false) ? "not_allowed" : "ok")
    return QuotaUsage(status: status, plan_type: payload["plan_type"] as? String, windows: windows, message: nil)
}

func officialQuotaRequest(credential: NativeCredential) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
    request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("codex-quota-menubar/0.5.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 15
    return request
}

final class NativeQuotaNetwork: NSObject, URLSessionDataDelegate {
    private var bytes = Data()
    private var status = 0
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var completion: ((Result<QuotaUsage, NativeQuotaError>) -> Void)?

    func fetch(_ credential: NativeCredential, completion: @escaping (Result<QuotaUsage, NativeQuotaError>) -> Void) {
        self.completion = completion
        bytes = Data()
        status = 0
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session!.dataTask(with: officialQuotaRequest(credential: credential))
        task!.resume()
    }

    func cancel() { task?.cancel(); session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(status == 200 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= 1048576 else { dataTask.cancel(); return }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<QuotaUsage, NativeQuotaError>
        if status == 401 { result = .failure(.expired) }
        else if error != nil || status != 200 { result = .failure(.unavailable) }
        else if let usage = try? normalizeNativeUsage(data: bytes) { result = .success(usage) }
        else { result = .failure(.response) }
        completion?(result)
        completion = nil
        self.task = nil
        self.session = nil
        session.finishTasksAndInvalidate()
    }
}

enum NativeRefreshReason: Hashable { case startup, event, demand, manual, reset }

func nativeSelfTest(check: (Bool) -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("cpa-core/config.yaml")
    let auth = root.appendingPathComponent("auth")
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
    let yaml = "oauth:\n  providers:\n    auth-dir: ignored\n  auth-dir: ../auth\n"
    try yaml.write(to: config, atomically: true, encoding: .utf8)
    check(try nativeAuthDirectory(text: yaml, configURL: config).path == auth.path)
    for invalid in ["server:\n  auth-dir: ../auth", "auth-dir: ../auth\noauth:\n  auth-dir: ../auth"] {
        do { _ = try nativeAuthDirectory(text: invalid, configURL: config); check(false) }
        catch { check(true) }
    }
    check(try nativeManagementKey(text: "management-secret-key = \"fixture\"\n[other]\nkey=\"ignored\"") == "fixture")
    let credentialURL = auth.appendingPathComponent("fixture.json")
    func writeCredential(token: String = "fixture", disabled: Bool = false, type: String = "codex") throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": type, "access_token": token, "account_id": "fixture-account", "disabled": disabled])
        try data.write(to: credentialURL)
    }
    try writeCredential()
    let original = try nativeCredential(url: credentialURL)!
    check(original.authIndex == String(SHA256.hash(data: Data(("codex:" + credentialURL.path).utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)))
    try writeCredential(token: "rotated")
    check(try nativeCredential(url: credentialURL)!.cacheKey != original.cacheKey)
    for attributes in [("fixture", true, "codex"), ("", false, "codex"), ("fixture", false, "other")] {
        try writeCredential(token: attributes.0, disabled: attributes.1, type: attributes.2)
        check(try nativeCredential(url: credentialURL) == nil)
    }
    try writeCredential()
    let dbURL = root.appendingPathComponent("usage-records/usage.db")
    try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(dbURL.path, &database) == SQLITE_OK else { throw NativeQuotaError.configuration }
    defer { sqlite3_close(database) }
    func sql(_ statement: String) throws {
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw NativeQuotaError.configuration }
    }
    try sql("CREATE TABLE usage_events(timestamp_ms REAL,id INTEGER,auth_index TEXT,auth_type TEXT,provider TEXT,failed INTEGER,generate INTEGER)")
    check(try resolveNativeQuota(cpaHome: root).resolution == "single-account")
    try sql("INSERT INTO usage_events VALUES(1,1,'third','api-key','glm',0,1)")
    check(try resolveNativeQuota(cpaHome: root).credential == nil)
    try sql("INSERT INTO usage_events VALUES(2,2,'\(original.authIndex)','oauth','codex',0,1)")
    check(try resolveNativeQuota(cpaHome: root).credential?.accountID == "fixture-account")
    try sql("INSERT INTO usage_events VALUES(3,3,'third','api-key','glm',0,1)")
    let retained = try resolveNativeQuota(cpaHome: root)
    check(retained.resolution == "last-official-request" && retained.credential?.authIndex == original.authIndex)
    try writeCredential(disabled: true)
    do { _ = try resolveNativeQuota(cpaHome: root); check(false) } catch { check(true) }
    let normalized = try normalizeNativeUsage(data: Data("{\"rate_limit\":{\"limit_reached\":true,\"allowed\":false,\"primary_window\":{\"usedPercent\":12,\"windowDurationMins\":300},\"secondary_window\":{\"used_percent\":true,\"limit_window_seconds\":60}}}".utf8))
    check(normalized.status == "limit_reached")
    check(normalized.windows?.first?.percentage == nil && normalized.windows?.last?.limit_window_seconds == 18000)
    for value in ["-1", "101", "true", "\"47\""] {
        let usage = try normalizeNativeUsage(data: Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(value)}}}".utf8))
        check(usage.windows?.first?.percentage == nil)
    }
    check(finiteNumber(Double.infinity) == nil && finiteNumber(Double.nan) == nil)
    check(nativeMinimumAge(reason: .event, retained: false, failed: false, dirty: false) == 30)
    check(nativeMinimumAge(reason: .event, retained: true, failed: false, dirty: false) == 300)
    check(nativeMinimumAge(reason: .manual, retained: false, failed: true, dirty: false) == 20)
    check(nativeMinimumAge(reason: .manual, retained: false, failed: false, dirty: false) == 0)
    check(nativeMinimumAge(reason: .reset, retained: true, failed: false, dirty: false) == 30)
    check(nativeMinimumAge(reason: .demand, retained: false, failed: false, dirty: true) == 30)
    try writeCredential()
    try sql("PRAGMA journal_mode=WAL")
    try sql("PRAGMA wal_checkpoint(TRUNCATE)")
    sqlite3_close(database)
    database = nil
    try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
    try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
    check(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
    check(try resolveNativeQuota(cpaHome: root).resolution == "last-official-request")
    let protected = try nativeOpenUsageDatabase(database: dbURL)
    defer { sqlite3_close(protected) }
    check(sqlite3_exec(protected, "DELETE FROM usage_events", nil, nil, nil) == SQLITE_READONLY)
    check(try nativeLatestEvent(database: dbURL)?.identifier == 3)
    let standalone = root.appendingPathComponent("without-cpa")
    check(try resolveNativeQuota(cpaHome: standalone, authDirectory: auth).resolution == "single-account")
    let secondURL = auth.appendingPathComponent("second.json")
    try Data("{\"type\":\"codex\",\"access_token\":\"fixture-second\",\"account_id\":\"second-account\"}".utf8).write(to: secondURL)
    check(try resolveNativeQuota(cpaHome: standalone, authDirectory: auth).resolution == "ambiguous")
    let second = try nativeCredential(url: secondURL)!
    let selected = try resolveNativeQuota(cpaHome: standalone, authDirectory: auth, selectedAuthIndex: second.authIndex)
    check(selected.resolution == "selected-account" && selected.credential?.accountID == "second-account")
    check(!selected.eventTargetsCredential)
    let retainedSelected = try resolveNativeQuota(cpaHome: root, authDirectory: auth, selectedAuthIndex: second.authIndex)
    check(retainedSelected.cursor != nil && !retainedSelected.eventTargetsCredential)
    do { _ = try resolveNativeQuota(cpaHome: standalone, authDirectory: auth, selectedAuthIndex: "missing"); check(false) }
    catch { check(true) }
}

func nativeMinimumAge(reason: NativeRefreshReason, retained: Bool, failed: Bool, dirty: Bool) -> Double {
    if failed { return 20 }
    if reason == .manual { return 0 }
    if reason == .reset { return 30 }
    if reason == .event { return retained ? 300 : 30 }
    return dirty && !retained ? 30 : 300
}

final class NativeQuotaEngine {
    let cpaHome: URL
    let queue = DispatchQueue(label: "codex.quota.engine")
    var onSnapshot: ((QuotaSnapshot, Int) -> Void)?
    var onLoading: ((Bool) -> Void)?
    var onDisabled: (() -> Void)?
    var onAccounts: (([NativeAccountChoice], String?) -> Void)?
    private let authDirectory: URL?
    private let settingsURL: URL?
    private let managementPort: Int
    private var selectedAuthIndex: String?
    private var cache: [String: Entry] = [:]
    private var order: [String] = []
    private var network: NativeQuotaNetwork?
    private var pending = Set<NativeRefreshReason>()
    private var firstEvent: Double?
    private var dirtySince: Double?
    private var cursor: String?
    private var eventWork: DispatchWorkItem?
    private var trailingWork: DispatchWorkItem?
    private var resetWork: DispatchWorkItem?
    private var idleTimer: DispatchSourceTimer?
    private var lifecycleTimer: DispatchSourceTimer?
    private var managementSession: URLSession?
    private var managementBusy = false
    private var stopped = false
    private var requestCount = 0
    private let managed: Bool

    struct Entry {
        let usage: QuotaUsage
        let attemptedAt: Double
        let refreshedAt: Double?
        let failed: Bool
    }

    init(cpaHome: URL, managed: Bool, authDirectory: URL? = nil, selectedAuthIndex: String? = nil, settingsURL: URL? = nil, managementPort: Int = 8317) {
        self.cpaHome = cpaHome
        self.managed = managed
        self.authDirectory = authDirectory
        self.selectedAuthIndex = selectedAuthIndex
        self.settingsURL = settingsURL
        self.managementPort = (1...65535).contains(managementPort) ? managementPort : 8317
    }

    func selectAccount(_ authIndex: String?) {
        queue.async {
            do {
                let candidates = try nativeCredentials(cpaHome: self.cpaHome, authDirectory: self.authDirectory)
                guard authIndex == nil || candidates.contains(where: { $0.authIndex == authIndex }) else { return }
                if let url = self.settingsURL {
                    var settings = (try? boundedData(url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    settings["selectedAuthIndex"] = authIndex
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try JSONSerialization.data(withJSONObject: settings).write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                self.selectedAuthIndex = authIndex
                self.request(.demand)
            } catch { return }
        }
    }

    func start() {
        queue.async { [self] in
            self.refresh(.startup)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 900, repeating: 900)
            timer.setEventHandler { [weak self] in self?.checkCursor() }
            timer.resume()
            self.idleTimer = timer
            if self.managed {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.connectionProxyDictionary = [:]
                self.managementSession = URLSession(configuration: configuration, delegate: QuotaSessionDelegate(), delegateQueue: nil)
                let lifecycle = DispatchSource.makeTimerSource(queue: self.queue)
                lifecycle.schedule(deadline: .now() + 2, repeating: 2)
                lifecycle.setEventHandler { [weak self] in self?.checkLifecycle() }
                lifecycle.resume()
                self.lifecycleTimer = lifecycle
            }
        }
    }

    func close() {
        queue.async {
            self.stopped = true
            self.network?.cancel()
            self.managementSession?.invalidateAndCancel()
            self.idleTimer?.cancel()
            self.lifecycleTimer?.cancel()
            self.eventWork?.cancel()
            self.trailingWork?.cancel()
            self.resetWork?.cancel()
        }
    }

    func request(_ reason: NativeRefreshReason) { queue.async { self.refresh(reason) } }

    func event() {
        queue.async { [self] in
            guard !self.stopped else { return }
            let now = Date().timeIntervalSince1970
            if self.firstEvent == nil { self.firstEvent = now }
            if self.dirtySince == nil { self.dirtySince = now }
            self.eventWork?.cancel()
            let delay = max(0, min(now + 2, self.firstEvent! + 5) - now)
            let work = DispatchWorkItem { [weak self] in self?.firstEvent = nil; self?.refresh(.event) }
            self.eventWork = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func checkCursor() {
        guard let latest = try? nativeLatestEvent(database: cpaHome.appendingPathComponent("usage-records/usage.db")), latest.cursor != cursor else { return }
        event()
    }

    private func checkLifecycle() {
        guard !stopped, !managementBusy else { return }
        do {
            let data = try boundedData(cpaHome.appendingPathComponent("config.toml"))
            guard let text = String(data: data, encoding: .utf8) else { return }
            let key = try nativeManagementKey(text: text)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(managementPort)/v0/management/plugins")!)
            request.timeoutInterval = 1
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            managementBusy = true
            managementSession?.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                self.queue.async {
                    self.managementBusy = false
                    guard !self.stopped, error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                          let data = data, data.count <= 1048576,
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    let entries = payload["plugins"] as? [[String: Any]] ?? []
                    let plugin = entries.first { $0["id"] as? String == "codex-quota-menubar" }
                    if payload["plugins_enabled"] as? Bool == false || plugin?["enabled"] as? Bool == false || plugin == nil {
                        DispatchQueue.main.async { self.onDisabled?() }
                    }
                }
            }.resume()
        } catch { return }
    }

    private func refresh(_ reason: NativeRefreshReason) {
        guard !stopped else { return }
        if network != nil { pending.insert(reason); return }
        let selection: NativeResolution
        do {
            let credentials = try nativeCredentials(cpaHome: cpaHome, authDirectory: authDirectory)
            let selected = selectedAuthIndex
            let choices = credentials.map { NativeAccountChoice(name: $0.name, authIndex: $0.authIndex) }
            DispatchQueue.main.async { self.onAccounts?(choices, selected) }
            selection = try resolveNativeQuota(cpaHome: cpaHome, selectedAuthIndex: selected, credentials: credentials)
        }
        catch {
            publish(QuotaSnapshot(resolution: "unavailable", sourceLabel: "CPA 配置或账号不可用", observedAt: nil,
                error: "CPA 配置或账号不可用。", accounts: []))
            return
        }
        if selection.cursor != cursor {
            cursor = selection.cursor
            if dirtySince == nil { dirtySince = Date().timeIntervalSince1970 }
        }
        guard let credential = selection.credential else {
            publish(QuotaSnapshot(resolution: selection.resolution, sourceLabel: selection.source, observedAt: selection.observedAt, error: nil, accounts: []))
            return
        }
        let now = Date().timeIntervalSince1970
        let key = credential.cacheKey
        let entry = cache[key]
        let dirty = dirtySince.map { now - $0 >= 30 } ?? false
        let minimum = nativeMinimumAge(reason: reason, retained: !selection.eventTargetsCredential, failed: entry?.failed == true, dirty: dirty)
        if let entry = entry, now - entry.attemptedAt < minimum {
            publish(snapshot(selection: selection, entry: entry))
            if (reason == .event && (selection.eventTargetsCredential || entry.failed)) || reason == .reset {
                trailingWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refresh(reason) }
                trailingWork = work
                queue.asyncAfter(deadline: .now() + max(0.05, minimum - (now - entry.attemptedAt)), execute: work)
            }
            return
        }
        requestCount += 1
        DispatchQueue.main.async { self.onLoading?(true) }
        let fetcher = NativeQuotaNetwork()
        network = fetcher
        fetcher.fetch(credential) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                let completed = Date().timeIntervalSince1970
                let updated: Entry
                switch result {
                case .success(let usage):
                    updated = Entry(usage: usage, attemptedAt: completed, refreshedAt: completed * 1000, failed: false)
                    if self.pending.isEmpty { self.dirtySince = nil }
                case .failure(let error):
                    let message = error == .expired ? "账号认证已过期，请在 CPA 重新登录。" : "额度接口暂时不可用。"
                    updated = Entry(usage: QuotaUsage(status: entry?.refreshedAt == nil ? "error" : "stale",
                        plan_type: entry?.usage.plan_type, windows: entry?.usage.windows ?? [], message: message),
                        attemptedAt: completed, refreshedAt: entry?.refreshedAt, failed: true)
                }
                self.cache[key] = updated
                self.order.removeAll { $0 == key }
                self.order.append(key)
                while self.order.count > 8 { self.cache.removeValue(forKey: self.order.removeFirst()) }
                self.network = nil
                self.publish(self.snapshot(selection: selection, entry: updated))
                DispatchQueue.main.async { self.onLoading?(false) }
                let waiting = self.pending
                self.pending.removeAll()
                if !waiting.isEmpty {
                    let next: NativeRefreshReason = waiting.contains(.manual) ? .manual : (waiting.contains(.reset) ? .reset : .event)
                    self.refresh(next)
                }
            }
        }
    }

    private func snapshot(selection: NativeResolution, entry: Entry) -> QuotaSnapshot {
        QuotaSnapshot(resolution: selection.resolution, sourceLabel: selection.source, observedAt: selection.observedAt, error: nil,
            accounts: [QuotaAccount(name: selection.credential!.name, current: true, usage: entry.usage, refreshedAt: entry.refreshedAt)])
    }

    private func publish(_ snapshot: QuotaSnapshot) {
        resetWork?.cancel()
        let now = Date().timeIntervalSince1970
        let deadlines = (snapshot.account?.usage?.windows ?? []).compactMap { window -> Double? in
            let epoch = window.reset_at ?? window.reset_after_seconds.flatMap { interval in snapshot.account?.refreshedAt.map { $0 / 1000 + interval } }
            guard let epoch = epoch, epoch.isFinite, epoch + 5 > now, epoch < 4102444800 else { return nil }
            return epoch + 5
        }
        if let reset = deadlines.min() {
            let work = DispatchWorkItem { [weak self] in self?.refresh(.reset) }
            resetWork = work
            queue.asyncAfter(deadline: .now() + (reset - now), execute: work)
        }
        let count = requestCount
        DispatchQueue.main.async { self.onSnapshot?(snapshot, count) }
    }
}
