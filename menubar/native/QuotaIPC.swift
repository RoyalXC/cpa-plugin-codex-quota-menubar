import Foundation
import Darwin
import CryptoKit

let nativeProtocolVersion = 2
let nativeHelperFallbackVersion = "0.6.0"

func nativeHelperVersion(bundle: Bundle = .main) -> String {
    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? nativeHelperFallbackVersion
}

func nativeIPCReply(managed: Bool, version: String) -> Data {
    Data("Q2\(managed ? "M" : "I"):\(version)\n".utf8)
}

func nativeDefaultSocketURL(home: URL, uid: uid_t = getuid()) -> URL {
    let hash = SHA256.hash(data: Data(home.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
    return URL(fileURLWithPath: "/tmp/cqm-\(uid)-\(hash)/events-v2.sock")
}

func nativeEventDescriptor(arguments: [String]) -> Int32 {
    guard let argument = arguments.first(where: { $0 == "--event-fd" || $0.hasPrefix("--event-fd=") || $0.hasPrefix("--event-fd") }) else { return -1 }
    let raw: String
    if argument == "--event-fd" {
        guard let index = arguments.firstIndex(of: argument), arguments.count > index + 1 else { return -1 }
        raw = arguments[index + 1]
    } else if argument.hasPrefix("--event-fd=") {
        raw = String(argument.dropFirst("--event-fd=".count))
    } else {
        raw = String(argument.dropFirst("--event-fd".count))
    }
    return Int32(raw) ?? -1
}

private func ensureSecureSocketDirectory(_ directory: URL) throws {
    var attributes = stat()
    if lstat(directory.path, &attributes) != 0 {
        guard errno == ENOENT, mkdir(directory.path, 0o700) == 0 else { throw NativeQuotaError.configuration }
        guard lstat(directory.path, &attributes) == 0 else { throw NativeQuotaError.configuration }
    }
    guard attributes.st_uid == getuid(), attributes.st_mode & S_IFMT == S_IFDIR else { throw NativeQuotaError.configuration }
    guard chmod(directory.path, 0o700) == 0 else { throw NativeQuotaError.configuration }
}

func quotaSocketAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NativeQuotaError.configuration }
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    return address
}

final class NativeEventListener {
    private final class Client {
        let descriptor: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var authenticated = false
        init(descriptor: Int32, source: DispatchSourceRead) { self.descriptor = descriptor; self.source = source }
    }

    private let queue = DispatchQueue(label: "codex.quota.ipc")
    private let socketURL: URL
    private let managed: Bool
    private let version: String
    private var source: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var bound = false
    var onEvent: ((Int) -> Void)?

    init(socketURL: URL, managed: Bool, version: String = nativeHelperFallbackVersion) { self.socketURL = socketURL; self.managed = managed; self.version = version }

    func start() throws {
        try ensureSecureSocketDirectory(socketURL.deletingLastPathComponent())
        var attributes = stat()
        if lstat(socketURL.path, &attributes) == 0 {
            guard attributes.st_uid == getuid(), attributes.st_mode & S_IFMT == S_IFSOCK else { throw NativeQuotaError.configuration }
            guard unlink(socketURL.path) == 0 else { throw NativeQuotaError.configuration }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NativeQuotaError.unavailable }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var address: sockaddr_un
        do { address = try quotaSocketAddress(path: socketURL.path) }
        catch { Darwin.close(descriptor); throw error }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw NativeQuotaError.unavailable }
        bound = true
        guard chmod(socketURL.path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            unlink(socketURL.path)
            bound = false
            throw NativeQuotaError.unavailable
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self] in self?.acceptClients(descriptor) }
        reader.setCancelHandler { Darwin.close(descriptor) }
        source = reader
        reader.resume()
    }

    func close(userRequestedQuit: Bool = false) {
        queue.sync {
            self.source?.cancel()
            self.source = nil
            for client in self.clients.values {
                if userRequestedQuit && client.authenticated {
                    _ = send(client.descriptor, Array("D".utf8), 1, 0)
                }
                client.source.cancel()
            }
            self.clients.removeAll()
            if self.bound { unlink(self.socketURL.path); self.bound = false }
        }
    }

    private func acceptClients(_ listener: Int32) {
        while true {
            let descriptor = accept(listener, nil, nil)
            if descriptor < 0 { if errno == EINTR { continue }; return }
            var owner: uid_t = 0
            var group: gid_t = 0
            guard clients.count < 16, getpeereid(descriptor, &owner, &group) == 0, owner == getuid() else {
                Darwin.close(descriptor)
                continue
            }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            var enabled: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            let client = Client(descriptor: descriptor, source: reader)
            clients[descriptor] = client
            reader.setEventHandler { [weak self, weak client] in if let client = client { self?.receive(client) } }
            reader.setCancelHandler { Darwin.close(descriptor) }
            reader.resume()
            queue.asyncAfter(deadline: .now() + 2) { [weak self, weak client] in
                guard let client = client, !client.authenticated else { return }
                self?.disconnect(client)
            }
        }
    }

    private func disconnect(_ client: Client) {
        guard clients[client.descriptor] === client else { return }
        clients.removeValue(forKey: client.descriptor)
        client.source.cancel()
    }

    private func receive(_ client: Client) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(client.descriptor, &bytes, bytes.count)
        guard count > 0 else {
            if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { disconnect(client) }
            return
        }
        var payload = Data(bytes.prefix(count))
        if !client.authenticated {
            client.buffer.append(payload)
            guard client.buffer.count >= 2 else { return }
            guard client.buffer.prefix(2) == Data("Q2".utf8) else { disconnect(client); return }
            let reply = nativeIPCReply(managed: managed, version: version)
            let sent = reply.withUnsafeBytes { bytes in send(client.descriptor, bytes.baseAddress, bytes.count, 0) }
            guard sent == reply.count else { disconnect(client); return }
            client.authenticated = true
            payload = client.buffer.dropFirst(2)
            client.buffer.removeAll()
        }
        guard payload.allSatisfy({ $0 == 85 }) else { disconnect(client); return }
        if !payload.isEmpty { onEvent?(payload.count) }
    }
}

