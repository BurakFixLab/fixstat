@preconcurrency import AVFoundation
import MacSensors
import SwiftUI

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
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
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
                    if camera.frames > 30 && brightness < 0.03 {
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
            guard let name = camera.deviceName, let brightness = camera.brightness else { return }
            monitor.recordCheck(.camera, detail: [name, camera.resolution,
                                                  String(localized: "average brightness \(Format.percent(brightness * 100))")]
                .compactMap { $0 }.joined(separator: " · "))
        }
    }
}

@MainActor
@Observable
final class CameraPreview {
    enum Permission { case unknown, granted, denied, noCamera }

    private(set) var permission = Permission.unknown
    private(set) var deviceName: String?
    private(set) var resolution: String?
    private(set) var frames = 0
    /// Average luma 0…1 of a recent frame.
    private(set) var brightness: Double?

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let sampler = FrameSampler()
    @ObservationIgnored private let queue = DispatchQueue(label: "FixStat.camera")

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permission = .granted
        case .notDetermined:
            permission = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: permission = .denied
        }
        guard permission == .granted else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            permission = .noCamera
            return
        }
        deviceName = device.localizedName
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        resolution = "\(dimensions.width) × \(dimensions.height)"
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        sampler.onFrame = { [weak self] count, luma in
            Task { @MainActor in
                self?.frames = count
                if let luma { self?.brightness = luma }
            }
        }
        output.setSampleBufferDelegate(sampler, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let session = session
        queue.async { session.startRunning() }
    }

    func stop() {
        let session = session
        queue.async { session.stopRunning() }
    }
}

/// Counts frames and measures the average luma of every 15th frame (Y plane, sparse).
private final class FrameSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: ((Int, Double?) -> Void)?
    private var count = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        count += 1
        guard count % 15 == 1, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if count % 15 == 0 { onFrame?(count, nil) }
            return
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var samples = 0
        for y in Swift.stride(from: 0, to: height, by: 16) {
            for x in Swift.stride(from: 0, to: width, by: 16) {
                total += Int(bytes[y * stride + x])
                samples += 1
            }
        }
        onFrame?(count, samples > 0 ? Double(total) / Double(samples) / 255 : nil)
    }
}

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
