package com.cloudwebrtc.webrtc.detection

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import org.webrtc.NetworkMonitor.init
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import kotlin.concurrent.thread

class MotionDetection(binaryMessenger: BinaryMessenger) :
    VideoSink, EventChannel.StreamHandler {
    private var videoTrack: VideoTrack? = null
    private val pixelDetection by lazy { PixelDetection() }
    private val eventChannel = EventChannel(binaryMessenger, "FlutterWebRTC/motionDetection")
    private var eventSink: EventChannel.EventSink? = null
    private var prevDetection = 0L
    private var detectionLevel = 2
    private var intervalMs = 300
    private var started = false
    private var listener: Listener? = null

    init {
        eventChannel.setStreamHandler(this)
    }

    fun requestMotionDetection(request: DetectionRequest, videoTrack: VideoTrack) {
        if (!request.enabled) {
            stopDetection()
            return
        }
        if (!started) {
            startDetection(videoTrack)
        }
        setDetectionLevel(request.level)
    }

    fun addListener(listener: Listener) {
        this.listener = listener;
    }

    fun removeListener() {
        this.listener = null
    }

    private fun startDetection(videoTrack: VideoTrack) {
        this.started = true
        this.videoTrack = videoTrack
        videoTrack.addSink(this)
        Log.d("TAG", "Motion detection started")
    }

    private fun stopDetection() {
        videoTrack?.removeSink(this)
        videoTrack = null
        pixelDetection.resetPrevious()
        this.started = false
        Log.d("TAG", "Motion detection stopped")
    }

    val frameIntervalMs: Long
        get() = this.intervalMs.toLong()


    private fun setDetectionLevel(level: Int) {
        this.detectionLevel = level
    }

    override fun onFrame(videoFrame: VideoFrame) {
        if (System.currentTimeMillis() - prevDetection < intervalMs) {
            return
        }
        prevDetection = System.currentTimeMillis()
        videoFrame.retain()
        val i420Buffer = videoFrame.buffer.toI420() ?: return
        val rotation = videoFrame.rotation
        videoFrame.release()
        thread {
            pixelDetection.detect(
                buffer = i420Buffer,
                rotation = rotation,
                detectionLevel = detectionLevel
            ) { result ->
                sendDetection(result)
                listener?.onDetect(result)
            }
        }
    }

    private fun sendDetection(detected: DetectionResult) {
        if (!started) return
        val params = detected.toMap()
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(params)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        this.eventSink = null
    }

    fun dispose() {
        if (started) {
            stopDetection()
            started = false
        }
        eventSink = null;

    }

    interface Listener {
        fun onDetect(detection: DetectionResult)
    }

}