func nativeIPCSelfTest(check: (Bool) -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = root.appendingPathComponent("events-v2.sock")
    let listener = NativeEventListener(socketURL: endpoint, managed: false, version: "0.5.0")
    let received = DispatchSemaphore(value: 0)
    listener.onEvent = { count in if count == 3 { received.signal() } }
    try listener.start()
    defer { listener.close() }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { Darwin.close(descriptor) }
    var address = try quotaSocketAddress(path: endpoint.path)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    check(connected == 0)
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    check(send(descriptor, Array("Q2".utf8), 2, 0) == 2)
    var reply = [UInt8](repeating: 0, count: 32)
    let replyCount = recv(descriptor, &reply, reply.count, 0)
    check(String(bytes: reply.prefix(max(0, replyCount)), encoding: .utf8) == "Q2I:0.5.0\n")
    check(send(descriptor, Array("UUU".utf8), 3, 0) == 3)
    check(received.wait(timeout: .now() + 1) == .success)
    listener.close(userRequestedQuit: true)
    var quit = [UInt8](repeating: 0, count: 1)
    check(recv(descriptor, &quit, 1, 0) == 1 && quit[0] == 68)
    check(!FileManager.default.fileExists(atPath: endpoint.path))
    try "fixture".write(to: endpoint, atomically: true, encoding: .utf8)
    let unsafe = NativeEventListener(socketURL: endpoint, managed: false)
    do { try unsafe.start(); check(false) } catch { check(true) }
    check(try String(contentsOf: endpoint, encoding: .utf8) == "fixture")
    check(String(data: nativeIPCReply(managed: true, version: "0.5.0"), encoding: .utf8) == "Q2M:0.5.0\n")
    check(nativeProtocolVersion == 2)
    for (name, version) in [("versioned", "1.2.3"), ("unversioned", nil)] as [(String, String?)] {
        let bundleURL = root.appendingPathComponent("\(name).bundle")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": "test.codex.quota.\(name)", "CFBundlePackageType": "BNDL"]
        info["CFBundleShortVersionString"] = version
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        guard let bundle = Bundle(url: bundleURL) else { check(false); continue }
        check(nativeHelperVersion(bundle: bundle) == (version ?? nativeHelperFallbackVersion))
    }
    check(nativeEventDescriptor(arguments: ["helper", "--event-fd", "198"]) == 198)
    check(nativeEventDescriptor(arguments: ["helper", "--event-fd=198"]) == 198)
    check(nativeEventDescriptor(arguments: ["helper", "--event-fd198"]) == 198)
    let path = nativeDefaultSocketURL(home: URL(fileURLWithPath: "/tmp/quota-data"), uid: 501).path
    check(path.hasPrefix("/tmp/cqm-501-") && path.hasSuffix("/events-v2.sock") && path.count < 104)
}
