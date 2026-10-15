import SwiftUI
import AppKit
import PDFKit

struct FolderSyncResult {
    var records: [Record]
    var imported: Int
    var exported: Int
    var conflicts: Int
}

enum FolderSync {
    private static func failure(_ text: String) -> NSError { NSError(domain: "ScanMacSync", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    /// Reads and validates all source files before mutating either library. No network API is used.
    static func synchronize(local: URL, remote: URL, records: [Record]) throws -> FolderSyncResult {
        let fm = FileManager.default
        let localPath = local.standardizedFileURL.resolvingSymlinksInPath().path
        let remotePath = remote.standardizedFileURL.resolvingSymlinksInPath().path
        guard localPath != remotePath, !remotePath.hasPrefix(localPath + "/"), !localPath.hasPrefix(remotePath + "/") else { throw failure(tr("Elige una carpeta externa a la biblioteca local de ScanMac.")) }
        let index = remote.appendingPathComponent("scanmac-library.json")
        let originalIndex: Data? = fm.fileExists(atPath: index.path) ? try Data(contentsOf: index) : nil
        let remoteRecords = try originalIndex.map { try JSONDecoder().decode([Record].self, from: $0) } ?? []
        guard Set(records.map(\.id)).count == records.count, Set(remoteRecords.map(\.id)).count == remoteRecords.count else { throw failure(tr("El índice contiene identificadores duplicados; no se modificó la biblioteca compartida.")) }
        func load(_ list: [Record], from root: URL) throws -> [UUID: Data] {
            var all: [UUID: Data] = [:]
            for record in list {
                let file = root.appendingPathComponent(record.id.uuidString + ".pdf")
                guard fm.fileExists(atPath: file.path) else { throw failure(tr("Falta el PDF de «{0}» en {1}. Espera a que tu proveedor descargue los archivos y vuelve a intentarlo.", String(describing: record.name), String(describing: root.path))) }
                let bytes = try Data(contentsOf: file)
                guard let pdf = PDFDocument(data: bytes), pdf.pageCount > 0 else { throw failure(tr("El PDF de «{0}» no es válido o todavía no se ha descargado.", String(describing: record.name))) }
                all[record.id] = bytes
            }
            return all
        }
        let localData = try load(records, from: local)
        let remoteData = try load(remoteRecords, from: remote)
        var localResult = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var remoteResult = Dictionary(uniqueKeysWithValues: remoteRecords.map { ($0.id, $0) })
        var localWrites: [UUID: Data] = [:], remoteWrites: [UUID: Data] = [:]
        var imported = 0, exported = 0, conflicts = 0
        for remoteRecord in remoteRecords {
            let id = remoteRecord.id
            guard let localRecord = localResult[id] else {
                localResult[id] = remoteRecord; localWrites[id] = remoteData[id]; imported += 1; continue
            }
            let remoteNewer = (remoteRecord.updatedAt ?? remoteRecord.date) > (localRecord.updatedAt ?? localRecord.date)
            if localData[id] == remoteData[id] {
                if remoteNewer { localResult[id] = remoteRecord }
                else { remoteResult[id] = localRecord }
                continue
            }
            // Preserve the losing version locally. It is uploaded on the next explicit sync.
            var copy = remoteNewer ? localRecord : remoteRecord
            copy.id = UUID(); copy.name += " (conflicto conservado)"; copy.date = Date(); copy.updatedAt = copy.date; copy.trashedAt = nil
            localResult[copy.id] = copy; localWrites[copy.id] = remoteNewer ? localData[id] : remoteData[id]; conflicts += 1
            if remoteNewer { localResult[id] = remoteRecord; localWrites[id] = remoteData[id]; imported += 1 }
            else { remoteResult[id] = localRecord; remoteWrites[id] = localData[id]; exported += 1 }
        }
        for record in records where remoteResult[record.id] == nil {
            remoteResult[record.id] = record; remoteWrites[record.id] = localData[record.id]; exported += 1
        }
        // Abort if another writer changed the index while inputs were being read.
        let currentIndex: Data? = fm.fileExists(atPath: index.path) ? try Data(contentsOf: index) : nil
        guard currentIndex == originalIndex else { throw failure(tr("Otra instancia modificó la carpeta durante la lectura. Vuelve a sincronizar.")) }
        let localIndex = local.appendingPathComponent("library.json")
        let originalLocalIndex: Data? = fm.fileExists(atPath: localIndex.path) ? try Data(contentsOf: localIndex) : nil
        let finalLocal = localResult.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let localIndexBytes = try JSONEncoder().encode(finalLocal)
        let remoteIndexBytes = try JSONEncoder().encode(remoteResult.values.sorted { $0.id.uuidString < $1.id.uuidString })
        // A durable recovery journal exists before any original PDF or index is replaced.
        // Keep this journal after any commit failure, even if best-effort rollback succeeds.
        let recovery = local.appendingPathComponent("SyncRecovery", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let localBackup = recovery.appendingPathComponent("local", isDirectory: true)
        let remoteBackup = recovery.appendingPathComponent("remote", isDirectory: true)
        do {
            try fm.createDirectory(at: localBackup, withIntermediateDirectories: true)
            try fm.createDirectory(at: remoteBackup, withIntermediateDirectories: true)
            for (id, bytes) in localData { try bytes.write(to: localBackup.appendingPathComponent(id.uuidString + ".pdf"), options: .atomic) }
            for (id, bytes) in remoteData { try bytes.write(to: remoteBackup.appendingPathComponent(id.uuidString + ".pdf"), options: .atomic) }
            if let originalLocalIndex { try originalLocalIndex.write(to: localBackup.appendingPathComponent("library.json"), options: .atomic) }
            if let originalIndex { try originalIndex.write(to: remoteBackup.appendingPathComponent("scanmac-library.json"), options: .atomic) }
            // Preserve in-memory metadata as well when a previously unsaved index was absent.
            try JSONEncoder().encode(records).write(to: recovery.appendingPathComponent("local-records.json"), options: .atomic)
            let manifest: [String: Any] = ["localPath": local.path, "remotePath": remote.path, "localIndexExisted": originalLocalIndex != nil, "remoteIndexExisted": originalIndex != nil, "state": "prepared", "created": Date().description]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: recovery.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            // No original has been touched. Partial backup preparation can safely be removed.
            try? fm.removeItem(at: recovery)
            throw failure(tr("No se pudo preparar una copia de recuperación; no se modificó la biblioteca: ") + error.localizedDescription)
        }
        do {
            // First make all new IDs (including conflict backups) durable and discoverable.
            // Only after their index is saved may an existing original ID be replaced.
            for (id, bytes) in localWrites where localData[id] == nil {
                try bytes.write(to: local.appendingPathComponent(id.uuidString + ".pdf"), options: .atomic)
            }
            try localIndexBytes.write(to: localIndex, options: .atomic)
            for (id, bytes) in localWrites where localData[id] != nil {
                try bytes.write(to: local.appendingPathComponent(id.uuidString + ".pdf"), options: .atomic)
            }
            for (id, bytes) in remoteWrites { try bytes.write(to: remote.appendingPathComponent(id.uuidString + ".pdf"), options: .atomic) }
            try remoteIndexBytes.write(to: index, options: .atomic)
        } catch {
            let commitError = error.localizedDescription
            var rollbackFailures: [String] = []
            func restore(_ bytes: Data, to destination: URL) {
                do { try bytes.write(to: destination, options: .atomic) }
                catch { rollbackFailures.append(destination.lastPathComponent + ": " + error.localizedDescription) }
            }
            // Restore original bytes before indices. Never delete the recovery journal on failure.
            for (id, bytes) in localData { restore(bytes, to: local.appendingPathComponent(id.uuidString + ".pdf")) }
            for (id, bytes) in remoteData { restore(bytes, to: remote.appendingPathComponent(id.uuidString + ".pdf")) }
            if let originalLocalIndex { restore(originalLocalIndex, to: localIndex) }
            else if fm.fileExists(atPath: localIndex.path) {
                do { try fm.removeItem(at: localIndex) } catch { rollbackFailures.append("Índice local: " + error.localizedDescription) }
            }
            if let originalIndex { restore(originalIndex, to: index) }
            else if fm.fileExists(atPath: index.path) {
                do { try fm.removeItem(at: index) } catch { rollbackFailures.append("Índice compartido: " + error.localizedDescription) }
            }
            let report = "Error de escritura: " + commitError + "\n" + (rollbackFailures.isEmpty ? "Restauración de originales completada." : "Restauración incompleta:\n" + rollbackFailures.joined(separator: "\n"))
            try? report.write(to: recovery.appendingPathComponent("ERROR.txt"), atomically: true, encoding: .utf8)
            throw failure(report + "\nCopias de recuperación conservadas en: " + recovery.path)
        }
        // A cleanup failure leaves redundant backups, without invalidating a completed sync.
        try? fm.removeItem(at: recovery)
        return FolderSyncResult(records: finalLocal, imported: imported, exported: exported, conflicts: conflicts)
    }
}

extension Library {
    func restoreSyncLocation() {
        let saved = root.appendingPathComponent("sync-bookmark.data")
        guard let data = try? Data(contentsOf: saved) else { return }
        do {
            var stale = false
            let folder = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            syncFolder = folder
            if stale { let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }; try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil).write(to: saved, options: .atomic) }
        } catch { self.error = tr("Selecciona de nuevo la carpeta de sincronización: ") + error.localizedDescription }
    }
    func chooseSyncLocation() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.message = tr("Elige una carpeta dedicada para compartir tu biblioteca ScanMac.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { let data = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil); try data.write(to: root.appendingPathComponent("sync-bookmark.data"), options: .atomic); syncFolder = folder }
        catch { self.error = error.localizedDescription }
    }
    func synchronizeFolderNow() {
        guard !busy, let folder = syncFolder else { return }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() }; busy = false }
        busy = true
        do {
            let outcome = try FolderSync.synchronize(local: root, remote: folder, records: records)
            sessions = [:]; redoHistory = []; records = outcome.records; folders = Array(Set(folders + records.compactMap(\.folder))).sorted()
            if let id = selected { document = PDFDocument(url: url(id)); page = min(page, max(0, (document?.pageCount ?? 1) - 1)); history = []; redoHistory = []; sessions = [:]; revision = UUID() }
            message = tr("Sincronizado: {0} recibidos, {1} enviados, {2} conflictos conservados", String(describing: outcome.imported), String(describing: outcome.exported), String(describing: outcome.conflicts))
        } catch {
            // Reload both metadata and PDF state after rollback or any partially completed write.
            if let bytes = try? Data(contentsOf: root.appendingPathComponent("library.json")), let saved = try? JSONDecoder().decode([Record].self, from: bytes) { records = saved }
            folders = Array(Set(folders + records.compactMap(\.folder))).sorted()
            if let id = selected {
                document = PDFDocument(url: url(id))
                page = min(page, max(0, (document?.pageCount ?? 1) - 1))
            } else { document = nil }
            history = []; redoHistory = []; sessions = [:]; revision = UUID()
            self.error = tr("Sincronización incompleta: ") + error.localizedDescription
        }
    }
}

