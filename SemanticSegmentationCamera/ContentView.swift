//
//  ContentView.swift
//  SemanticSegmentationCamera
//
//  Created by yogox on 2020/09/12.
//  Copyright © 2020 Yogox Galaxy. All rights reserved.
//

import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins


class CIBlendWithMatte : CIFilter {
    var inputImage: CIImage?
    var backgroundImage: CIImage?
    var color: CIVector?
    
    override var outputImage: CIImage? {
        guard let inputImage = inputImage
            , let backgroundImage = backgroundImage
            , let color = color else { return nil}
        
        // 写真に合わせてMatte画像のスケールを拡大
        let scaleFilter = CIFilter.lanczosScaleTransform()
        let matteHeight = inputImage.extent.height
        let photoHeight = backgroundImage.extent.height
        scaleFilter.inputImage = inputImage
        scaleFilter.scale = Float(photoHeight / matteHeight)
        scaleFilter.aspectRatio = 1.0
        
        // マット画像の色・アルファを変更
        let colorFilter = CIFilter.colorClamp()
        colorFilter.inputImage = scaleFilter.outputImage!
        colorFilter.maxComponents = color
        
        // Matte画像自身をマスクにして写真と合成
        let blendFilter = CIFilter.blendWithMask()
        blendFilter.inputImage = colorFilter.outputImage!
        blendFilter.backgroundImage = backgroundImage
        blendFilter.maskImage = scaleFilter.outputImage!
        
        return blendFilter.outputImage!
    }
}

class CIBlendWIthSemanticSegmentationMatte : CIFilter {
    var inputImage: CIImage?
    var skinMatteImage: CIImage?
    var hairMatteImage: CIImage?
    var teethMatteImage: CIImage?
    var alpha: CGFloat?
    
    override var outputImage: CIImage? {
        guard let inputImage = inputImage
            , let skinMatteImage = skinMatteImage
            , let hairMatteImage = hairMatteImage
            , let teethMatteImage = teethMatteImage
            , let alpha = alpha else { return nil }
        guard (0.0 ... 1.0).contains(alpha) else {return nil}
        
        // 肌のmatteを赤で合成
        let skinFilter = CIBlendWithMatte()
        skinFilter.inputImage = skinMatteImage
        skinFilter.backgroundImage = inputImage
        skinFilter.color = CIVector(x: 1, y: 0, z: 0, w: alpha)
        
        // 髮のmatteを緑で合成
        let hairFilter = CIBlendWithMatte()
        hairFilter.inputImage = hairMatteImage
        hairFilter.backgroundImage = skinFilter.outputImage!
        hairFilter.color = CIVector(x: 0, y: 1, z: 0, w: alpha)
        
        // 歯のmatteを青で合成
        let teethFilter = CIBlendWithMatte()
        teethFilter.inputImage = teethMatteImage
        teethFilter.backgroundImage = hairFilter.outputImage!
        teethFilter.color = CIVector(x: 0, y: 0, z: 1, w: alpha)
        
        return teethFilter.outputImage!
    }
}

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
    @Published var image: UIImage?
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
            
            photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
            
            // SemanticSegmentationMatteの設定
            photoOutput.enabledSemanticSegmentationMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes
            
        }
        
        captureSession.commitConfiguration()
    }
    
    func switchCamera() {
        captureSession[currentCameraPosition]?.stopRunning()
        currentCameraPosition.toggle()
        captureSession[currentCameraPosition]?.startRunning()
    }
    
    func takePhoto() {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.isDepthDataDeliveryEnabled = true
        
        // SemanticSegmentationMatteの設定
        settings.enabledSemanticSegmentationMatteTypes = dataOutput[currentCameraPosition]?.availableSemanticSegmentationMatteTypes ?? [AVSemanticSegmentationMatte.MatteType]()
        
        dataOutput[currentCameraPosition]?.capturePhoto(with: settings, delegate: self)
    }
    
    // MARK: - AVCapturePhotoCaptureDelegate
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // 元写真を取得
        guard let imageData = photo.fileDataRepresentation(), let ciImage = CIImage(data: imageData) else {return}
        var photoImage = ciImage
        
        // skin, hair, teethのsemanticSegmentationMatteを取得
        if let skinMatte = photo.semanticSegmentationMatte(for: .skin)
            , let hairMatte = photo.semanticSegmentationMatte(for: .hair)
            , let teethMatte = photo.semanticSegmentationMatte(for: .teeth)
        {
            // CIImageを作成s
            let skinImage = CIImage(semanticSegmentationMatte: skinMatte, options: [.auxiliarySemanticSegmentationSkinMatte : true])
            let hairImage = CIImage(semanticSegmentationMatte: hairMatte, options: [.auxiliarySemanticSegmentationHairMatte : true])
            let teethImage = CIImage(semanticSegmentationMatte: teethMatte, options: [.auxiliarySemanticSegmentationTeethMatte : true])
            
            // 自作カスタムフィルターでmatteを着色して写真と合成
            let matteFilter = CIBlendWIthSemanticSegmentationMatte()
            matteFilter.inputImage = photoImage
            matteFilter.skinMatteImage = skinImage
            matteFilter.hairMatteImage = hairImage
            matteFilter.teethMatteImage = teethImage
            matteFilter.alpha = 0.7
            photoImage = matteFilter.outputImage!
        }
        
        // 画像の向きを決め打ち修正
        photoImage = photoImage.oriented(.right)
        // Imageクラスでも描画されるようにCGImage経由でUIImageに変換
        let context = CIContext(options: nil)
        let cgImage = context.createCGImage(photoImage, from: photoImage.extent)
        self.image = UIImage(cgImage: cgImage!)
    }
}

