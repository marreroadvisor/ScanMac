import SwiftUI
import AppKit
import PDFKit
import Security
import Darwin

private enum ScanCloudError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

private final class ScanCloudNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private enum ScanCloudKeychain {
    static func query(endpoint: URL, username: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ScanMac.CloudAccount." + endpoint.absoluteString, kSecAttrAccount as String: username]
    }
    static func save(_ token: String, endpoint: URL, username: String) throws {
        let base = query(endpoint: endpoint, username: username)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ScanCloudError.message(tr("No se pudo guardar la sesión en el Llavero ({0}).", String(describing: status))) }
    }
    static func read(endpoint: URL, username: String) throws -> String {
        var query = query(endpoint: endpoint, username: username)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw ScanCloudError.message(tr("No hay una sesión guardada para este servidor y usuario. Inicia sesión.")) }
        return token
    }
    static func remove(endpoint: URL, username: String) throws {
        let status = SecItemDelete(query(endpoint: endpoint, username: username) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ScanCloudError.message(tr("No se pudo eliminar la sesión del Llavero ({0}).", String(describing: status))) }
    }
}

private struct ScanCloudHealth: Decodable { let status: String; let service: String; let api_version: Int }
private struct ScanCloudAuth: Decodable { let token: String; let username: String }
private struct ScanCloudEntry: Decodable { let record: Record; let version: Int }
private struct ScanCloudListing: Decodable { let documents: [ScanCloudEntry] }
private struct ScanCloudDocument: Decodable { let record: Record; let pdf_base64: String; let version: Int }
private struct ScanCloudUpload: Encodable { let record: Record; let pdf_base64: String; let expected_version: Int }
private struct ScanCloudShare: Decodable { let url_path: String }

