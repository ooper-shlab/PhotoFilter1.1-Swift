//
//  AVReaderWriter.swift
//  Photo Filter
//
//  Created by 開発 on 2014/08/09.
//
//
/*
 Copyright (C) 2014 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information

 Abstract:

  Helper class to read and decode a movie frame by frame, adjust each frame, then encode and write to a new movie file.

 */

import AVFoundation
import Foundation
extension Boolean: BooleanLiteralConvertible {
    public static func convertFromBooleanLiteral(value: BooleanLiteralType)->Boolean {
        return value ? 1 : 0;
    }
    public init(booleanLiteral value:Bool) {
        self = value ? 1 : 0;
    }
}

import CoreMedia
//Constants taken from <CoreMedia/CMFormatDescription.h>
// Many of the following extension keys and values are the same as the corresponding CVImageBuffer attachment keys and values
let kCMFormatDescriptionExtension_CleanAperture: NSString = kCVImageBufferCleanApertureKey					// CFDictionary containing the following four keys
let kCMFormatDescriptionKey_CleanApertureWidth: NSString = kCVImageBufferCleanApertureWidthKey				// CFNumber
let kCMFormatDescriptionKey_CleanApertureHeight: NSString = kCVImageBufferCleanApertureHeightKey			// CFNumber
let kCMFormatDescriptionKey_CleanApertureHorizontalOffset: NSString = kCVImageBufferCleanApertureHorizontalOffsetKey	// CFNumber
let kCMFormatDescriptionKey_CleanApertureVerticalOffset: NSString = kCVImageBufferCleanApertureVerticalOffsetKey	// CFNumber

let kCMFormatDescriptionExtension_PixelAspectRatio: NSString = kCVImageBufferPixelAspectRatioKey				// CFDictionary with the following two keys
let kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: NSString = kCVImageBufferPixelAspectRatioHorizontalSpacingKey	// CFNumber
let kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: NSString = kCVImageBufferPixelAspectRatioVerticalSpacingKey	// CFNumber

@objc(AAPLAVReaderWriterAdjustDelegate)
protocol AVReaderWriterAdjustDelegate {
    optional func adjustPixelBuffer(adjustPixelBuffer: CVPixelBuffer!)
    
    optional func adjustPixelBuffer(inputBuffer: CVPixelBuffer!, toOutputBuffer outputBuffer: CVPixelBuffer!)
}


@objc private
protocol RWSampleBufferChannelDelegate: NSObjectProtocol {
    
    optional func sampleBufferChannel(sampleBufferChannel: RWSampleBufferChannel,
        didReadSampleBuffer sampleBuffer: CMSampleBuffer)
    
    optional func sampleBufferChannel(sampleBufferChannel: RWSampleBufferChannel,
        didReadSampleBuffer sampleBuffer: CMSampleBuffer,
        andMadeWriteSampleBuffer sampleBufferForWrite: CVPixelBuffer)
    
}


private
class RWSampleBufferChannel: NSObject {
    //MARK: defined in interface in .m
    private var completionHandler: dispatch_block_t?
    private var serializationQueue: dispatch_queue_t
    
