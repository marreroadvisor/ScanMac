import SwiftUI
import AppKit
import PDFKit

extension Library {
    func reorderPage(from: Int, to: Int) {
        guard let doc = document, from != to, (0..<doc.pageCount).contains(from), (0..<doc.pageCount).contains(to), let p = doc.page(at: from) else { return }
        snapshot(); doc.removePage(at: from); doc.insert(p, at: to); page = to; invalidateText(); persist()
    }
    func deletePages(_ indexes: Set<Int>) {
        guard let doc = document, !indexes.isEmpty, indexes.allSatisfy({ (0..<doc.pageCount).contains($0) }), indexes.count < doc.pageCount else { error = tr("Conserva al menos una página en el documento."); return }
        snapshot(); for i in indexes.sorted(by: >) { doc.removePage(at: i) }; page = min(page, doc.pageCount - 1); invalidateText(); persist()
    }
    func duplicatePages(_ indexes: Set<Int>) {
        guard let doc = document, !indexes.isEmpty, indexes.allSatisfy({ (0..<doc.pageCount).contains($0) }) else { return }
        snapshot(); for i in indexes.sorted(by: >) { if let p = doc.page(at: i)?.copy() as? PDFPage { doc.insert(p, at: i + 1) } }; invalidateText(); persist()
    }
    func rotatePages(_ indexes: Set<Int>) {
        guard let doc = document, !indexes.isEmpty else { return }; snapshot()
        for i in indexes { if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }; invalidateText(); persist()
    }
    func insertBlankPage() {
        guard let doc = document else { return }
        let image = NSImage(size: NSSize(width: 612, height: 792)); image.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 612, height: 792)).fill(); image.unlockFocus()
        guard let blank = PDFPage(image: image) else { return }; snapshot(); doc.insert(blank, at: min(page + 1, doc.pageCount)); page += 1; invalidateText(); persist()
    }
    func splitIntoLibrary() {
        guard let doc = document else { return }
        let title = current?.name ?? "Documento"; let oldRecords = records; var written: [URL] = []
        do {
            for i in 0..<doc.pageCount {
                let one = PDFDocument(); guard let copy = doc.page(at: i)?.copy() as? PDFPage else { throw CocoaError(.fileReadCorruptFile) }; one.insert(copy, at: 0)
                guard let data = one.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                let id = UUID(); let destination = url(id); try data.write(to: destination, options: .atomic); written.append(destination)
                records.append(Record(id: id, name: title + " — página \(i + 1)", date: Date(), folder: current?.folder))
            }
            try saveIndex(); message = tr("Se crearon {0} documentos; original conservado", String(describing: doc.pageCount))
        } catch { records = oldRecords; for file in written { try? FileManager.default.removeItem(at: file) }; self.error = error.localizedDescription }
    }
}

struct PageOrganizerPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) var dismiss
    @State var selected: Set<Int> = []
    @State var range = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(tr("Organizar páginas")).font(.title2.bold()); Spacer(); Button(tr("Cerrar")) { dismiss() } }
            Text(tr("Arrastra las miniaturas para reordenarlas. Marca varias para editar en lote.")).foregroundStyle(.secondary)
            HStack { TextField(tr("Seleccionar rango: 1,3-5"), text: $range); Button(tr("Seleccionar")) { do { selected = Set(try Library.advancedPageIndexes(range, pageCount: lib.document?.pageCount ?? 0)) } catch { lib.error = error.localizedDescription } }; Button(tr("Todas")) { selected = Set(0..<(lib.document?.pageCount ?? 0)) }; Button(tr("Ninguna")) { selected = [] } }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], spacing: 20) {
                    if let doc = lib.document { ForEach(0..<doc.pageCount, id: \.self) { i in
                        VStack { if let p = doc.page(at: i) { Image(nsImage: p.thumbnail(of: NSSize(width: 105, height: 145), for: .cropBox)).resizable().scaledToFit().frame(width: 105, height: 145) }; Toggle(tr("Página {0}", String(describing: i + 1)), isOn: Binding(get: { selected.contains(i) }, set: { if $0 { selected.insert(i) } else { selected.remove(i) } })).toggleStyle(.checkbox) }.padding(9).background(selected.contains(i) ? Color.teal.opacity(0.15) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .draggable(String(i)).dropDestination(for: String.self) { items, _ in guard let item = items.first, let from = Int(item) else { return false }; lib.reorderPage(from: from, to: i); selected = []; return true }
                    } }
                }.padding(5)
            }.id(lib.revision)
            HStack { Button(tr("Girar selección")) { lib.rotatePages(selected) }.disabled(selected.isEmpty); Button(tr("Duplicar")) { lib.duplicatePages(selected); selected = [] }.disabled(selected.isEmpty); Button(tr("Eliminar selección"), role: .destructive) { lib.deletePages(selected); selected = [] }.disabled(selected.isEmpty || selected.count >= (lib.document?.pageCount ?? 0)); Spacer(); Button(tr("Deshacer")) { lib.undo(); selected = [] }.disabled(lib.history.isEmpty) }
            HStack { Button(tr("Insertar página vacía")) { lib.insertBlankPage(); selected = [] }; Button(tr("Añadir archivo")) { lib.chooseImport(append: true); selected = [] }; Button(tr("Dividir en documentos individuales")) { lib.splitIntoLibrary() } }
            if let error = lib.error { Text(trStatus(error)).foregroundStyle(.red) }
            Text(trStatus(lib.message)).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 760, height: 650).disabled(lib.busy)
    }
}
