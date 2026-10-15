import Foundation
import Darwin

struct ResearchSource: Identifiable {
    let id: Int
    let title: String
    let url: URL
    let text: String
    let fullPage: Bool
    var evidence: String { "[S\(id)] \(title)\nURL: \(url.absoluteString)\n" + (fullPage ? "Extracto de página:" : "Solo extracto del buscador (página no recuperada):") + "\n" + text }
}

private final class ResearchRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ResearchWeb {
    private static let blocker = ResearchRedirectBlocker()
    private static let session: URLSession = { let c = URLSessionConfiguration.ephemeral; c.urlCache = nil; c.httpShouldSetCookies = false; c.timeoutIntervalForRequest = 18; return URLSession(configuration: c, delegate: blocker, delegateQueue: nil) }()
    /// Public HTTPS only, no credentials, local names, literal IPs, or non-public DNS answers.
    static func publicURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased(), host.count < 254,
              host.range(of: #"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}$"#, options: .regularExpression) != nil,
              ![".localhost",".local",".internal",".test",".invalid",".home",".lan"].contains(where: host.hasSuffix) else { return false }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var pointer: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &pointer) == 0, let first = pointer else { return false }; defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            let info = current.pointee
            if info.ai_family == AF_INET {
                let raw = info.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let a = raw >> 24, b = (raw >> 16)&255
                if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31) || (a == 192 && (b == 168 || b == 0)) || (a == 100 && b >= 64 && b <= 127) || (a == 198 && (b == 18 || b == 19)) { return false }
            } else if info.ai_family == AF_INET6 {
                let bytes = info.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                // Globally routable unicast2000::/3 only; rejects mapped/local/multicast.
                if bytes[0]&0xe0 != 0x20 { return false }
            } else { return false }
            cursor = info.ai_next
        }
        return true
    }
    static func plain(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<(script|style|noscript|svg|template)\b[^>]*>.*?</\1>"#, #"(?is)<!--.*?-->"#, #"(?is)<[^>]+>"#] { text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        for (a,b) in [("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'"),("&nbsp;"," ")] { text = text.replacingOccurrences(of: a, with: b) }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        guard publicURL(url) else { throw URLError(.unsupportedURL) }
        var call = URLRequest(url: url); call.setValue("ScanMac/0.8 Research (public-page reader)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: call)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes { data.append(byte); if data.count >= 512_000 { break } }
        try Task.checkCancellation(); return (data,http)
    }
    static func search(_ query: String) async throws -> [ResearchSource] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 400 else { throw NSError(domain: "ScanMac.Research",code:1,userInfo:[NSLocalizedDescriptionKey:"Escribe una consulta pública de hasta400 caracteres."]) }
        // Prefer the public encyclopedia API: no API key, scripts or tracking redirects.
        let encyclopedia = try? await wikipedia(q)
        if let encyclopedia, !encyclopedia.isEmpty { return encyclopedia }
        var url = URLComponents(string: "https://www.bing.com/search")!; url.queryItems = [URLQueryItem(name: "q", value: q),URLQueryItem(name: "format", value: "rss")]
        let (data,_) = try await get(url.url!)
        let delegate = SearchRSSParser(); let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw URLError(.cannotParseResponse) }
        var results: [ResearchSource] = []; var seen = Set<String>()
        for item in delegate.items {
            guard results.count < 5, relevant(query: q,title: item.title + " " + item.description), let target = URL(string: item.link), publicURL(target), seen.insert(target.absoluteString).inserted else { continue }
            var body = plain(item.description), full = false
            if let (page,response) = try? await get(target), let type = response.value(forHTTPHeaderField: "Content-Type"), type.contains("text/html"), let html = String(data: page, encoding: .utf8) {
                let parsed = plain(html)
                if parsed.count > 200 { body = String(parsed.prefix(9000)); full = true }
            }
            results.append(ResearchSource(id: results.count+1,title: plain(item.title),url: target,text: body,fullPage: full))
        }
        return results
    }
    private static func relevant(query: String,title: String) -> Bool {
        let stop: Set<String> = ["official","documentation","what","where","when","about","para","como","sobre","documentación","oficial"]
        let words = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 && !stop.contains($0) }
        return words.contains { title.localizedCaseInsensitiveContains($0) }
    }
    private static func wikipedia(_ query: String) async throws -> [ResearchSource] {
        var url = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        url.queryItems = [URLQueryItem(name:"action",value:"query"),URLQueryItem(name:"list",value:"search"),URLQueryItem(name:"srsearch",value:query),URLQueryItem(name:"format",value:"json"),URLQueryItem(name:"srlimit",value:"5")]
        let (data,_) = try await get(url.url!)
        let object = try JSONSerialization.jsonObject(with:data) as? [String:Any]
        let results = (object?["query"] as? [String:Any])?["search"] as? [[String:Any]] ?? []
        var sources: [ResearchSource] = []
        for result in results {
            guard let title = result["title"] as? String, let pageID = result["pageid"] as? Int else { continue }
            var extractURL = URLComponents(string:"https://en.wikipedia.org/w/api.php")!
            extractURL.queryItems = [URLQueryItem(name:"action",value:"query"),URLQueryItem(name:"prop",value:"extracts"),URLQueryItem(name:"explaintext",value:"1"),URLQueryItem(name:"exchars",value:"8000"),URLQueryItem(name:"pageids",value:String(pageID)),URLQueryItem(name:"format",value:"json")]
            var text = plain(result["snippet"] as? String ?? ""), full = false
            if let (body,_) = try? await get(extractURL.url!), let json = try? JSONSerialization.jsonObject(with:body) as? [String:Any], let query = json["query"] as? [String:Any], let pages = query["pages"] as? [String:Any], let page = pages[String(pageID)] as? [String:Any], let extract = page["extract"] as? String, !extract.isEmpty { text = extract; full = true }
            guard !text.isEmpty else { continue }
            sources.append(ResearchSource(id:sources.count+1,title:title,url:URL(string:"https://en.wikipedia.org/?curid=\(pageID)")!,text:text,fullPage:full))
        }
        return sources
    }
    static func readPublicPage(_ raw: String,id: Int) async throws -> ResearchSource {
        guard let url = URL(string:raw.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw URLError(.badURL) }
        let (data,response) = try await get(url)
        let mime = response.mimeType ?? ""
        guard mime == "text/html" || mime == "text/plain", let text = String(data:data,encoding:.utf8) else { throw URLError(.cannotDecodeContentData) }
        let body = mime == "text/html" ? plain(text) : text
        guard !body.isEmpty else { throw URLError(.zeroByteResource) }
        return ResearchSource(id:id,title:url.host ?? "Página pública",url:url,text:String(body.prefix(12000)),fullPage:true)
    }

}

private final class SearchRSSParser: NSObject, XMLParserDelegate {
    struct Item { var title = ""; var link = ""; var description = "" }
    var items: [Item] = []; private var current: Item?; private var element = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) { element = name; if name == "item" { current = Item() } }
    func parser(_ parser: XMLParser, foundCharacters string: String) { guard current != nil else { return }; switch element { case "title": current?.title += string; case "link": current?.link += string; case "description": current?.description += string; default: break } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name == "item", let current { items.append(current); self.current = nil }; element = "" }
}