    private var useAdaptor: Bool
    private var finished: Bool // only accessed on serialization queue;
    private var assetWriterInput: AVAssetWriterInput
    private var assetReaderOutput: AVAssetReaderOutput
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    //MARK: defined in implementation
    init(assetReaderOutput localAssetReaderOutput: AVAssetReaderOutput,
        assetWriterInput localAssetWriterInput: AVAssetWriterInput,
        useAdaptor: Bool) {
            
            assetReaderOutput = localAssetReaderOutput
            assetWriterInput = localAssetWriterInput
            
            finished = false
            
            // Pixel buffer attributes keys for the pixel buffer pool are defined in <CoreVideo/CVPixelBuffer.h>.
            // To specify the pixel format type, the pixelBufferAttributes dictionary should contain a value for kCVPixelBufferPixelFormatTypeKey.
            // For example, use [NSNumber numberWithInt:kCVPixelFormatType_32BGRA] for 8-bit-per-channel BGRA.
            // See the discussion under appendPixelBuffer:withPresentationTime: for advice on choosing a pixel format.
            //
            self.useAdaptor = useAdaptor
            let adaptorAttrs: [NSObject: AnyObject] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
            ]
            if useAdaptor {
                adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: localAssetWriterInput,
                    sourcePixelBufferAttributes: adaptorAttrs)
            }
            
            serializationQueue = dispatch_queue_create("AAPLRWSampleBufferChannel queue", nil)
            super.init()
            
    }
    
    // always called on the serialization queue
    private func callCompletionHandlerIfNecessary() {
        // Set state to mark that we no longer need to call the completion handler, grab the completion handler, and clear out the ivar
        var oldFinished = finished
        finished = true
        
        if !oldFinished {
            assetWriterInput.markAsFinished()  // let the asset writer know that we will not be appending any more samples to this input
            
            let localCompletionHandler = completionHandler
            completionHandler = nil
            
            localCompletionHandler?()
        }
    }
    
    
    // delegate is retained until completion handler is called.
    // Completion handler is guaranteed to be called exactly once, whether reading/writing finishes, fails, or is cancelled.
    // Delegate may be nil.
    //
    func startWithDelegate(delegate: RWSampleBufferChannelDelegate?, completionHandler localCompletionHandler: dispatch_block_t) {
        //TODO: see if not copying really works!
        completionHandler = localCompletionHandler  // released in -callCompletionHandlerIfNecessary
        
        assetWriterInput.requestMediaDataWhenReadyOnQueue(serializationQueue) {
            
            if self.finished {
                return
            }
            
            var completedOrFailed = false
            
            // Read samples in a loop as long as the asset writer input is ready
            while self.assetWriterInput.readyForMoreMediaData && !completedOrFailed {
                autoreleasepool {
                    
                    if let sampleBuffer = self.assetReaderOutput.copyNextSampleBuffer() {
                        var success = false
                        
                        let sampleBufferChannel: ((RWSampleBufferChannel,didReadSampleBuffer:CMSampleBuffer,andMadeWriteSampleBuffer:CVPixelBuffer)->Void)? = delegate?.sampleBufferChannel
                        if self.adaptor != nil && sampleBufferChannel != nil {
                            var writerBuffer: Unmanaged<CVPixelBuffer>?
                            CVPixelBufferPoolCreatePixelBuffer(nil, self.adaptor!.pixelBufferPool,
                                &writerBuffer);
                            let managedWriterBuffer = writerBuffer?.takeRetainedValue()
                            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                            
                            sampleBufferChannel!(self, didReadSampleBuffer:sampleBuffer, andMadeWriteSampleBuffer:managedWriterBuffer!)
                            success = self.adaptor!.appendPixelBuffer(managedWriterBuffer, withPresentationTime: presentationTime)
                            
                        } else if let sampleBufferChannel = delegate?.sampleBufferChannel?
                            as ((RWSampleBufferChannel,didReadSampleBuffer:CMSampleBuffer)->Void)? {
                                sampleBufferChannel(self, didReadSampleBuffer: sampleBuffer)
                                success = self.assetWriterInput.appendSampleBuffer(sampleBuffer)
                        }
                        
                        //Annotated CoreFoundation objects are managed.
                        
                        completedOrFailed = !success
                    } else {
                        completedOrFailed = true
                    }
                    
                }
            }
            
            if completedOrFailed {
                self.callCompletionHandlerIfNecessary()
            }
        }
    }
    
    func cancel() {
        dispatch_async(serializationQueue) {
            self.callCompletionHandlerIfNecessary()
        }
    }
    
}


//MARK: -


typealias AVReaderWriterProgressProc = Float->Void
typealias AVReaderWriterCompletionProc = NSError?->Void

extension CMTime {
    var numeric: Bool {
        return ((self.flags & (CMTimeFlags.Valid | CMTimeFlags.ImpliedValueFlagsMask)) == CMTimeFlags.Valid)
    }
}

class AVReaderWriter: NSObject, RWSampleBufferChannelDelegate {
    //MARK: defined in interface
    var delegate: AVReaderWriterAdjustDelegate?
    
    //MARK: defined in interface extension
    private var asset: AVAsset!
    private var timeRange: CMTimeRange!
    private var outputURL: NSURL!
    
    //MARK: defined in implementation
    private var _serializationQueue: dispatch_queue_t
    
    // All of these are createed, accessed, and torn down exclusively on the serializaton queue
    private var assetReader: AVAssetReader!
    private var assetWriter: AVAssetWriter!
    private var audioSampleBufferChannel: RWSampleBufferChannel!
    private var videoSampleBufferChannel: RWSampleBufferChannel!
    private var cancelled: Bool = false
    private var _progressProc: AVReaderWriterProgressProc!
    private var _completionProc: AVReaderWriterCompletionProc!
    
