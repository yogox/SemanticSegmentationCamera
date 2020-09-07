//
//  ContentView.swift
//  SemanticSegmentationCamera
//
//  Created by yogox on 2020/08/05.
//  Copyright © 2020 Yogox Galaxy. All rights reserved.
//

import SwiftUI
import AVFoundation

extension AVCaptureDevice.Position: CaseIterable {
    public static var allCases: [AVCaptureDevice.Position] {
        return [.front, .back]
    }
    
    mutating func toggle() {
        self = self == .front ? .back : .front
    }
}
typealias CameraPosition = AVCaptureDevice.Position

class SemanticSegmentationCamera: NSObject, AVCapturePhotoCaptureDelegate, ObservableObject {
    @Published var previewLayer:[CameraPosition:AVCaptureVideoPreviewLayer] = [:]
    private var captureDevice:AVCaptureDevice!
    private var captureSession:[CameraPosition:AVCaptureSession] = [:]
    private var dataOutput:[CameraPosition:AVCapturePhotoOutput] = [:]
    private var currentCameraPosition:CameraPosition
    
    override init() {
        currentCameraPosition = .back
        super.init()
        for cameraPosition in CameraPosition.allCases {
            previewLayer[cameraPosition] = AVCaptureVideoPreviewLayer()
            captureSession[cameraPosition] = AVCaptureSession()
            setupSession(cameraPosition: cameraPosition)
        }
        captureSession[currentCameraPosition]?.startRunning()
    }
    
    private func setupDevice(cameraPosition: CameraPosition = .back) {
        if let availableDevice = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: AVMediaType.video, position: cameraPosition).devices.first {
            captureDevice = availableDevice
        }
    }
    
    private func setupSession(cameraPosition: CameraPosition = .back) {
        setupDevice(cameraPosition: cameraPosition)
        
        let captureSession = self.captureSession[cameraPosition]!
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo
        
        do {
            let captureDeviceInput = try AVCaptureDeviceInput(device: captureDevice)
            captureSession.addInput(captureDeviceInput)
        } catch {
            print(error.localizedDescription)
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        self.previewLayer[cameraPosition] = previewLayer
        
        dataOutput[cameraPosition] = AVCapturePhotoOutput()
        guard let photoOutput = dataOutput[cameraPosition] else { return }
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }
        
        captureSession.commitConfiguration()
    }
    
    func switchCamera() {
        captureSession[currentCameraPosition]?.stopRunning()
        currentCameraPosition.toggle()
        captureSession[currentCameraPosition]?.startRunning()
    }
    
    func takePhoto() {
        let settings = AVCapturePhotoSettings()
        dataOutput[currentCameraPosition]?.capturePhoto(with: settings, delegate: self)
    }
    
    // MARK: - AVCapturePhotoCaptureDelegate
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // TODO: 写真撮影時処理
    }
}

struct CALayerView: UIViewControllerRepresentable {
    var caLayer:AVCaptureVideoPreviewLayer
    
    func makeUIViewController(context: UIViewControllerRepresentableContext<CALayerView>) -> UIViewController {
        let viewController = UIViewController()
        
        caLayer.frame = viewController.view.layer.frame
        caLayer.videoGravity = .resizeAspectFill
        viewController.view.layer.addSublayer(caLayer)
        
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<CALayerView>) {
    }
}

struct ContentView: View {
    @ObservedObject var simpleCamera = SemanticSegmentationCamera()
    @State private var flipped = false
    @State private var angle:Double = 0
    
    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()
                
                VStack {
                    Spacer()
                    
                    ZStack() {
                        CALayerView(caLayer: self.simpleCamera.previewLayer[.front]!).opacity(self.flipped ? 1.0 : 0.0)
                        CALayerView(caLayer: self.simpleCamera.previewLayer[.back]!).opacity(self.flipped ? 0.0 : 1.0)
                        
                    }
                    .modifier(FlipEffect(flipped: self.$flipped, angle: self.angle, axis: (x: 0, y: 1)))
                    Spacer()
                }
                Spacer()
                
                HStack {
                    Spacer()
                    Spacer()
                    
                    Button(action: {
                        self.simpleCamera.takePhoto()
                    }) {
                        Image(systemName: "camera.circle.fill")
                            .renderingMode(.original)
                            .resizable()
                            .frame(width: 60, height: 60, alignment: .center)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        self.simpleCamera.switchCamera()
                        withAnimation(nil) {
                            if self.angle >= 360 {
                                self.angle = self.angle.truncatingRemainder(dividingBy: 360)
                            }
                        }
                        withAnimation(Animation.easeIn(duration: 1.0)) {
                            self.angle += 180
                        }
                    }) {
                        Image(systemName: "camera.rotate.fill")
                            .renderingMode(.original)
                            .resizable()
                            .frame(width: 40, height: 40, alignment: .center)
                    }
                }
                .padding(20)
                
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.gray)
            
        }
    }
}

struct FlipEffect: GeometryEffect {
    
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    
    @Binding var flipped: Bool
    var angle: Double
    let axis: (x: CGFloat, y: CGFloat)
    
    func effectValue(size: CGSize) -> ProjectionTransform {
        
        DispatchQueue.main.async {
            self.flipped = self.angle >= 90 && self.angle < 270
        }
        
        let tweakedAngle = flipped ? -180 + angle : angle
        let a = CGFloat(Angle(degrees: tweakedAngle).radians)
        
        var transform3d = CATransform3DIdentity;
        transform3d.m34 = -1/max(size.width, size.height)
        
        transform3d = CATransform3DRotate(transform3d, a, axis.x, axis.y, 0)
        transform3d = CATransform3DTranslate(transform3d, -size.width/2.0, -size.height/2.0, 0)
        
        let affineTransform = ProjectionTransform(CGAffineTransform(translationX: size.width/2.0, y: size.height / 2.0))
        
        return ProjectionTransform(transform3d).concatenating(affineTransform)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
