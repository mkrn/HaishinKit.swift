import AVFoundation
import Combine
import HaishinKit
import Logboard
import PhotosUI
import SwiftUI
import VideoToolbox

final class ViewModel: ObservableObject {
    let maxRetryCount: Int = 10000

    private var rtmpConnection = RTMPConnection()
    @Published var rtmpStream: RTMPStream!
    private var sharedObject: RTMPSharedObject!
    private var currentEffect: VideoEffect?
    @Published var currentPosition: AVCaptureDevice.Position = .back
    private var retryCount: Int = 0
    @Published var published = false
    @Published var zoomLevel: CGFloat = 1.0
    @Published var videoRate = CGFloat(3200); //CGFloat(VideoCodecSettings.default.bitRate / 1000)
    @Published var audioRate = CGFloat(AudioCodecSettings.default.bitRate / 1000)
    @Published var fps: String = "FPS"
    private var nc = NotificationCenter.default
    
    var zeroCounter = 0;

    var subscriptions = Set<AnyCancellable>()

    var frameRate: String = "30.0" {
        willSet {
            rtmpStream.frameRate = Float64(newValue) ?? 30.0
            objectWillChange.send()
        }
    }

    var videoEffect: String = "None" {
        willSet {
            if let currentEffect: VideoEffect = currentEffect {
                _ = rtmpStream.unregisterVideoEffect(currentEffect)
            }

            switch newValue {
            case "Monochrome":
                currentEffect = MonochromeEffect()
                _ = rtmpStream.registerVideoEffect(currentEffect!)

            case "Pronoma":
                print("case Pronoma")
                currentEffect = PronamaEffect()
                _ = rtmpStream.registerVideoEffect(currentEffect!)

            default:
                break
            }

            objectWillChange.send()
        }
    }

    var videoEffectData = ["None", "Monochrome", "Pronoma"]

    var frameRateData = ["15.0", "30.0", "60.0"]

    func config() {
        rtmpStream = RTMPStream(connection: rtmpConnection)
        if let orientation = DeviceUtil.videoOrientation(by: UIDevice.current.orientation) {
            rtmpStream.videoOrientation = orientation
        }
        rtmpStream.sessionPreset = .hd1280x720
        rtmpStream.videoSettings.videoSize = .init(width: 720, height: 1280)
        
        if #available(iOS 16.0, *) {
          rtmpStream.videoSettings.bitRateMode = .constant
        } else {
            rtmpStream.videoSettings.bitRateMode = .average
        }
        
        rtmpStream.mixer.recorder.delegate = self
        rtmpStream.delegate = self
        rtmpConnection.delegate = self

        nc.publisher(for: UIDevice.orientationDidChangeNotification, object: nil)
            .sink { [weak self] _ in
                guard let orientation = DeviceUtil.videoOrientation(by: UIDevice.current.orientation), let self = self else {
                    return
                }
                self.rtmpStream.videoOrientation = orientation
            }
            .store(in: &subscriptions)

        checkDeviceAuthorization()
    }

    func checkDeviceAuthorization() {
        let requiredAccessLevel: PHAccessLevel = .readWrite
        PHPhotoLibrary.requestAuthorization(for: requiredAccessLevel) { authorizationStatus in
            switch authorizationStatus {
            case .limited:
                logger.info("limited authorization granted")
            case .authorized:
                logger.info("authorization granted")
            default:
                logger.info("Unimplemented")
            }
        }
    }

    func registerForPublishEvent() {
        rtmpStream.attachAudio(AVCaptureDevice.default(for: .audio)) { error in
            logger.error(error)
        }
        rtmpStream.attachCamera(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition)) { error in
            logger.error(error)
        }
