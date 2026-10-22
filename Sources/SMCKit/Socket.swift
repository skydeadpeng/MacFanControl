import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// 守护进程与 GUI/CLI 之间的本地通信:unix socket + JSON 行协议
public enum FanProtocol {
    /// 发送 {"cmd":"status"} / {"cmd":"set","config":{...}} / {"cmd":"restore"}
    public static func makeRequest(cmd: String, config: [String: Any]? = nil) -> Data {
        var obj: [String: Any] = ["cmd": cmd]
        if let c = config { obj["config"] = c }
        var d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }

    public static func parse(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 构造 sockaddr_un(实测必须用 copyBytes 写入 sun_path,utf8CString+memcpy 会得到损坏的地址)
    public static func makeAddress(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            dest.copyBytes(from: bytes)
        }
        return addr
    }

    public static func addressLength(for path: String) -> socklen_t {
        socklen_t(2 + min(path.utf8.count + 1, 92))
    }
}

/// JSON 行协议服务端(守护进程用)
public final class JSONLineServer {
    public typealias Handler = ([String: Any]) -> [String: Any]

    private let path: String
    private let handler: Handler
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "macfan.server")   // 串行处理请求
    private var running = false

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SMCError.badData("socket() 失败") }

        var addr = FanProtocol.makeAddress(path: path)
        let len = FanProtocol.addressLength(for: path)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard r == 0 else { close(fd); fd = -1; throw SMCError.badData("bind(\(path)) 失败: errno=\(errno)") }
        guard listen(fd, 8) == 0 else { close(fd); fd = -1; throw SMCError.badData("listen 失败") }

        // root 时限制为 admin 组可读写
        chmod(path, mode_t(geteuid() == 0 ? 0o660 : 0o666))
        if geteuid() == 0 { chown(path, 0, 80) }

        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            guard client >= 0 else {
                if !running { return }
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            queue.async { [weak self] in
                self?.serve(client: client)
            }
        }
    }

    private func serve(client: Int32) {
        defer { close(client) }
        // 3 秒读超时,避免连接悬挂
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buffer.count < 1_048_576 {
            let n = read(client, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.contains(0x0A) { break }
        }
        guard let req = FanProtocol.parse(buffer), !req.isEmpty else { return }
        let resp = handler(req)
        guard let out = try? JSONSerialization.data(withJSONObject: resp) else { return }
        var data = out
        data.append(0x0A)
        _ = data.withUnsafeBytes { raw in write(client, raw.baseAddress, raw.count) }
    }

    public func stop() {
        running = false
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }
}

/// JSON 行协议客户端(GUI / fanctl status 用)
public enum FanClient {
    public static func request(_ payload: Data, timeout: Double = 1.2) -> [String: Any]? {
        for path in Paths.socketCandidates {
            if let resp = request(path: path, payload: payload, timeout: timeout) {
                return resp
            }
        }
        return nil
    }

    public static func status() -> [String: Any]? {
        request(FanProtocol.makeRequest(cmd: "status"))
    }

    public static func set(config: [String: Any]) -> [String: Any]? {
        request(FanProtocol.makeRequest(cmd: "set", config: config))
    }

    static func request(path: String, payload: Data, timeout: Double) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = FanProtocol.makeAddress(path: path)
        let len = FanProtocol.addressLength(for: path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard ok == 0 else { return nil }
        _ = payload.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buffer.count < 1_048_576 {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.contains(0x0A) { break }
        }
        return FanProtocol.parse(buffer)
    }
}