    init(asset: AVAsset) {
        
        self.asset = asset
        _serializationQueue = dispatch_queue_create("AVReaderWriter Queue", nil)
        super.init()
    }
    
    func writeToURL(localOutputURL: NSURL!,
        progress: AVReaderWriterProgressProc!,
        completion: AVReaderWriterCompletionProc!) {
            outputURL = localOutputURL
            
            let localAsset = asset
            
            _completionProc = completion
            _progressProc = progress
            
            localAsset.loadValuesAsynchronouslyForKeys(["tracks", "duration"]) {
                
                // Dispatch the setup work to the serialization queue, to ensure this work is serialized with potential cancellation
                dispatch_async(self._serializationQueue) {
                    
                    // Since we are doing these things asynchronously, the user may have already cancelled on the main thread.  In that case, simply return from this block
                    if self.cancelled {
                        return
                    }
                    
                    var success = true
                    var localError: NSError? = nil
                    
                    success = (localAsset.statusOfValueForKey("tracks" ,error:&localError) == AVKeyValueStatus.Loaded)
                    if success {
                        success = (localAsset.statusOfValueForKey("duration", error:&localError) == AVKeyValueStatus.Loaded)
                    }
                    
                    if success {
                        self.timeRange = CMTimeRangeMake(kCMTimeZero, localAsset.duration)
                        
                        // AVAssetWriter does not overwrite files for us, so remove the destination file if it already exists
                        let fm = NSFileManager()
                        let localOutputPath = localOutputURL.path!
                        if fm.fileExistsAtPath(localOutputPath) {
                            success = fm.removeItemAtPath(localOutputPath, error:&localError)
                        }
                    }
                    
                    // Set up the AVAssetReader and AVAssetWriter, then begin writing samples or flag an error
                    if success {
                        success = self.setUpReaderAndWriterReturningError(&localError)
                    }
                    if success {
                        success = self.startReadingAndWritingReturningError(&localError)
                    }
                    
                    if !success {
                        self.readingAndWritingDidFinishSuccessfully(success, withError:localError)
                    }
                }
            }
    }
    