@MainActor private final class ScanCloudAccountModel: ObservableObject {
    @Published var endpoint = "http://127.0.0.1:8765"
    @Published var username = ""
    @Published var password = ""
    @Published var running = false
    @Published var problem: String?
    @Published var status = tr("Servidor propio de ScanMac · Sin conexión automática")
    @Published var shareURL: URL?
    @Published var shareHours = 720
    @Published private(set) var account = ""
    private var bearer = ""
    private var authenticatedEndpoint: URL?
    private var syncedIDs = Set<UUID>()
    private let noRedirect = ScanCloudNoRedirect()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: noRedirect, delegateQueue: nil)
    }()

    static func validatedEndpoint(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw ScanCloudError.message(tr("Escribe el origen del servidor, sin ruta, usuario ni parámetros.")) }
        let scheme = components.scheme?.lowercased()
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard loopback else { throw ScanCloudError.message(tr("Esta versión está configurada solo para este Mac. Usa localhost, 127.0.0.1 o ::1.")) }
        guard scheme == "https" || (scheme == "http" && loopback) else { throw ScanCloudError.message(tr("Usa HTTPS. HTTP solo se permite para localhost, 127.0.0.1 o ::1.")) }
        if let port = components.port, !(1...65535).contains(port) { throw ScanCloudError.message(tr("Puerto de servidor inválido.")) }
        components.scheme = scheme; components.host = host; components.path = ""
        guard let url = components.url else { throw ScanCloudError.message(tr("La dirección del servidor no es válida.")) }
        return url
    }
    var authenticated: Bool { !bearer.isEmpty && (try? Self.validatedEndpoint(endpoint)) == authenticatedEndpoint }
    func canShare(_ id: UUID?) -> Bool { guard let id else { return false }; return authenticated && syncedIDs.contains(id) }

    private func call<T: Decodable>(_ type: T.Type, base: URL, path: String, method: String = "GET", body: Data? = nil, token: String? = nil) async throws -> T {
        let destination = base.appendingPathComponent(path)
        var request = URLRequest(url: destination); request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScanCloudError.message(tr("El servidor no devolvió una respuesta HTTP.")) }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw ScanCloudError.message(tr("Credenciales incorrectas o sesión caducada. Inicia sesión de nuevo."))
            case 409: throw ScanCloudError.message(tr("Conflicto: otro equipo cambió un documento. La sincronización se detuvo; las copias locales se conservan. Vuelve a sincronizar."))
            case 300..<400: throw ScanCloudError.message(tr("El servidor intentó redirigir la solicitud. Las redirecciones están bloqueadas; escribe la dirección final del servidor."))
            default: throw ScanCloudError.message(tr("El servidor devolvió HTTP {0}. La operación quedó incompleta.", String(describing: http.statusCode)))
            }
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func validateService(_ base: URL) async throws {
        let health = try await call(ScanCloudHealth.self, base: base, path: "health")
        guard health.status == "ok", health.service == "ScanMacPrivate", health.api_version == 1 else { throw ScanCloudError.message(tr("La dirección no corresponde a un servidor ScanMac compatible.")) }
    }

    func authenticate(register: Bool) async {
        guard !running else { return }
        running = true; problem = nil; defer { running = false; password = "" }
        do {
            let base = try Self.validatedEndpoint(endpoint)
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !password.isEmpty else { throw ScanCloudError.message(tr("Escribe usuario y contraseña.")) }
            try await validateService(base)
            let payload = try JSONSerialization.data(withJSONObject: ["username": user, "password": password])
            let result = try await call(ScanCloudAuth.self, base: base, path: register ? "v1/register" : "v1/login", method: "POST", body: payload)
            guard !result.token.isEmpty, !result.username.isEmpty else { throw ScanCloudError.message(tr("La sesión recibida no es válida.")) }
            try ScanCloudKeychain.save(result.token, endpoint: base, username: result.username)
            bearer = result.token; authenticatedEndpoint = base; account = result.username; username = result.username; syncedIDs = []; shareURL = nil
            status = tr("Sesión iniciada como {0}. Pulsa Sincronizar para transferir documentos.", String(describing: account))
        } catch { problem = error.localizedDescription }
    }
    func restoreSession() {
        guard !running else { return }; problem = nil
        do {
            let base = try Self.validatedEndpoint(endpoint); let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty else { throw ScanCloudError.message(tr("Escribe el usuario de la sesión guardada.")) }
            bearer = try ScanCloudKeychain.read(endpoint: base, username: user); authenticatedEndpoint = base; account = user; syncedIDs = []; shareURL = nil
            status = tr("Sesión recuperada del Llavero. Se validará al sincronizar.")
        } catch { problem = error.localizedDescription }
    }
    func logout() {
        guard !running else { return }; problem = nil
        do { if let authenticatedEndpoint { try ScanCloudKeychain.remove(endpoint: authenticatedEndpoint, username: account) }; bearer = ""; authenticatedEndpoint = nil; account = ""; syncedIDs = []; shareURL = nil; password = ""; status = tr("Sesión local cerrada y eliminada del Llavero.") }
        catch { problem = error.localizedDescription }
    }

    private func reloadLibrary(_ lib: Library) {
        lib.sessions = [:]; lib.redoHistory = []
        if let data = try? Data(contentsOf: lib.root.appendingPathComponent("library.json")), let records = try? JSONDecoder().decode([Record].self, from: data) { lib.records = records }
        lib.folders = Array(Set(lib.folders + lib.records.compactMap(\.folder))).sorted()
        if let selected = lib.selected {
            lib.document = PDFDocument(url: lib.url(selected)); lib.page = min(lib.page, max(0, (lib.document?.pageCount ?? 1) - 1)); lib.history = []; lib.revision = UUID()
        }
    }
    private func recordBytes(_ record: Record) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(record) }

    func synchronize(_ lib: Library) async {
        guard !running, !lib.busy, authenticated, let base = authenticatedEndpoint else { return }
        running = true; lib.busy = true; problem = nil; shareURL = nil
        let token = bearer; let snapshot = lib.records
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScanMacCloud-" + UUID().uuidString, isDirectory: true)
        defer { reloadLibrary(lib); try? FileManager.default.removeItem(at: folder); running = false; lib.busy = false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            status = tr("Consultando biblioteca del servidor…")
            try await validateService(base)
            let list = try await call(ScanCloudListing.self, base: base, path: "v1/documents", token: token)
            guard Set(list.documents.map { $0.record.id }).count == list.documents.count else { throw ScanCloudError.message(tr("El servidor devolvió documentos duplicados.")) }
            var remote: [UUID: ScanCloudDocument] = [:]; var remotePDF: [UUID: Data] = [:]
            for (index, entry) in list.documents.enumerated() {
                status = tr("Descargando {0} de {1}…", String(describing: index + 1), String(describing: list.documents.count))
                let document = try await call(ScanCloudDocument.self, base: base, path: "v1/documents/" + entry.record.id.uuidString, token: token)
                guard document.record.id == entry.record.id, document.version == entry.version, document.version > 0,
                      let bytes = Data(base64Encoded: document.pdf_base64), let pdf = PDFDocument(data: bytes), !pdf.isLocked, pdf.pageCount > 0 else {
                    throw ScanCloudError.message(tr("Un documento cambió durante la descarga o su PDF no es válido. Vuelve a sincronizar."))
                }
                remote[entry.record.id] = document; remotePDF[entry.record.id] = bytes
                try bytes.write(to: folder.appendingPathComponent(entry.record.id.uuidString + ".pdf"), options: .atomic)
            }
            try JSONEncoder().encode(list.documents.compactMap { remote[$0.record.id]?.record }).write(to: folder.appendingPathComponent("scanmac-library.json"), options: .atomic)
            status = tr("Combinando documentos y preservando conflictos…")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(lib.records) == encoder.encode(snapshot) else { throw ScanCloudError.message(tr("La biblioteca local cambió durante la descarga. No se combinó; vuelve a sincronizar.")) }
            let outcome = try FolderSync.synchronize(local: lib.root, remote: folder, records: snapshot)
            lib.records = outcome.records
            var uploaded = 0; var confirmed = Set<UUID>()
            for (index, record) in outcome.records.enumerated() {
                let bytes = try Data(contentsOf: lib.url(record.id))
                if let existing = remote[record.id], remotePDF[record.id] == bytes, try recordBytes(existing.record) == recordBytes(record) { confirmed.insert(record.id); continue }
                status = tr("Subiendo {0} de {1}…", String(describing: index + 1), String(describing: outcome.records.count))
                let payload = ScanCloudUpload(record: record, pdf_base64: bytes.base64EncodedString(), expected_version: remote[record.id]?.version ?? 0)
                let result = try await call(ScanCloudEntry.self, base: base, path: "v1/documents/" + record.id.uuidString, method: "PUT", body: JSONEncoder().encode(payload), token: token)
                guard result.record.id == record.id, result.version > 0 else { throw ScanCloudError.message(tr("El servidor no confirmó correctamente la subida.")) }
                confirmed.insert(record.id); uploaded += 1
            }
            syncedIDs = confirmed
            status = tr("Sincronizado: {0} recibidos, {1} subidos, {2} conflictos conservados.", String(describing: outcome.imported), String(describing: uploaded), String(describing: outcome.conflicts))
            lib.message = status
        } catch { syncedIDs = []; problem = error.localizedDescription; status = tr("Sincronización incompleta. Revisa el error y vuelve a intentarlo.") }
    }

    func createShare(id: UUID?) async {
        guard !running, canShare(id), let id, let base = authenticatedEndpoint else { return }
        running = true; problem = nil; shareURL = nil; defer { running = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["document_id": id.uuidString, "expires_hours": shareHours])
            let result = try await call(ScanCloudShare.self, base: base, path: "v1/shares", method: "POST", body: body, token: bearer)
            guard result.url_path.hasPrefix("/s/"), !result.url_path.contains("?"), !result.url_path.contains("#"), !result.url_path.contains(".."), !result.url_path.contains(":") else { throw ScanCloudError.message(tr("El servidor devolvió un enlace no válido.")) }
            let url = base.appendingPathComponent(String(result.url_path.dropFirst()))
            guard url.host == base.host, url.scheme == base.scheme, url.port == base.port else { throw ScanCloudError.message(tr("El enlace apunta a un servidor diferente.")) }
            shareURL = url; status = tr("Local link expires in {0} hours", String(shareHours))
        } catch { problem = error.localizedDescription }
    }
}