//        rtmpStream.publisher(for: \.currentFPS)
//            .sink { [weak self] currentFPS in
//                guard let self = self else {
//                    return
//                }
//            }
//            .store(in: &subscriptions)

        nc.publisher(for: AVAudioSession.interruptionNotification, object: nil)
            .sink { notification in
                logger.info(notification)
            }
            .store(in: &subscriptions)

        nc.publisher(for: AVAudioSession.routeChangeNotification, object: nil)
            .sink { notification in
                logger.info(notification)
            }
            .store(in: &subscriptions)
    }

    func unregisterForPublishEvent() {
        rtmpStream.close()
    }

    func startPublish() {
        UIApplication.shared.isIdleTimerDisabled = true
        logger.info(Preference.defaultInstance.uri!)

        rtmpConnection.addEventListener(.rtmpStatus, selector: #selector(rtmpStatusHandler), observer: self)
        rtmpConnection.addEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
        rtmpConnection.connect(Preference.defaultInstance.uri!)
    }

    func stopPublish() {
        UIApplication.shared.isIdleTimerDisabled = false
        rtmpConnection.close()
        rtmpConnection.removeEventListener(.rtmpStatus, selector: #selector(rtmpStatusHandler), observer: self)
        rtmpConnection.removeEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
    }

    func toggleTorch() {
        rtmpStream.torch.toggle()
    }

    func pausePublish() {
        rtmpStream.paused.toggle()
    }

    func tapScreen(touchPoint: CGPoint) {
        let pointOfInterest = CGPoint(x: touchPoint.x / UIScreen.main.bounds.size.width, y: touchPoint.y / UIScreen.main.bounds.size.height)
        logger.info("pointOfInterest: \(pointOfInterest)")
        guard
            let device = rtmpStream.videoCapture(for: 0)?.device, device.isFocusPointOfInterestSupported else {
            return
        }
        do {
            try device.lockForConfiguration()
            device.focusPointOfInterest = pointOfInterest
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        } catch let error as NSError {
            logger.error("while locking device for focusPointOfInterest: \(error)")
        }
    }

    func rotateCamera() {
        let position: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        rtmpStream.attachCamera(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)) { error in
            logger.error(error)
        }
        currentPosition = position
    }

    func changeZoomLevel(level: CGFloat) {
        guard let device = rtmpStream.videoCapture(for: 0)?.device, 1 <= level && level < device.activeFormat.videoMaxZoomFactor else {
            return
        }
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: level, withRate: 5.0)
            device.unlockForConfiguration()
        } catch let error as NSError {
            logger.error("while locking device for ramp: \(error)")
        }
    }

    func changeVideoRate(level: CGFloat) {
        rtmpStream.videoSettings.bitRate = UInt32(level * 1000)
    }

    func changeAudioRate(level: CGFloat) {
        rtmpStream.audioSettings.bitRate = Int(level * 1000)
    }

    @objc
    private func rtmpStatusHandler(_ notification: Notification) {
        let e = Event.from(notification)
        guard let data: ASObject = e.data as? ASObject, let code: String = data["code"] as? String else {
            return
        }
        print(code)
        switch code {
        case RTMPConnection.Code.connectSuccess.rawValue:
            retryCount = 0
            rtmpStream.publish(Preference.defaultInstance.streamName!)
        // sharedObject!.connect(rtmpConnection)
        case RTMPConnection.Code.connectFailed.rawValue, RTMPConnection.Code.connectClosed.rawValue:
            guard retryCount <= maxRetryCount else {
                return
            }
            Thread.sleep(forTimeInterval: pow(2.0, Double(retryCount)))
            rtmpConnection.connect(Preference.defaultInstance.uri!)
            retryCount += 1
        default:
            break
        }
    }

    @objc
    private func rtmpErrorHandler(_ notification: Notification) {
        logger.error(notification)
        rtmpConnection.connect(Preference.defaultInstance.uri!)
    }
}

extension ViewModel: IORecorderDelegate {
    // MARK: IORecorderDelegate
    func recorder(_ recorder: IORecorder, errorOccured error: IORecorder.Error) {
        logger.error(error)
    }

    func recorder(_ recorder: IORecorder, finishWriting writer: AVAssetWriter) {
        PHPhotoLibrary.shared().performChanges({() -> Void in
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: writer.outputURL)
        }, completionHandler: { _, error -> Void in
            do {
                try FileManager.default.removeItem(at: writer.outputURL)
            } catch {
                print(error)
            }
        })
    }
}