    private func setUpReaderAndWriterReturningError(outError: NSErrorPointer)->Bool {
        var localError: NSError? = nil
        let localAsset = asset
        let localOutputURL = outputURL
        
        // Create asset reader and asset writer
        assetReader = AVAssetReader(asset: localAsset, error:&localError)
        if localError != nil {
            if outError != nil {
                outError.memory = localError
            }
            return false
        }
        
        assetWriter = AVAssetWriter(URL: localOutputURL, fileType:AVFileTypeQuickTimeMovie, error: &localError)
        if localError != nil {
            if outError != nil {
                outError.memory = localError
            }
            return false
        }
        
        // Create asset reader outputs and asset writer inputs for the first audio track and first video track of the asset
        
        // Grab first audio track and first video track, if the asset has them
        var audioTrack: AVAssetTrack? = nil
        let audioTracks = localAsset.tracksWithMediaType(AVMediaTypeAudio)
        if audioTracks.count > 0 {
            audioTrack = (audioTracks[0] as AVAssetTrack)
        }
        
        var videoTrack: AVAssetTrack? = nil
        let videoTracks = localAsset.tracksWithMediaType(AVMediaTypeVideo)
        if videoTracks.count > 0 {
            videoTrack = (videoTracks[0] as AVAssetTrack)
        }
        
        if audioTrack != nil {
            // Decompress to Linear PCM with the asset reader
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            assetReader.addOutput(output)
            
            let input = AVAssetWriterInput(mediaType: audioTrack?.mediaType, outputSettings: nil)
            assetWriter.addInput(input)
            
            // Create and save an instance of AAPLRWSampleBufferChannel, which will coordinate the work of reading and writing sample buffers
            audioSampleBufferChannel = RWSampleBufferChannel(assetReaderOutput: output, assetWriterInput: input, useAdaptor: false)
        }
        
        if videoTrack != nil {
            // Decompress to ARGB with the asset reader
            let decompSettings: [NSObject: AnyObject] = [
                kCVPixelBufferPixelFormatTypeKey : kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey : [NSObject: AnyObject]()
            ]
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: decompSettings)
            assetReader.addOutput(output)
            
            // Get the format description of the track, to fill in attributes of the video stream that we don't want to change
            var formatDescription: CMFormatDescription? = nil
            let formatDescriptions = videoTrack!.formatDescriptions
            if formatDescriptions.count > 0 {
                formatDescription = (formatDescriptions[0] as CMFormatDescription)
            }
            
            // Grab track dimensions from format description
            var trackDimensions = CGSizeZero
            if formatDescription != nil {
                trackDimensions = CMVideoFormatDescriptionGetPresentationDimensions(formatDescription!, false, false)
            } else {
                trackDimensions = videoTrack!.naturalSize
            }
            
            // Grab clean aperture, pixel aspect ratio from format description
            var compressionSettings: [NSObject: AnyObject]? = nil
            if formatDescription != nil {
                var cleanAperture: [NSObject: AnyObject]? = nil
                let cleanApertureDescr = CMFormatDescriptionGetExtension(formatDescription!,
                    kCMFormatDescriptionExtension_CleanAperture)?.takeUnretainedValue() as NSDictionary?
                if let cleanApertureDesc = cleanApertureDescr {
                    cleanAperture = [
                        AVVideoCleanApertureWidthKey :
                            cleanApertureDesc[kCMFormatDescriptionKey_CleanApertureWidth]!,
                        AVVideoCleanApertureHeightKey :
                            cleanApertureDesc[kCMFormatDescriptionKey_CleanApertureHeight]!,
                        AVVideoCleanApertureHorizontalOffsetKey :
                            cleanApertureDesc[kCMFormatDescriptionKey_CleanApertureHorizontalOffset]!,
                        AVVideoCleanApertureVerticalOffsetKey :
                            cleanApertureDesc[kCMFormatDescriptionKey_CleanApertureVerticalOffset]!,
                    ]
                }
                
                var pixelAspectRatio: [NSObject: AnyObject]? = nil
                let pixelAspectRatioDescr = CMFormatDescriptionGetExtension(formatDescription!, kCMFormatDescriptionExtension_PixelAspectRatio)?.takeUnretainedValue() as NSDictionary?
                if let pixelAspectRatioDesc = pixelAspectRatioDescr {
                    pixelAspectRatio = [
                        AVVideoPixelAspectRatioHorizontalSpacingKey :
                            pixelAspectRatioDesc[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing]!,
                        AVVideoPixelAspectRatioVerticalSpacingKey :
                            pixelAspectRatioDesc[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing]!,
                    ]
                }
                
                if cleanAperture != nil || pixelAspectRatio != nil {
                    var mutableCompressionSettings: [NSObject: AnyObject] = [:]
                    if cleanAperture != nil {
                        mutableCompressionSettings[AVVideoCleanApertureKey] = cleanAperture
                    }
                    if pixelAspectRatio != nil {
                        mutableCompressionSettings[AVVideoPixelAspectRatioKey] = pixelAspectRatio
                    }
                    compressionSettings = mutableCompressionSettings
                }
            }
            
            // Compress to H.264 with the asset writer
            var videoSettings: [NSObject: AnyObject] = [
                AVVideoCodecKey: AVVideoCodecH264,
                AVVideoWidthKey: trackDimensions.width,
                AVVideoHeightKey: trackDimensions.height,
            ]
            if compressionSettings != nil {
                videoSettings[AVVideoCompressionPropertiesKey] = compressionSettings
            }
            
            let input = AVAssetWriterInput(mediaType: videoTrack!.mediaType, outputSettings: videoSettings)
            input.transform = videoTrack!.preferredTransform
            assetWriter.addInput(input)
            
            // Create and save an instance of AAPLRWSampleBufferChannel, which will coordinate the work of reading and writing sample buffers
            videoSampleBufferChannel = RWSampleBufferChannel(assetReaderOutput:output, assetWriterInput:input, useAdaptor:true)
        }
        