struct SyncPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(tr("Sincronizar mediante carpeta")).font(.title2.bold()); Spacer(); Button(tr("Cerrar")) { dismiss() } }
            Text(tr("Elige una carpeta dedicada de iCloud Drive, Dropbox u otro proveedor ya configurado en tu Mac, o una carpeta compartida. ScanMac copia los archivos; tu proveedor se encarga de transportarlos entre equipos."))
            Text(tr("Carpeta: ") + (lib.syncFolder?.path ?? "Sin seleccionar")).textSelection(.enabled).font(.callout).foregroundStyle(.secondary)
            Button(tr("Elegir carpeta…")) { lib.chooseSyncLocation() }
            Text(tr("Al pulsar Sincronizar ahora se copiarán todos los PDF y metadatos de la biblioteca, incluidos documentos de la papelera y texto OCR, a esa carpeta; también se importarán sus documentos. No se ejecuta en segundo plano. Las versiones diferentes se conservan como copias de conflicto locales y se enviarán en la próxima sincronización. No se propagan eliminaciones definitivas: elimina la copia de ambos equipos para evitar que vuelva a aparecer.")).font(.callout)
            Text(tr("Espera a que tu proveedor termine de descargar y subir los archivos. Evita sincronizar desde dos equipos a la vez.")).foregroundStyle(.secondary).font(.callout)
            HStack { Spacer(); Button(tr("Sincronizar ahora")) { lib.synchronizeFolderNow() }.buttonStyle(.borderedProminent).disabled(lib.syncFolder == nil || lib.busy) }
        }.padding(24).frame(width: 660)
    }
}
