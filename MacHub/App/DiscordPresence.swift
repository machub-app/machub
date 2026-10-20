import Foundation

/// "Playing <game> · via MacHub" in the user's Discord status, through Discord's local Rich Presence socket
/// ($TMPDIR/discord-ipc-N). Nothing leaves the Mac except what Discord itself shows to the user's friends, and only
/// while the setting is on. Without Discord running, every call is a silent no-op.
actor DiscordPresence {
    static let shared = DiscordPresence()
    static let enabledKey = "discord.presence"

    /// The "MacHub" application registered on discord.com/developers. Empty: presence is off until it's set.
    static let clientID = ""

    static var isEnabled: Bool {
        !clientID.isEmpty && (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
    }

    private var socket: Int32 = -1

    /// Shows the game being played, with elapsed time and its Steam artwork.
    func playing(_ name: String, appID: Int?, since start: Date) {
        guard Self.isEnabled, connect() else { return }
        var activity: [String: Any] = [
            "details": name,
            "state": "via MacHub",
            "timestamps": ["start": Int(start.timeIntervalSince1970)],
            "assets": [
                "large_image": appID.map { "https://cdn.cloudflare.steamstatic.com/steam/apps/\($0)/header.jpg" } ?? Self.icon,
                "large_text": name,
                "small_image": Self.icon,
                "small_text": "MacHub",
            ],
        ]
        if let appID { activity["buttons"] = [["label": "View on Steam", "url": "https://store.steampowered.com/app/\(appID)"]] }
        send(activity: activity)
    }

    /// Clears the status when the game closes.
    func stopped() {
        guard socket >= 0 else { return }
        send(activity: nil)
    }

    static let icon = "https://raw.githubusercontent.com/machub-app/machub/main/docs/brand/icon.png"

    // MARK: Discord IPC: frames of (opcode UInt32 LE, length UInt32 LE, JSON)

    enum Opcode: UInt32 { case handshake = 0, frame = 1, close = 2 }

    static func frame(_ opcode: Opcode, _ payload: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var data = Data()
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        return data
    }

    static func parseFrame(_ data: Data) -> (opcode: UInt32, payload: [String: Any])? {
        guard data.count >= 8 else { return nil }
        let opcode = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let length = Int(data.dropFirst(4).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard data.count >= 8 + length,
              let payload = try? JSONSerialization.jsonObject(with: data.dropFirst(8).prefix(length)) as? [String: Any] else { return nil }
        return (opcode, payload)
    }

    private func send(activity: [String: Any]?) {
        var args: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier)]
        if let activity { args["activity"] = activity }
        let payload: [String: Any] = ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]
        guard write(Self.frame(.frame, payload)), read() != nil else { disconnect(); return }
    }

    private func connect() -> Bool {
        if socket >= 0 { return true }
        let folder = NSTemporaryDirectory()
        for index in 0..<10 {
            let path = (folder as NSString).appendingPathComponent("discord-ipc-\(index)")
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var nosigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { close(fd); continue }
            socket = fd
            guard write(Self.frame(.handshake, ["v": 1, "client_id": Self.clientID])),
                  let ready = read(), ready.payload["evt"] as? String == "READY" else {
                disconnect()
                return false
            }
            return true
        }
        return false
    }

    private func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, data.count) } == data.count
    }

    private func read() -> (opcode: UInt32, payload: [String: Any])? {
        var header = [UInt8](repeating: 0, count: 8)
        guard recv(socket, &header, 8, MSG_WAITALL) == 8 else { return nil }
        let length = Int(UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24)
        var body = [UInt8](repeating: 0, count: length)
        guard length == 0 || recv(socket, &body, length, MSG_WAITALL) == length else { return nil }
        return Self.parseFrame(Data(header + body))
    }

    private func disconnect() {
        if socket >= 0 { close(socket) }
        socket = -1
    }
}
