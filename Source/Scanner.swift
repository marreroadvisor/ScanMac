import SwiftUI
import AppKit
import Quartz
import ImageCaptureCore

struct ScannerEntry: Identifiable {
    let id = UUID()
    let device: ICScannerDevice
}

@MainActor final class ScannerDiscovery: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate {
    @Published var devices: [ScannerEntry] = []
    @Published var selected: UUID?
    @Published var searching = false
    @Published var status = tr("Pulsa Buscar escáneres para detectar dispositivos USB y Bonjour compatibles con Captura de Imagen de macOS.")
    private var browser: ICDeviceBrowser?
    var selectedDevice: ICScannerDevice? { devices.first { $0.id == selected }?.device }
    func start() {
        stop()
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue)!
        self.browser = browser; searching = true
        status = tr("Buscando escáneres. Si no aparece ninguno, comprueba la conexión y el controlador del fabricante.")
        browser.start()
    }
    func stop() {
        for entry in devices where entry.device.hasOpenSession { entry.device.requestCloseSession() }
        browser?.stop(); browser?.delegate = nil; browser = nil
        devices = []; selected = nil; searching = false
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice, !devices.contains(where: { $0.device === scanner }) else { return }
        devices.append(ScannerEntry(device: scanner))
        status = tr("{0} escáner(es) encontrado(s). Selecciona uno para abrir sus controles.", String(describing: devices.count))
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let removed = devices.first { $0.device === device }?.id
        devices.removeAll { $0.device === device }
        if selected == removed { selected = nil }
        status = devices.isEmpty ? tr("No hay escáneres disponibles.") : tr("{0} escáner(es) disponible(s).", String(devices.count))
    }
    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        if devices.isEmpty { status = tr("No se encontraron escáneres locales. Se continúa buscando dispositivos Bonjour mientras este panel permanece abierto.") }
    }
}

struct NativeScannerView: NSViewRepresentable {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    let device: ICScannerDevice
    let onScan: (Data?, URL?, Error?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }
    func makeNSView(context: Context) -> IKScannerDeviceView {
        let view = IKScannerDeviceView(frame: NSRect(x: 0, y: 0, width: 800, height: 490))
        view.delegate = context.coordinator; view.transferMode = .memoryBased
        view.hasDisplayModeSimple = true; view.hasDisplayModeAdvanced = true; view.mode = .advanced
        view.displaysDownloadsDirectoryControl = false; view.displaysPostProcessApplicationControl = false
        view.scanControlLabel = tr("Escanear"); view.overviewControlLabel = tr("Vista previa")
        view.scannerDevice = device
        return view
    }
    func updateNSView(_ view: IKScannerDeviceView, context: Context) {
        context.coordinator.onScan = onScan
        view.scanControlLabel = tr("Escanear"); view.overviewControlLabel = tr("Vista previa")
        if view.scannerDevice !== device {
            let previous = view.scannerDevice
            view.scannerDevice = nil
            if previous?.hasOpenSession == true { previous?.requestCloseSession() }
            view.scannerDevice = device
        }
    }
    static func dismantleNSView(_ view: IKScannerDeviceView, coordinator: Coordinator) {
        coordinator.active = false; view.delegate = nil
        let device = view.scannerDevice; view.scannerDevice = nil
        if device?.hasOpenSession == true { device?.requestCloseSession() }
    }
    final class Coordinator: NSObject, IKScannerDeviceViewDelegate {
        var onScan: (Data?, URL?, Error?) -> Void
        var active = true
        init(onScan: @escaping (Data?, URL?, Error?) -> Void) { self.onScan = onScan }
        func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didScanTo url: URL!, fileData data: Data!, error: (any Error)!) {
            guard active else { return }; onScan(data, url, error)
        }
        func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didEncounterError error: (any Error)!) {
            guard active else { return }; onScan(nil, nil, error)
        }
    }
}

struct ScannerPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = ScannerDiscovery()
    @State private var append = false
    @State private var captured = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("Escáner físico")).font(.title2.bold()); Spacer()
                Button(tr("Cerrar")) { discovery.stop(); dismiss() }
            }
            HStack {
                Button(tr(discovery.searching ? "Volver a buscar" : "Buscar escáneres")) { discovery.start() }
                if discovery.searching { Button(tr("Detener búsqueda")) { discovery.stop() } }
                if !discovery.devices.isEmpty {
                    Picker(tr("Dispositivo"), selection: $discovery.selected) {
                        Text(tr("Seleccionar…")).tag(Optional<UUID>.none)
                        ForEach(discovery.devices) { entry in Text(entry.device.name ?? tr("Escáner")).tag(Optional(entry.id)) }
                    }.frame(maxWidth: 370)
                }
            }
            Text(trStatus(discovery.status)).font(.callout).foregroundStyle(.secondary)
            Toggle(tr("Añadir páginas al documento abierto"), isOn: $append).disabled(lib.document == nil)
            if let device = discovery.selectedDevice {
                NativeScannerView(device: device, onScan: receive).frame(minWidth: 800, minHeight: 490)
            } else {
                VStack(spacing: 12) { Image(systemName: "scanner").font(.system(size: 48)).foregroundStyle(.secondary); Text(tr("Selecciona un escáner compatible para ajustar resolución, color y área de captura.")).foregroundStyle(.secondary) }.frame(minWidth: 800, minHeight: 300)
            }
            Text(tr("Páginas recibidas: {0}. La búsqueda comienza solo cuando la solicitas; inicia cada captura con el control Escanear. Las funciones disponibles dependen del dispositivo y su controlador.", String(describing: captured))).font(.caption).foregroundStyle(.secondary)
        }.padding(20).onDisappear { discovery.stop() }
    }
    private func receive(_ bytes: Data?, _ url: URL?, _ error: Error?) {
        if let error { lib.error = tr("El escáner informó un error: ") + error.localizedDescription; return }
        do {
            let data: Data
            if let bytes { data = bytes }
            else if let url { data = try Data(contentsOf: url) }
            else { return }
            guard let image = NSImage(data: data), let tiff = image.tiffRepresentation else { lib.error = tr("El escáner no devolvió una imagen válida."); return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let imageURL = folder.appendingPathComponent("Escaneo \(captured + 1).tiff")
            try tiff.write(to: imageURL, options: .atomic)
            lib.importFiles([imageURL], append: append && lib.document != nil)
            captured += 1
            // Multi-page feeder captures form one document after its first successful page.
            append = true
        } catch { lib.error = tr("No se pudo importar la captura: ") + error.localizedDescription }
    }
}
