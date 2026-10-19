import Foundation
import Network

/// A tiny web page on your Wi-Fi where any phone or computer can paste an AI answer into Hoot.
/// The URL carries a random secret, so only devices you showed the QR code to can send.
final class DropServer: @unchecked Sendable {
    static let port: UInt16 = 8179
    var onText: ((String, String) -> Void)?    // text, device label

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hoot.drop")

    let token: String = {
        if let saved = UserDefaults.standard.string(forKey: "dropToken") { return saved }
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let token = String((0..<10).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(token, forKey: "dropToken")
        return token
    }()

    var isRunning: Bool { listener != nil }

    var url: String? {
        guard let ip = Self.lanAddress() else { return nil }
        return "http://\(ip):\(Self.port)/\(token)"
    }

    func start() throws {
        guard listener == nil else { return }
        let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP (just enough for one page and one POST)

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.respond(conn, to: request)
            } else if done || error != nil || buffer.count > 1_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }

    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ conn: NWConnection, to req: Request) {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        guard path == "/\(token)" else { return send(conn, status: "404 Not Found", type: "text/plain", body: "Not found") }
        if req.method == "POST" {
            let text = String(data: req.body, encoding: .utf8) ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onText?(text, Self.deviceName(req.headers["user-agent"] ?? ""))
            }
            send(conn, status: "200 OK", type: "text/plain", body: "ok")
        } else {
            send(conn, status: "200 OK", type: "text/html; charset=utf-8", body: Self.page)
        }
    }

    private func send(_ conn: NWConnection, status: String, type: String, body: String) {
        let bytes = Data(body.utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func deviceName(_ ua: String) -> String {
        if ua.contains("iPhone") { return "iPhone" }
        if ua.contains("iPad") { return "iPad" }
        if ua.contains("Android") { return "Android" }
        if ua.contains("Windows") { return "Windows PC" }
        if ua.contains("Mac") { return "Other Mac" }
        return "Other device"
    }

    /// The Mac's Wi-Fi / Ethernet IPv4 address.
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidates.append((String(cString: ifa.ifa_name), String(cString: host)))
        }
        return (candidates.first { $0.0 == "en0" } ?? candidates.first { $0.0.hasPrefix("en") })?.1
    }

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Send to Hoot</title><style>
    :root{color-scheme:light dark;--bg:#f6f4ff;--card:#fff;--ink:#1d1b26;--muted:#6d6a7c;--accent:#7b6cff}
    @media (prefers-color-scheme:dark){:root{--bg:#15141b;--card:#211f2a;--ink:#f1effa;--muted:#a19db3}}
    body{margin:0;font:16px/1.4 -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--ink);padding:16px}
    .card{max-width:560px;margin:0 auto;background:var(--card);border-radius:20px;padding:18px;box-shadow:0 6px 30px #0001}
    h1{font-size:20px;margin:0 0 4px}p{margin:0 0 12px;color:var(--muted);font-size:14px}
    textarea{width:100%;box-sizing:border-box;min-height:220px;border-radius:14px;border:1px solid #8884;padding:12px;font:inherit;background:transparent;color:inherit}
    .row{display:flex;gap:8px;margin-top:10px}button{flex:1;border:0;border-radius:14px;padding:13px;font:600 16px system-ui;cursor:pointer}
    #send{background:linear-gradient(135deg,#8f78ff,#fa85bf);color:#fff}#paste{background:#8882;color:inherit}
    #msg{text-align:center;margin-top:10px;min-height:20px;font-weight:600}
    </style></head><body><div class="card"><h1>🦉 Send to Hoot</h1>
    <p>Paste an answer from Claude, ChatGPT or Gemini — it shows up in Hoot's AI Assist panel on your Mac.</p>
    <textarea id="t" placeholder="Paste here…"></textarea>
    <div class="row"><button id="paste">Paste</button><button id="send">Send</button></div><div id="msg"></div></div>
    <script>
    const t=document.getElementById('t'),m=document.getElementById('msg');
    document.getElementById('paste').onclick=async()=>{try{t.value=await navigator.clipboard.readText()}catch(e){m.textContent='Long-press the box and choose Paste'}};
    document.getElementById('send').onclick=async()=>{if(!t.value.trim())return;m.textContent='Sending…';
    try{const r=await fetch(location.pathname,{method:'POST',headers:{'Content-Type':'text/plain'},body:t.value});
    m.textContent=r.ok?'Sent to Hoot ✓':'Something went wrong';if(r.ok)t.value=''}catch(e){m.textContent='Can\\'t reach your Mac — same Wi-Fi?'}};
    </script></body></html>
    """
}
