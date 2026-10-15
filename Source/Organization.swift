import SwiftUI
import AppKit
import PDFKit

extension Library {
    func browse(_ section: String, folder: String? = nil) {
        guard !busy else { return }
        storeSession(); selected = nil; document = nil; query = ""; folderFilter = folder
        rootFolderOnly = section == "Todos" || section == "Carpeta"
        trashOnly = section == "Papelera"; starredOnly = section == "Favoritos"; signedOnly = section == "Firmados"
    }
    func createFolder(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !folders.contains(clean) else { return }
        folders.append(clean); folders.sort()
        do { try JSONEncoder().encode(folders).write(to: root.appendingPathComponent("folders.json"), options: .atomic) } catch { self.error = error.localizedDescription }
    }
    func duplicateDocument(_ id: UUID) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        let newID = UUID()
        do { try FileManager.default.copyItem(at: url(id), to: url(newID)); record.id = newID; record.name += " — copia"; record.date = Date(); record.updatedAt = Date(); record.trashedAt = nil; records.append(record); try saveIndex(); select(newID) }
        catch { self.error = error.localizedDescription }
    }
    func mergeRecords(_ ids: Set<UUID>) {
        let combined = PDFDocument()
        for record in records.filter({ ids.contains($0.id) && $0.trashedAt == nil }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            guard let doc = PDFDocument(url: url(record.id)), !doc.isLocked else { error = tr("No se pudo leer {0}", String(describing: record.name)); return }
            for i in 0..<doc.pageCount { if let p = doc.page(at: i)?.copy() as? PDFPage { combined.insert(p, at: combined.pageCount) } }
        }
        guard combined.pageCount > 0, let data = combined.dataRepresentation() else { return }
        let id = UUID()
        do { try data.write(to: url(id), options: .atomic); records.append(Record(id: id, name: "Documentos unidos", date: Date())); try saveIndex(); select(id) } catch { self.error = error.localizedDescription }
    }
    func shareDocument() { guard let id = selected else { return }; let picker = NSSharingServicePicker(items: [url(id)]); if let view = NSApp.keyWindow?.contentView { picker.show(relativeTo: CGRect(x: view.bounds.maxX - 150, y: view.bounds.maxY - 80, width: 1, height: 1), of: view, preferredEdge: .minY) } }
    func importRichText() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .rtf, .html, .init(filenameExtension: "docx")!]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importRichText(source: source)
    }
    func importRichText(source: URL) {
        do {
            let content: NSAttributedString
            if ["txt", "md"].contains(source.pathExtension.lowercased()) { content = NSAttributedString(string: try String(contentsOf: source, encoding: .utf8), attributes: [.font: NSFont.systemFont(ofSize: 12)]) }
            else { content = try NSAttributedString(url: source, options: [:], documentAttributes: nil) }
            let storage = NSTextStorage(attributedString: content); let layout = NSLayoutManager(); storage.addLayoutManager(layout)
            let pdf = PDFDocument(); var glyph = 0
            repeat {
                let container = NSTextContainer(size: NSSize(width: 500, height: 680)); container.lineFragmentPadding = 0; layout.addTextContainer(container)
                let range = layout.glyphRange(for: container)
                let data = NSMutableData(); var media = CGRect(x: 0, y: 0, width: 612, height: 792)
                guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw CocoaError(.fileWriteUnknown) }
                context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(media)
                context.translateBy(x: 56, y: 736); context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                layout.drawBackground(forGlyphRange: range, at: .zero); layout.drawGlyphs(forGlyphRange: range, at: .zero)
                NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
                if let p = PDFDocument(data: data as Data)?.page(at: 0)?.copy() as? PDFPage { pdf.insert(p, at: pdf.pageCount) }
                let next = NSMaxRange(range); if next <= glyph { break }; glyph = next
            } while glyph < layout.numberOfGlyphs
            guard let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            let id = UUID(); try data.write(to: url(id), options: .atomic); records.append(Record(id: id, name: source.deletingPathExtension().lastPathComponent, date: Date(), text: content.string)); try saveIndex(); select(id)
        } catch { self.error = error.localizedDescription }
    }
}

struct OrganizePanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) var dismiss
    @State var folder = ""
    @State var tags = ""
    @State var ids: Set<UUID> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(tr("Organizar documentos")).font(.title2.bold()); Spacer(); Button(tr("Cerrar")) { dismiss() } }
            HStack { TextField(tr("Nueva carpeta"), text: $folder); Button(tr("Crear carpeta")) { lib.createFolder(folder); folder = "" }.disabled(folder.isEmpty) }
            if lib.current != nil {
                Picker(tr("Carpeta del documento"), selection: Binding(get: { lib.current?.folder ?? "" }, set: { value in lib.update { $0.folder = value.isEmpty ? nil : value } })) { Text(tr("Sin carpeta")).tag(""); ForEach(lib.folders, id: \.self) { Text($0).tag($0) } }
                HStack { TextField(tr("Etiquetas separadas por comas"), text: $tags); Button(tr("Guardar etiquetas")) { lib.update { $0.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } } }
                Button(tr("Duplicar documento actual")) { if let id = lib.selected { lib.duplicateDocument(id) } }
            }
            Divider(); Text(tr("Unir copias de documentos (orden alfabético)")).font(.headline)
            List(lib.records.filter { $0.trashedAt == nil }) { record in
                Toggle(record.name, isOn: Binding(get: { ids.contains(record.id) }, set: { if $0 { ids.insert(record.id) } else { ids.remove(record.id) } }))
            }.frame(height: 230)
            Button(tr("Unir {0} documentos", String(describing: ids.count))) { lib.mergeRecords(ids); dismiss() }.disabled(ids.count < 2)
        }.padding(24).frame(width: 610).onAppear { tags = (lib.current?.tags ?? []).joined(separator: ", ") }
    }
}

extension Library {
    func toggleFavorite(_ id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].starred.toggle(); records[i].updatedAt = Date()
        do { try saveIndex() } catch { self.error = error.localizedDescription }
    }
}
