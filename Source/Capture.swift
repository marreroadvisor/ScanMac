import SwiftUI
import AppKit
import PDFKit
import AVFoundation
import QuartzCore

final class ScanCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedID = ""
    @Published var running = false
    @Published var starting = false
    @Published var takingPhoto = false
    @Published var problem: String?
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "ScanMac.camera")
    private var onPhoto: ((Data) -> Void)?
    private var cancelled = false

    override init() {
        super.init()
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        selectedID = devices.first?.uniqueID ?? ""
    }

    func start() {
        guard !running, !starting else { return }
        cancelled = false; problem = nil; starting = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    guard !self.cancelled else { self.starting = false; return }
                    if granted { self.configureAndStart() }
                    else { self.starting = false; self.problem = tr("Permiso de cámara denegado. Puedes cambiarlo en Ajustes del Sistema > Privacidad y seguridad > Cámara.") }
                }
            }
        default:
            starting = false; problem = tr("Activa el permiso de cámara para ScanMac en Ajustes del Sistema > Privacidad y seguridad > Cámara.")
        }
    }

    private func configureAndStart() {
        guard let device = devices.first(where: { $0.uniqueID == selectedID }) else {
            starting = false; problem = tr("No hay una cámara disponible. Conecta una cámara y vuelve a abrir este panel."); return
        }
        queue.async {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                for previous in self.session.inputs { self.session.removeInput(previous) }
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration(); throw AdvancedPDFError.invalid(tr("No se pudo conectar la cámara seleccionada."))
                }
                self.session.addInput(input)
                if !self.session.outputs.contains(self.output) {
                    guard self.session.canAddOutput(self.output) else {
                        self.session.commitConfiguration(); throw AdvancedPDFError.invalid(tr("La cámara no permite capturar fotografías."))
                    }
                    self.session.addOutput(self.output)
                }
                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.starting = false
                    if self.cancelled { self.stop() } else { self.running = self.session.isRunning; if !self.running { self.problem = tr("No se pudo iniciar la cámara.") } }
                }
            } catch {
                DispatchQueue.main.async { self.starting = false; self.problem = error.localizedDescription }
            }
        }
    }

    func stop() {
        cancelled = true; running = false
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func capture(_ handler: @escaping (Data) -> Void) {
        guard running, !takingPhoto else { return }
        takingPhoto = true; onPhoto = handler
        queue.async { self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        DispatchQueue.main.async {
            self.takingPhoto = false
            if let error { self.problem = error.localizedDescription; self.onPhoto = nil; return }
            guard let data else { self.problem = tr("No se pudo leer la fotografía."); self.onPhoto = nil; return }
            guard !self.cancelled else { self.onPhoto = nil; return }
            self.onPhoto?(data); self.onPhoto = nil
        }
    }
}

private final class ScanCameraPreviewView: NSView {
    let cameraLayer = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true
        cameraLayer.videoGravity = .resizeAspect; layer?.addSublayer(cameraLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); cameraLayer.frame = bounds }
}

private struct ScanCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> ScanCameraPreviewView {
        let view = ScanCameraPreviewView(); view.cameraLayer.session = session; return view
    }
    func updateNSView(_ view: ScanCameraPreviewView, context: Context) { view.cameraLayer.session = session }
}

struct CameraPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = ScanCameraController()
    @State private var append = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(tr("Escanear con cámara")).font(.title2.bold()); Spacer(); Button(tr("Cerrar")) { camera.stop(); dismiss() } }
            Text(tr("Selecciona una cámara y pulsa Iniciar. Una cámara de Continuidad aparece si el iPhone y macOS la ofrecen.")).font(.callout).foregroundStyle(.secondary)
            Picker(tr("Cámara"), selection: $camera.selectedID) { ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } }.disabled(camera.running || camera.starting)
            ZStack {
                Color.black
                if camera.running { ScanCameraPreview(session: camera.session) }
                else { Text(tr(camera.starting ? "Iniciando cámara…" : "La cámara está apagada")).foregroundStyle(.white) }
            }.frame(width: 640, height: 360).clipShape(RoundedRectangle(cornerRadius: 12))
            Toggle(tr("Añadir al documento abierto"), isOn: $append).disabled(lib.document == nil)
            if let problem = camera.problem { Text(trStatus(problem)).foregroundStyle(.red).textSelection(.enabled) }
            if let problem = lib.error { Text(trStatus(problem)).foregroundStyle(.red) }
            HStack {
                Button(tr(camera.running ? "Detener cámara" : "Iniciar cámara")) { if camera.running { camera.stop() } else { camera.start() } }.disabled(camera.starting || camera.takingPhoto || camera.devices.isEmpty)
                Spacer()
                Button(tr(camera.takingPhoto ? "Capturando…" : "Capturar documento")) {
                    camera.capture { data in
                        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Escaneo-" + UUID().uuidString + ".jpg")
                        do {
                            try data.write(to: temporary, options: .atomic)
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            lib.importFiles([temporary], append: append && lib.document != nil)
                        } catch { lib.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(!camera.running || camera.takingPhoto || lib.busy)
            }
            Text(trStatus(lib.message)).font(.caption).foregroundStyle(.secondary)
        }.padding(24).onDisappear { camera.stop() }
    }
}

