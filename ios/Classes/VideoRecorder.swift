//
//  VideoRecorder.swift
//  flutter_webrtc
//
//  Created by MacBook 16 on 16.06.2022.
//

import Foundation
import WebRTC
import Flutter
import CoreVideo
import AVFoundation


public class VideoRecorder:NSObject, RTCVideoRenderer {
    private var videoTrack: RTCVideoTrack?
    
    private var videoWriter: AVAssetWriter?
    private var pixelBuffer: CVPixelBuffer?
    private var prevFramePixelBuffer: CVPixelBuffer?
    private var frameSize: CGSize?
    private var writerInput: AVAssetWriterInput?
    private var adapter: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false
    private var writerCreated = false
    
    private var firstFrameTime: CFTimeInterval?
    private let eventChannel: FlutterEventChannel
    private var eventSink :FlutterEventSink?
    private let motionDetection: MotionDetection
    
    
    
    
    @objc public init(binaryMessenger: FlutterBinaryMessenger, motionDetection: MotionDetection) {
        eventChannel = FlutterEventChannel(
            name: "FlutterWebRTC/detectionOnVideo",
            binaryMessenger: binaryMessenger)
        self.motionDetection = motionDetection
        super.init()
        eventChannel.setStreamHandler(self)
    }
    
    
    @objc public func startCapure(videoTrack: RTCVideoTrack,
                                  topPath path: String,
                                  enableAudio: Bool,
                                  result: FlutterResult) {
        guard !started else {
            result(false)
            return
        }
        // TODO: enable audio
        self.started = true
        self.videoTrack = videoTrack
        let url = URL.init(fileURLWithPath: path)
        do {
            videoWriter = try AVAssetWriter.init(outputURL: url, fileType: AVFileType.mp4)
        } catch {
            result(FlutterError(code: "failed to create writer", message: error.localizedDescription, details: nil))
            return
        }
        videoTrack.add(self)
        motionDetection.addListener(listener: self)
        result(true)
    }
    
    @objc public func stopCapure(result: FlutterResult) {
        guard started else {
            result(nil)
            return
        }
        
        videoTrack?.remove(self)
        motionDetection.removeLister()
        writerInput?.markAsFinished()
        writerCreated = false
        videoWriter?.finishWriting { [weak videoWriter] in
            guard let writer = videoWriter else { return }
            if writer.status == .failed {
                NSLog("Video writing failed: %@", writer.error?.localizedDescription ?? "")
            } else {
                NSLog("Video witing fished with: %@", writer.status.rawValue)
            }
        }
        let duration: Int
        if let firstFrameTime = firstFrameTime {
            duration = Int((CACurrentMediaTime() - firstFrameTime) * 1000)
        } else { duration = 0 }
        NSLog("Video duration: %d", duration)
        adapter = nil
        started = false
        videoTrack = nil
        videoWriter = nil
        adapter = nil
        firstFrameTime = nil
        result(NSNumber(value: duration))
        
        
    }
    
    public func setSize(_ size: CGSize) {
        if !writerCreated {
            createWriter(size: size)
        }
        if pixelBuffer == nil || self.frameSize != size {
            createBuffer(size: size)
        }
        self.frameSize = size
    }
    
    public func renderFrame(_ frame: RTCVideoFrame?) {
        guard started, let frame = frame,
              let pixelBuffer = self.pixelBuffer,
              let writer = writerInput,
              writer.isReadyForMoreMediaData else {
            NSLog("frame skipper")
            return
        }
        let frameTime = CACurrentMediaTime()
        let currentFrameNumer: Int64
        if let firstFrameTime = firstFrameTime {
            currentFrameNumer = Int64((frameTime - firstFrameTime) * 600)
        } else {
            firstFrameTime = frameTime
            currentFrameNumer = 0
        }
        let persentedTime = CMTimeMake(value: currentFrameNumer, timescale: 600)
        
        pixelBuffer.copy(from: frame)
        adapter?.append(pixelBuffer, withPresentationTime: persentedTime)
        
    }
    
    private func createWriter(size: CGSize) {
        
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecH264,
            AVVideoWidthKey: NSNumber.init(value: size.width),
            AVVideoHeightKey: NSNumber.init(value: size.height)
        ]
        let writerInput = AVAssetWriterInput.init(mediaType: AVMediaType.video, outputSettings: settings)
        self.writerInput = writerInput
        self.adapter = AVAssetWriterInputPixelBufferAdaptor.init(assetWriterInput: writerInput)
        guard let writer = self.videoWriter else {
            fatalError("video writer is nil")
        }
        assert(adapter != nil)
        assert(writer.canAdd(writerInput))
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: CMTime.zero)
        writerCreated = true
    }
    
    private func createBuffer(size: CGSize) {
        CVPixelBufferCreate(kCFAllocatorDefault,
                            Int(size.width),
                            Int( size.height),
                            kCVPixelFormatType_32BGRA,
                            nil,
                            &pixelBuffer)
    }
    
    private func createPrevBuffer(size: CGSize) {
        let pixelAttr:NSDictionary = [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()]
        CVPixelBufferCreate(kCFAllocatorDefault,
                            Int(size.width),
                            Int( size.height),
                            kCVPixelFormatType_32BGRA,
                            pixelAttr,
                            &prevFramePixelBuffer)
    }
}