extension ViewModel : RTMPConnectionDelegate {
    // MARK: RTMPStreamDelegate
    func connection(_ connection: HaishinKit.RTMPConnection, publishInsufficientBWOccured stream: HaishinKit.RTMPStream) {
        print("insufficientBW",  stream.videoSettings.bitRate,  stream.audioSettings.bitRate, connection.currentBytesOutPerSecond * 8)
        var videoBitRate = stream.videoSettings.bitRate
        
        if videoBitRate > 450 * 1024 {
            videoBitRate -= 450 * 1024
        } else {
            videoBitRate = 60 * 1024
        }
        stream.videoSettings.bitRate = videoBitRate
        print("bitrate now ", videoBitRate)
    }
    
    func connection(_ connection: HaishinKit.RTMPConnection, publishSufficientBWOccured stream: HaishinKit.RTMPStream) {
        print("sufficientBW",  stream.videoSettings.bitRate, stream.audioSettings.bitRate, connection.currentBytesOutPerSecond * 8)
        guard (connection.currentBytesOutPerSecond > 0 && connection.currentBytesOutPerSecond * 8 > stream.videoSettings.bitRate / 2) else {
            print("false flag")
            return
        }
        
        let targetBitrate = UInt32(3200 * 1024)
        if Double(stream.currentFPS) >= 24 { // Getting stable
            var videoBitRate = min(stream.videoSettings.bitRate + 150 * 1024, targetBitrate)
            stream.videoSettings.bitRate = videoBitRate
            print("bitrate now ", videoBitRate)
        }
    }
     
    
    func connection(_ connection: HaishinKit.RTMPConnection, updateStats stream: HaishinKit.RTMPStream) {
                let curFps = stream.currentFPS
        
                let currentBitsPerSecond = connection.currentBytesOutPerSecond * 8;
                let currentMbps = String(format: "%.1f", Double(currentBitsPerSecond) / 1000.0 / 1000.0);
                let fpsStr = "\(max(curFps, 30)) fps   \(currentMbps)Mb/s";
                DispatchQueue.main.async {
                    self.fps = fpsStr
                }
        
                if connection.currentBytesOutPerSecond == 0 {
                    print("drop all")
                    
//                        zeroCounter += 1
//                    if zeroCounter >= 5 {
//                        zeroCounter = 0
//                        print("STALE")
//                        self.rtmpStream.close()
//        
//                        self.rtmpConnection.connect(Preference.defaultInstance.uri!)
//                    }
                } else {
                    zeroCounter = 0
                }
            }
}

extension ViewModel : NetStreamDelegate {
    func stream(_ stream: NetStream, didOutput audio: AVAudioBuffer, presentationTimeStamp: CMTime) {
    }
    
    func stream(_ stream: NetStream, didOutput video: CMSampleBuffer) {
    }
    
    #if os(iOS)
    func stream(_ stream: NetStream, sessionWasInterrupted session: AVCaptureSession, reason: AVCaptureSession.InterruptionReason?) {
        print("sessionWasInterrupted \(stream) \(session) ")
         
    }
    
    func stream(_ stream: NetStream, sessionInterruptionEnded session: AVCaptureSession) {
        print("sessionInterruptionEnded \(stream) \(session)")
    }
    #endif
    
    func stream(_ stream: NetStream, videoCodecErrorOccurred error: VideoCodec.Error) {
        print("videoCodecErrorOccured \(error)")
    }
    
    func stream(_ stream: NetStream, audioCodecErrorOccurred error: HaishinKit.AudioCodec.Error) {
        print("audioCodecError \(error)")
        // Implementation for handling audio codec errors
    }
    
    func streamWillDropFrame(_ stream: NetStream) -> Bool {
        let bufferFullness = rtmpConnection.socket.queueBytesOut.value
        print("streamWillDropFrame", bufferFullness, rtmpConnection.socket.outputBufferSize)
        let shouldDrop = bufferFullness > Int64(0.6 * Double(rtmpConnection.socket.outputBufferSize));
        print(shouldDrop)
        // Decide to drop frame if buffer is more than 80% full
        return shouldDrop

//        return false
    }
    
    func streamDidOpen(_ stream: NetStream) {
        // Implementation for handling the stream being opened
    }
}