@MainActor extension Library {
    func captureScreenshot() {
        guard !busy else { return }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Captura-" + UUID().uuidString + ".png")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", destination.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        busy = true; message = tr("Selecciona una región de la pantalla · Esc para cancelar")
        process.terminationHandler = { task in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: destination) }
                self.busy = false
                if task.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) {
                    self.importFiles([destination]); self.message = tr("Captura de pantalla importada")
                } else { self.message = tr("Captura cancelada o no disponible · Revisa el permiso de grabación de pantalla si es necesario") }
            }
        }
        do { try process.run() }
        catch { busy = false; self.error = tr("No se pudo iniciar la captura de pantalla: ") + error.localizedDescription; try? FileManager.default.removeItem(at: destination) }
    }

    func captureIDCard(front: NSImage, back: NSImage?, title: String) {
        let pageSize = NSSize(width: 595, height: 842)
        let canvas = NSImage(size: pageSize)
        canvas.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: pageSize)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.black]
        (title as NSString).draw(in: CGRect(x: 40, y: 775, width: 515, height: 30), withAttributes: attributes)
        func drawCard(_ image: NSImage, rect: CGRect, label: String) {
            let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray]
            (label as NSString).draw(in: CGRect(x: rect.minX, y: rect.maxY + 8, width: rect.width, height: 18), withAttributes: labelAttributes)
            guard image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(rect.width / image.size.width, rect.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
        }
        drawCard(front, rect: CGRect(x: 170, y: 515, width: 255, height: 161), label: "Anverso")
        if let back { drawCard(back, rect: CGRect(x: 170, y: 270, width: 255, height: 161), label: "Reverso") }
        canvas.unlockFocus()
        guard let page = PDFPage(image: canvas) else { error = tr("No se pudo crear la hoja de identificación."); return }
        let document = PDFDocument(); document.insert(page, at: 0)
        guard let data = document.dataRepresentation() else { error = tr("No se pudo generar el PDF."); return }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Identificación-" + UUID().uuidString + ".pdf")
        do {
            try data.write(to: temporary, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporary) }
            importFiles([temporary])
            update { $0.name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Identificación" : title }
            message = tr("Identificación creada en hoja A4 · El tamaño físico de la tarjeta es aproximado")
        } catch { self.error = error.localizedDescription }
    }
}

struct IDCardPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @State private var front: NSImage?
    @State private var back: NSImage?
    @State private var title = "Identificación"
    @State private var problem: String?
    private func choose(frontSide: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { problem = tr("No se pudo abrir la imagen seleccionada."); return }
        if frontSide { front = image } else { back = image }; problem = nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(tr("Tarjeta de identificación")).font(.title2.bold()); Spacer(); Button(tr("Cerrar")) { dismiss() } }
            Text(tr("Coloca el anverso y el reverso en una hoja A4. Las imágenes conservan su proporción.")).foregroundStyle(.secondary)
            TextField(tr("Título"), text: $title)
            HStack(spacing: 20) {
                VStack { if let front { Image(nsImage: front).resizable().scaledToFit().frame(width: 230, height: 160) } else { Image(systemName: "person.text.rectangle").font(.system(size: 55)).frame(width: 230, height: 160) }; Button(tr("Importar anverso…")) { choose(frontSide: true) } }
                VStack { if let back { Image(nsImage: back).resizable().scaledToFit().frame(width: 230, height: 160) } else { Image(systemName: "rectangle").font(.system(size: 55)).frame(width: 230, height: 160) }; Button(tr("Importar reverso…")) { choose(frontSide: false) }; if back != nil { Button(tr("Quitar reverso")) { back = nil } } }
            }
            if let problem { Text(trStatus(problem)).foregroundStyle(.red) }
            Button(tr("Crear PDF en biblioteca")) { if let front { lib.captureIDCard(front: front, back: back, title: title); if lib.error == nil { dismiss() } } }.buttonStyle(.borderedProminent).disabled(front == nil || lib.busy)
        }.padding(24).frame(width: 560)
    }
}