@MainActor final class LocalCloudServer: ObservableObject {
    static let shared = LocalCloudServer()
    @Published private(set) var running = false
    @Published private(set) var message = tr("Servidor local detenido")
    private var process: Process?

    private func portAvailable() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(8765).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
    func start(root: URL) {
        guard process == nil else { return }
        guard portAvailable() else { message = tr("El puerto 8765 está ocupado o no está disponible. No se modificó el otro proceso."); return }
        guard let script = Bundle.main.url(forResource: "server", withExtension: "py", subdirectory: "Server") else { message = tr("No se encontró Server/server.py dentro de ScanMac.app."); return }
        let data = root.appendingPathComponent("LocalServer", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            task.arguments = [script.path, "--host", "127.0.0.1", "--port", "8765", "--data-dir", data.path]
            // No request paths, session tokens, passwords or document contents are logged by this launcher.
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            task.terminationHandler = { completed in
                DispatchQueue.main.async {
                    guard self.process === completed else { return }
                    self.process = nil; self.running = false
                    self.message = completed.terminationStatus == 0 || completed.terminationReason == .uncaughtSignal ? tr("Servidor local detenido") : tr("El servidor local terminó (código {0}). Comprueba Python 3 y el puerto 8765.", String(completed.terminationStatus))
                }
            }
            process = task
            try task.run(); running = true
            message = tr("Servidor local iniciado en 127.0.0.1:8765 · Solo accesible desde este Mac")
        } catch { process = nil; running = false; message = tr("No se pudo iniciar el servidor: ") + error.localizedDescription }
    }
    func stop() {
        guard let process else { return }
        if process.isRunning { process.terminate(); message = tr("Deteniendo servidor local…") }
        else { self.process = nil; running = false; message = tr("Servidor local detenido") }
    }
}

