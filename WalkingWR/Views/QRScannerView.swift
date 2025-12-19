//
//  QRScannerView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import AVFoundation

#if os(iOS)
import UIKit
#endif

struct QRScannerView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var isScanning = true
    @State private var scannedMarker: QRMarker?
    @State private var showMarkerContent = false
    @State private var torchOn = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                #if os(iOS)
                // Camera view
                QRScannerRepresentable(
                    isScanning: $isScanning,
                    torchOn: $torchOn
                ) { code in
                    handleScan(code)
                }
                .ignoresSafeArea()
                #else
                // macOS placeholder
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 20) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 80))
                                .foregroundColor(.primary)
                            Text("QR Scanner requires iOS")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Run on an iOS device to scan QR codes")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            
                            // Demo button for testing
                            Button("Simulate QR Scan") {
                                handleScan("demo-marker-001")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.tealAccent)
                            .padding(.top, 20)
                        }
                    }
                #endif
                
                // Overlay
                VStack {
                    Spacer()
                    
                    #if os(iOS)
                    // Scanning frame
                    ZStack {
                        // Corner brackets
                        ScannerFrame()
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 250, height: 250)
                        
                        // Scanning line animation
                        if isScanning {
                            ScanningLine()
                                .frame(width: 230, height: 250)
                        }
                    }
                    
                    Spacer()
                    #endif
                    
                    // Instructions
                    VStack(spacing: 16) {
                        Text("Point at a QR marker")
                            .font(.appTitleMedium)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("Scan markers along your route to unlock wellbeing content and earn points")
                            .font(.appBodyMedium)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .padding(.bottom, 30)
                    
                    #if os(iOS)
                    // Torch button
                    Button(action: { torchOn.toggle() }) {
                        HStack {
                            Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            Text(torchOn ? "Light On" : "Light Off")
                        }
                        .font(.appBodyMedium)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                    .padding(.bottom, 40)
                    #endif
                }
            }
            .navigationTitle("Scan Marker")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.primary)
                }
            }
            .sheet(isPresented: $showMarkerContent) {
                if let marker = scannedMarker {
                    MarkerContentSheet(marker: marker, viewModel: viewModel) {
                        showMarkerContent = false
                        isScanning = true
                    }
                    .delayAlerts(viewModel: viewModel)
                }
            }
        }
    }
    
    func handleScan(_ code: String) {
        isScanning = false
        
        #if os(iOS)
        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        #endif
        
        // Process the QR code
        if let marker = viewModel.processQRCode(code) {
            scannedMarker = marker
            showMarkerContent = true
        } else {
            // Invalid code, resume scanning
            isScanning = true
        }
    }
}

// MARK: - Scanner Frame
struct ScannerFrame: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cornerLength: CGFloat = 30
        
        // Top left
        path.move(to: CGPoint(x: 0, y: cornerLength))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: cornerLength, y: 0))
        
        // Top right
        path.move(to: CGPoint(x: rect.width - cornerLength, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: cornerLength))
        
        // Bottom right
        path.move(to: CGPoint(x: rect.width, y: rect.height - cornerLength))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - cornerLength, y: rect.height))
        
        // Bottom left
        path.move(to: CGPoint(x: cornerLength, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height - cornerLength))
        
        return path
    }
}

// MARK: - Scanning Line Animation
struct ScanningLine: View {
    @State private var offset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .tealAccent.opacity(0.8), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2)
                .offset(y: offset)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                        offset = geometry.size.height
                    }
                }
        }
    }
}

// MARK: - Marker Content Sheet
struct MarkerContentSheet: View {
    let marker: QRMarker
    @ObservedObject var viewModel: WaitingRoomViewModel
    let onDismiss: () -> Void
    
    @State private var showContent = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Success animation
                    ZStack {
                        Circle()
                            .fill(Color.mintGreen.opacity(0.15))
                            .frame(width: 120, height: 120)
                            .scaleEffect(showContent ? 1 : 0.5)
                        
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.mintGreen)
                            .scaleEffect(showContent ? 1 : 0)
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showContent)
                    
                    // Points earned
                    VStack(spacing: 8) {
                        Text("+\(marker.pointsValue) points!")
                            .font(.appTitleLarge)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text(marker.location)
                            .font(.appBodyMedium)
                            .foregroundColor(.primary)
                    }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)
                    .animation(.easeOut(duration: 0.4).delay(0.2), value: showContent)
                    
                    // Content type badge
                    Text(marker.contentType.rawValue.uppercased())
                        .font(.appMicro)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(contentColor)
                        .clipShape(Capsule())
                        .opacity(showContent ? 1 : 0)
                        .animation(.easeOut(duration: 0.4).delay(0.3), value: showContent)
                    
                    // Content card
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: marker.content.icon)
                                .font(.title2)
                                .foregroundColor(contentColor)
                            
                            Text(marker.content.title)
                                .font(.appTitleMedium)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                        }
                        
                        Text(marker.content.description)
                            .font(.appBodyMedium)
                            .foregroundColor(.primary)
                        
                        if let steps = marker.content.steps {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text("\(index + 1)")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .foregroundColor(.primary)
                                            .frame(width: 24, height: 24)
                                            .background(contentColor)
                                            .clipShape(Circle())
                                        
                                        Text(step)
                                            .font(.appBodyMedium)
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(20)
                    .cardStyle()
                    .padding(.horizontal, 20)
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 30)
                    .animation(.easeOut(duration: 0.5).delay(0.4), value: showContent)
                    
                    Spacer(minLength: 40)
                }
                .padding(.top, 30)
            }
            .navigationTitle("Marker Found!")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        onDismiss()
                    }
                }
            }
            .onAppear {
                showContent = true
            }
        }
    }
    
    var contentColor: Color {
        switch marker.contentType {
        case .breathingExercise: return .lavenderMist
        case .gratitudePrompt: return .coralPink
        case .natureFact: return .mintGreen
        case .digitalTip: return .tealAccent
        case .miniChallenge: return .softAmber
        }
    }
}

// MARK: - iOS-only QR Scanner Implementation
#if os(iOS)
struct QRScannerRepresentable: UIViewControllerRepresentable {
    @Binding var isScanning: Bool
    @Binding var torchOn: Bool
    let onScan: (String) -> Void
    
    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.isScanning = isScanning
        uiViewController.setTorch(on: torchOn)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }
    
    class Coordinator: NSObject, QRScannerDelegate {
        let onScan: (String) -> Void
        
        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }
        
        func didScanCode(_ code: String) {
            onScan(code)
        }
    }
}

// MARK: - QR Scanner View Controller
protocol QRScannerDelegate: AnyObject {
    func didScanCode(_ code: String)
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    var isScanning = true
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            showPermissionDenied()
            return
        }
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }
            
            let metadataOutput = AVCaptureMetadataOutput()
            
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                metadataOutput.metadataObjectTypes = [.qr]
            }
            
            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.frame = view.bounds
            previewLayer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(previewLayer)
            
            self.previewLayer = previewLayer
            self.captureSession = session
            
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        } catch {
            showPermissionDenied()
        }
    }
    
    private func showPermissionDenied() {
        DispatchQueue.main.async {
            let label = UILabel()
            label.text = "Camera access required to scan QR codes"
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            
            self.view.backgroundColor = .black
            self.view.addSubview(label)
            
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: self.view.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 40),
                label.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -40)
            ])
        }
    }
    
    func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            // Handle error silently
        }
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard isScanning,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = metadataObject.stringValue else { return }
        
        isScanning = false
        delegate?.didScanCode(code)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }
}
#endif

#Preview {
    QRScannerView(viewModel: WaitingRoomViewModel())
}
