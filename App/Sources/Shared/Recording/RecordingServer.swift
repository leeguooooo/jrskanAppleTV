import Foundation
import Network

/// Serves recordings to AVPlayer over 127.0.0.1.
///
/// AVPlayer refuses an HLS playlist behind a `file://` URL (the item never
/// leaves `.unknown`), and recordings are HLS: MPEG-TS segments that
/// AVFoundation cannot read as a single file either. Over loopback HTTP the
/// same files play like any other VOD stream. The listener only binds the
/// loopback interface, and every path starts with a random token so other
/// apps on the device cannot browse the folder.
///
/// `GET /<token>/<recording id>/index.m3u8` renders the playlist from the
/// segment log on each request, so a recording still in progress plays as
/// an EVENT playlist that keeps growing.
final class RecordingServer: @unchecked Sendable {
    static let shared = RecordingServer(store: .standard)

    private let store: RecordingStore
    private let token = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "recording-server")
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    /// Recordings still being written; their playlists have no ENDLIST yet.
    private var liveIDs: Set<String> = []

    init(store: RecordingStore) {
        self.store = store
    }

    func setLive(_ id: String, _ live: Bool) {
        queue.async {
            if live { self.liveIDs.insert(id) } else { self.liveIDs.remove(id) }
        }
    }

    /// The playlist URL for a recording, starting the listener on first use
    /// (or again, if the system tore it down while the app was suspended).
    func playlistURL(for id: String) async throws -> URL {
        let port = try await ensureListening()
        return URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/\(id)/index.m3u8")!
    }

    private func ensureListening() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let listener = self.listener, listener.state == .ready, let port = self.port {
                    return continuation.resume(returning: port)
                }
                self.listener?.cancel()
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters)
                    var resumed = false
                    // The server lives for the whole process, so the listener's
                    // handlers can hold it strongly.
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            self.port = listener.port
                            if !resumed, let port = listener.port {
                                resumed = true
                                continuation.resume(returning: port)
                            }
                        case .failed(let error):
                            listener.cancel()
                            if self.listener === listener { self.listener = nil }
                            if !resumed {
                                resumed = true
                                continuation.resume(throwing: error)
                            }
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { connection in self.accept(connection) }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if error != nil || complete || buffer.count > 64 * 1_024 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return send(status: 400, on: connection) }
        let method = String(requestLine[0])
        let path = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? ""
        let parts = path.split(separator: "/").map(String.init)
        guard method == "GET" || method == "HEAD", parts.count == 3, parts[0] == token,
              Self.isSafeComponent(parts[1]), Self.isSafeComponent(parts[2]) else {
            return send(status: 404, on: connection)
        }

        let folder = store.folder(parts[1])
        let body: Data
        if parts[2] == "index.m3u8" {
            body = Data(folder.playlist(ended: !liveIDs.contains(parts[1])).utf8)
        } else if let data = try? Data(contentsOf: folder.url.appendingPathComponent(parts[2]), options: .mappedIfSafe) {
            body = data
        } else {
            return send(status: 404, on: connection)
        }

        let range = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("range:") }
            .flatMap { Self.byteRange($0, length: body.count) }
        var headers = [
            "Content-Type": Self.contentType(for: parts[2]),
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache"
        ]
        var status = 200
        var payload = body
        if let range {
            status = 206
            payload = body.subdata(in: range)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)"
        }
        send(status: status, headers: headers, body: method == "HEAD" ? nil : payload,
             contentLength: payload.count, on: connection)
    }

    private func send(status: Int, headers: [String: String] = [:], body: Data? = nil,
                      contentLength: Int = 0, on connection: NWConnection) {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(contentLength)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        var data = Data((head + "\r\n").utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Helpers

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix(".") && !value.contains("/") && !value.contains("\\")
    }

    static func contentType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "aac": return "audio/aac"
        case "m4a": return "audio/mp4"
        default: return "video/mp4"
        }
    }

    /// `Range: bytes=a-b`, `bytes=a-` or `bytes=-n`, clamped to the body.
    static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard let spec = header.split(separator: "=", maxSplits: 1).last, length > 0 else { return nil }
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        guard bounds.count == 2 else { return nil }
        switch (bounds[0], bounds[1]) {
        case let (start?, end?) where start <= end && start < length:
            return start..<min(end + 1, length)
        case let (start?, nil) where start < length:
            return start..<length
        case let (nil, suffix?) where suffix > 0:
            return max(0, length - suffix)..<length
        default:
            return nil
        }
    }
}