struct CloudAccountPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cloud = ScanCloudAccountModel()
    @ObservedObject private var localServer = LocalCloudServer.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(tr("Cuenta y nube propia")).font(.title2.bold()); Spacer(); Button(tr("Cerrar")) { dismiss() }.disabled(cloud.running) }
            Text(tr("Cuenta y documentos alojados únicamente en este Mac. Inicia el servidor y crea tu cuenta local; permanece activo mientras ScanMac esté abierto.")).foregroundStyle(.secondary)
            HStack { Button(tr("Iniciar servidor local")) { localServer.start(root: lib.root) }.disabled(localServer.running || cloud.running); Button(tr("Detener mi servidor")) { localServer.stop() }.disabled(!localServer.running || cloud.running) }
            Text(trStatus(localServer.message)).font(.caption).textSelection(.enabled)
            TextField(tr("Servidor local: http://127.0.0.1:8765"), text: $cloud.endpoint).disabled(cloud.running)
            HStack { TextField(tr("Usuario"), text: $cloud.username); SecureField(tr("Contraseña"), text: $cloud.password) }.disabled(cloud.running)
            HStack {
                Button(tr("Crear cuenta")) { Task { await cloud.authenticate(register: true) } }
                Button(tr("Iniciar sesión")) { Task { await cloud.authenticate(register: false) } }
                Button(tr("Recuperar sesión guardada")) { cloud.restoreSession() }
                Button(tr("Cerrar sesión")) { cloud.logout() }.disabled(cloud.account.isEmpty)
            }.disabled(cloud.running)
            Text(tr("Usuario: 3–64 letras, números, punto, guion o guion bajo. Contraseña: mínimo 10 caracteres.")).font(.caption).foregroundStyle(.secondary)
            Text(tr("La contraseña solo se envía cuando pulsas Crear cuenta o Iniciar sesión; no se guarda. El token de sesión se guarda en el Llavero de este Mac. Las redirecciones están bloqueadas.")).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(tr("Sincronizar ahora transfiere TODOS los PDF y metadatos de esta biblioteca, incluidos texto OCR y documentos de la papelera, a la cuenta de este servidor; también descarga sus documentos. Los conflictos conservan una copia. La sincronización es manual y no propaga eliminaciones definitivas.")).font(.callout)
            Button(tr("Sincronizar ahora")) { Task { await cloud.synchronize(lib) } }.buttonStyle(.borderedProminent).disabled(!cloud.authenticated || cloud.running || lib.busy)
            Divider()
            Text(tr("Enlace de lectura del documento seleccionado")).font(.headline)
            Text(tr("Local links work only on this Mac while the private server is running. Sync first to include recent changes.")).font(.caption).foregroundStyle(.secondary)
            Picker(tr("Link expiration"), selection: $cloud.shareHours) { Text(tr("1 hour")).tag(1); Text(tr("1 day")).tag(24); Text(tr("7 days")).tag(168); Text(tr("30 days")).tag(720) }
            Button(tr("Create local link")) { Task { await cloud.createShare(id: lib.selected) } }.disabled(!cloud.canShare(lib.selected) || cloud.running)
            if let url = cloud.shareURL {
                Text(url.absoluteString).textSelection(.enabled)
                Button(tr("Copiar enlace")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }.disabled(cloud.running)
            }
            if cloud.running { ProgressView().controlSize(.small) }
            Text(trStatus(cloud.status)).font(.caption).textSelection(.enabled)
            if let problem = cloud.problem { Text(trStatus(problem)).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(24).frame(width: 740)
        .interactiveDismissDisabled(cloud.running)
    }
}