        return true
    }
    
    private func startReadingAndWritingReturningError(outError: NSErrorPointer)->Bool {
        // Instruct the asset reader and asset writer to get ready to do work
        if !assetReader.startReading() {
            if outError != nil {
                outError.memory = assetReader.error
            }
            return false
        }
        
        if !assetWriter.startWriting() {
            if outError != nil {
                outError.memory = assetWriter.error
            }
            return false
        }
        
        
        let dispatchGroup = dispatch_group_create()
        
        // Start a sample-writing session
        assetWriter.startSessionAtSourceTime(timeRange.start)
        
        // Start reading and writing samples
        if audioSampleBufferChannel != nil {
            // Only set audio delegate for audio-only assets, else let the video channel drive progress
            var delegate: RWSampleBufferChannelDelegate? = nil
            if videoSampleBufferChannel == nil {
                delegate = self
            }
            
            dispatch_group_enter(dispatchGroup)
            audioSampleBufferChannel?.startWithDelegate(delegate) {
                dispatch_group_leave(dispatchGroup)
            }
        }
        if videoSampleBufferChannel != nil {
            dispatch_group_enter(dispatchGroup)
            videoSampleBufferChannel.startWithDelegate(self) {
                dispatch_group_leave(dispatchGroup)
            }
        }
        
        // Set up a callback for when the sample writing is finished
        dispatch_group_notify(dispatchGroup, _serializationQueue) {
            var finalSuccess = true
            var finalError: NSError? = nil
            
            if self.cancelled {
                self.assetReader.cancelReading()
                self.assetWriter.cancelWriting()
            } else {
                if self.assetReader.status == AVAssetReaderStatus.Failed {
                    finalSuccess = false
                    finalError = self.assetReader.error
                }
                
                if finalSuccess {
                    self.assetWriter.finishWritingWithCompletionHandler {
                        let success = (self.assetWriter.status == AVAssetWriterStatus.Completed)
                        self.readingAndWritingDidFinishSuccessfully(success, withError: self.assetWriter.error)
                    }
                }
            }
            
        }
        
        return true
    }
    
    private func cancel(sender: AnyObject!) {
        // Dispatch cancellation tasks to the serialization queue to avoid races with setup and teardown
        dispatch_async(_serializationQueue) {
            self.audioSampleBufferChannel.cancel()
            self.videoSampleBufferChannel.cancel()
            self.cancelled = true
        }
    }
    
    private func readingAndWritingDidFinishSuccessfully(success: Bool,  withError error: NSError?) {
        if !success {
            assetReader.cancelReading()
            assetWriter.cancelWriting()
        }
        
        // Tear down ivars
        assetReader = nil
        assetWriter = nil
        audioSampleBufferChannel = nil
        videoSampleBufferChannel = nil
        cancelled = false
        
        _completionProc(error)
    }
    
    private final func progressOfSampleBufferInTimeRange(sampleBuffer: CMSampleBuffer!, _ timeRange:CMTimeRange)->Double {
        var progressTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        progressTime = CMTimeSubtract(progressTime, timeRange.start);
        let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
        if sampleDuration.numeric {
            progressTime = CMTimeAdd(progressTime, sampleDuration)
        }
        return CMTimeGetSeconds(progressTime) / CMTimeGetSeconds(timeRange.duration)
    }
    
    
    private func sampleBufferChannel(sampleBufferChannel: RWSampleBufferChannel, didReadSampleBuffer sampleBuffer:CMSampleBuffer!) {
        // Calculate progress (scale of 0.0 to 1.0)
        let progress = progressOfSampleBufferInTimeRange(sampleBuffer, self.timeRange)
        
        _progressProc(Float(progress * 100.0))
        
        // Grab the pixel buffer from the sample buffer, if possible
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        
        if imageBuffer != nil && CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID() {
            //pixelBuffer = (CVPixelBufferRef)imageBuffer;
            //No need to convert CVImageBuffer to CVPixelBuffer in Xcode 6.1final
            delegate?.adjustPixelBuffer?(imageBuffer /*pixelBuffer*/)
        }
    }
    
    private func sampleBufferChannel(sampleBufferChannel: RWSampleBufferChannel!,
        didReadSampleBuffer sampleBuffer: CMSampleBuffer!,
        andMadeWriteSampleBuffer sampleBufferForWrite: CVPixelBuffer!) {
            // Calculate progress (scale of 0.0 to 1.0)
            let progress = progressOfSampleBufferInTimeRange(sampleBuffer, self.timeRange)
            
            _progressProc(Float(progress * 100.0))
            
            // Grab the pixel buffer from the sample buffer, if possible
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            
            if imageBuffer != nil && CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID()
                && sampleBufferForWrite != nil  {
                    //No need to convert CVImageBuffer to CVPixelBuffer in Xcode 6.1final
                    delegate?.adjustPixelBuffer?(imageBuffer/*pixelBuffer*/, toOutputBuffer: sampleBufferForWrite)
            }
    }
    
    
}