struct CALayerView: UIViewControllerRepresentable {
    var caLayer:AVCaptureVideoPreviewLayer
    
    func makeUIViewController(context: UIViewControllerRepresentableContext<CALayerView>) -> UIViewController {
        let viewController = UIViewController()
        
        let width = viewController.view.frame.width
        let height = viewController.view.frame.height
        let previewHeight = width * 4 / 3
        
        caLayer.videoGravity = .resizeAspect
        viewController.view.layer.addSublayer(caLayer)
        caLayer.frame = viewController.view.frame
        caLayer.position = CGPoint(x: width/2, y: previewHeight/2 + (height - previewHeight - 75)/3 )
        
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<CALayerView>) {
    }
}

enum Views {
    case transferPhoto
}

struct ContentView: View {
    @ObservedObject var segmentationCamera = SemanticSegmentationCamera()
    @State private var flipped = false
    @State private var angle:Double = 0
    @State private var selection:Views? = .none
    @State private var start = false
    
    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                ZStack {
                    ZStack() {
                        CALayerView(caLayer: self.segmentationCamera.previewLayer[.front]!).opacity(self.flipped ? 1.0 : 0.0)
                        CALayerView(caLayer: self.segmentationCamera.previewLayer[.back]!).opacity(self.flipped ? 0.0 : 1.0)
                    }
                    .modifier(FlipEffect(flipped: self.$flipped, angle: self.angle, axis: (x: 0, y: 1)))
                    
                    VStack {
                        
                        Spacer()
                        
                        Color.clear
                            .frame(width: geometry.size.width, height: geometry.size.width / 3 * 4)
                        
                        Spacer()
                        
                        HStack {
                            Spacer()
                            
                            Color.clear
                                .frame(width: 40, height: 40)
                            
                            Spacer()
                            
                            Button(action: {
                                self.segmentationCamera.takePhoto()
                                self.selection = .transferPhoto
                            }) {
                                Image(systemName: "camera.circle.fill")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 75, height: 75, alignment: .center)
                                    .foregroundColor(Color.white)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                self.segmentationCamera.switchCamera()
                                withAnimation(nil) {
                                    if self.angle >= 360 {
                                        self.angle = self.angle.truncatingRemainder(dividingBy: 360)
                                    }
                                }
                                withAnimation(Animation.easeIn(duration: 0.5)) {
                                    self.angle += 180
                                }
                            }) {
                                Image(systemName: "camera.rotate")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 40, height: 40, alignment: .center)
                                    .foregroundColor(Color.white)
                            }
                            
                            Spacer()
                        }
                        NavigationLink(destination: TransferPhotoView(segmentationCamera: self.segmentationCamera, selection: self.$selection
                            ),
                                       tag:Views.transferPhoto,
                                       selection:self.$selection) {
                                        EmptyView()
                        }
                        
                        Spacer()
                        
                    }
                    .navigationBarTitle(/*@START_MENU_TOKEN@*/"Navigation Bar"/*@END_MENU_TOKEN@*/)
                    .navigationBarHidden(/*@START_MENU_TOKEN@*/true/*@END_MENU_TOKEN@*/)
                    
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color.black)
                
            }
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

struct photoView: View {
    @ObservedObject var segmentationCamera: SemanticSegmentationCamera
    
    var body: some View {
        VStack {
            if self.segmentationCamera.image != nil {
                Image(uiImage: self.segmentationCamera.image!)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.black)
            }
        }
    }
}

struct TransferPhotoView: View {
    @ObservedObject var segmentationCamera: SemanticSegmentationCamera
    @Binding var selection:Views?
    
    var body: some View {
        VStack {
            Spacer()
            
            GeometryReader { geometry in
                photoView(segmentationCamera: self.segmentationCamera)
                    .frame(alignment: .center)
                    .border(Color.white, width:1)
                    .background(Color.black)
            }
            
            Spacer()
            
            HStack {
                Button(action: {
                    self.segmentationCamera.image = nil
                    self.selection = .none
                }) {
                    Text("Back")
                }
                
                Spacer()
            }
            .padding(20)
        }
        .background(/*@START_MENU_TOKEN@*/Color.black/*@END_MENU_TOKEN@*/)
        .navigationBarTitle("Image")
        .navigationBarHidden(/*@START_MENU_TOKEN@*/true/*@END_MENU_TOKEN@*/)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
