import AVFoundation
import SwiftUI
import UIKit

/// LiDAR-capable plate camera: captures a photo together with a depth map, runs a
/// rough portion-volume estimate, and hands both back. Used only when a LiDAR
/// device is present; the meal flow falls back to `CameraCaptureView` otherwise.
/// Capturing/estimating is advisory — nothing here doses.
struct DepthCameraCaptureView: UIViewControllerRepresentable {
    let onCaptured: (UIImage, PortionEstimate?) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool { PortionVolumeEstimator.isAvailable }

    func makeUIViewController(context _: Context) -> DepthCameraViewController {
        let controller = DepthCameraViewController()
        controller.onCaptured = onCaptured
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_: DepthCameraViewController, context _: Context) {}
}

final class DepthCameraViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCaptured: ((UIImage, PortionEstimate?) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "DepthCameraCaptureView.session")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        addControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return
        }
        session.addOutput(photoOutput)
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported

        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    private func addControls() {
        let captureButton = UIButton(type: .system)
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.setImage(UIImage(systemName: "camera.circle.fill"), for: .normal)
        captureButton.tintColor = .white
        captureButton.contentVerticalAlignment = .fill
        captureButton.contentHorizontalAlignment = .fill
        captureButton.addTarget(self, action: #selector(capture), for: .touchUpInside)
        view.addSubview(captureButton)

        let cancelButton = UIButton(type: .system)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle(String(localized: "Cancel"), for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            captureButton.widthAnchor.constraint(equalToConstant: 72),
            captureButton.heightAnchor.constraint(equalToConstant: 72),
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -44)
        ])
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func capture() {
        let settings = AVCapturePhotoSettings()
        settings.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(
        _: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return
        }
        let estimate = photo.depthData.flatMap { PortionVolumeEstimator.estimate(from: $0) }
        DispatchQueue.main.async { [weak self] in
            self?.onCaptured?(image, estimate)
        }
    }
}
