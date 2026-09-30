@preconcurrency import AVFoundation
import MacSensors
import SwiftUI
import FixStatCore

@available(macOS 14.0, *)
struct CameraTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var camera = CameraPreview()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch camera.permission {
            case .denied:
                Label("FixStat has no camera access. Allow it in System Settings › Privacy & Security › Camera.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(TemperatureColor.hot)
                Button("Open System Settings") { MediaPermission.openSettings("Privacy_Camera") }
            case .noCamera:
                Label("No camera found.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(TemperatureColor.hot)
            default:
                if let name = camera.deviceName {
                    Text(verbatim: [name, camera.resolution].compactMap { $0 }.joined(separator: " · "))
                        .font(.headline)
                }
                PreviewLayerView(session: camera.session)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: 560)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let brightness = camera.brightness {
                    Text("\(Format.number(Double(camera.frames))) frames · average brightness \(Format.percent(brightness * 100))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if camera.looksBlack {
                        Label("The image is black. Check that nothing covers the camera; otherwise suspect the camera or its cable.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(TemperatureColor.hot)
                    }
                }
            }
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.frames / 30) { _, _ in
            guard let detail = camera.detail else { return }
            monitor.recordCheck(.camera, detail: detail)
        }
    }
}

/// SwiftUI view of the core `CameraCapture`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class CameraPreview {
    typealias Permission = CameraCapture.Permission

    private(set) var permission = Permission.unknown
    private(set) var deviceName: String?
    private(set) var resolution: String?
    private(set) var frames = 0
    private(set) var brightness: Double?

    @ObservationIgnored private let camera = CameraCapture()
    var session: AVCaptureSession { camera.session }
    var detail: String? { camera.detail }
    var looksBlack: Bool { camera.looksBlack }

    init() {
        camera.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func start() async {
        await withCheckedContinuation { continuation in
            camera.start { continuation.resume() }
        }
        sync()
    }

    func stop() { camera.stop() }

    private func sync() {
        if camera.permission != permission { permission = camera.permission }
        if camera.deviceName != deviceName { deviceName = camera.deviceName }
        if camera.resolution != resolution { resolution = camera.resolution }
        frames = camera.frames
        if camera.brightness != brightness { brightness = camera.brightness }
    }
}

@available(macOS 14.0, *)
private struct PreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