extension VideoRecorder: MotionDetectionListener {
    func onDetected(result: DetectionResult) {
        guard let firstFrameTime = firstFrameTime else {
            return
        }
        let frameIndex = Int((CACurrentMediaTime() - firstFrameTime) * 1000 / 300)
        let frame = DetectionWithTime(
            squaresList: result.detectedList,
            frameIndex: frameIndex,
            aspect: result.aspectRatio,
            xSqCount: result.xCount,
            ySqCount: result.yCount)
        DispatchQueue.main.async { [weak self] in
            guard let eventSink = self?.eventSink else { return}
            eventSink(frame.toMap())
        }
    }
}


extension VideoRecorder: FlutterStreamHandler {
    
    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            eventSink = events
            return nil
        }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}



extension RTCI420BufferProtocol {
    func correctRotation(rotation: RTCVideoRotation) -> RTCI420BufferProtocol {
        let rotatedWidth: Int32
        let rotatedHeght: Int32
        if rotation == ._90 || rotation == ._270 {
            rotatedWidth = self.height
            rotatedHeght = self.width
        } else {
            rotatedHeght = self.height
            rotatedWidth = self.width
        }
        let buffer = RTCI420Buffer.init(width: rotatedWidth, height: rotatedHeght)
        RTCYUVHelper.i420Rotate(
            self.dataY,
            srcStrideY: strideY,
            srcU: dataU,
            srcStrideU: strideU,
            srcV: dataV,
            srcStrideV: strideV,
            dstY: UnsafeMutablePointer(mutating: buffer.dataY),
            dstStrideY: buffer.strideY,
            dstU: UnsafeMutablePointer(mutating:buffer.dataU),
            dstStrideU: buffer.strideU,
            dstV: UnsafeMutablePointer(mutating:buffer.dataV),
            dstStrideV: buffer.strideV,
            width: self.width,
            width: self.height,
            mode: rotation)
        return buffer
    }
    
}

extension CVPixelBuffer {
    func copy(from frame:RTCVideoFrame) {
        let i420Buf = frame.buffer.toI420().correctRotation(rotation: frame.rotation)
        CVPixelBufferLockBaseAddress(self, .readOnly)
        let pixelFormat: OSType = CVPixelBufferGetPixelFormatType(self)
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            
            let dstY = CVPixelBufferGetBaseAddressOfPlane(self, 0)
            let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(self, 0)
            let dstUV = CVPixelBufferGetBaseAddressOfPlane(self, 1)
            let dstUYStride = CVPixelBufferGetBytesPerRowOfPlane(self, 1)
            RTCYUVHelper.i420(toNV12: i420Buf.dataY,
                              srcStrideY: i420Buf.strideY,
                              srcU: i420Buf.dataU,
                              srcStrideU: i420Buf.strideU,
                              srcV: i420Buf.dataV,
                              srcStrideV: i420Buf.strideV,
                              dstY: dstY,
                              dstStrideY: Int32(dstYStride),
                              dstUV: dstUV,
                              dstStrideUV: Int32(dstUYStride),
                              width: i420Buf.width,
                              width: i420Buf.height)
        } else {
            let dst = CVPixelBufferGetBaseAddress(self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(self)
            if pixelFormat == kCVPixelFormatType_32BGRA {
                
                RTCYUVHelper.i420(toARGB: i420Buf.dataY,
                                  srcStrideY: i420Buf.strideY,
                                  srcU: i420Buf.dataU,
                                  srcStrideU: i420Buf.strideU,
                                  srcV: i420Buf.dataV,
                                  srcStrideV: i420Buf.strideV,
                                  dstARGB: dst,
                                  dstStrideARGB: Int32(bytesPerRow),
                                  width: i420Buf.width,
                                  height: i420Buf.height)
            } else if pixelFormat == kCVPixelFormatType_32ARGB {
                RTCYUVHelper.i420(toBGRA: i420Buf.dataY,
                                  srcStrideY: i420Buf.strideY,
                                  srcU: i420Buf.dataU,
                                  srcStrideU: i420Buf.strideU,
                                  srcV: i420Buf.dataV,
                                  srcStrideV: i420Buf.strideV,
                                  dstBGRA: dst,
                                  dstStrideBGRA: Int32(bytesPerRow),
                                  width: i420Buf.width,
                                  height: i420Buf.height)
                
            }
        }
        CVPixelBufferUnlockBaseAddress(self, .readOnly)
    }
}

