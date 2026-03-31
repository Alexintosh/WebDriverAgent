/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBH264Encoder.h"

#import <VideoToolbox/VideoToolbox.h>

#import "FBLogger.h"

static void compressionOutputCallback(void *outputCallbackRefCon,
                                       void *sourceFrameRefCon,
                                       OSStatus status,
                                       VTEncodeInfoFlags infoFlags,
                                       CMSampleBufferRef sampleBuffer)
{
  if (status != noErr || sampleBuffer == NULL) {
    [FBLogger logFmt:@"H264 encode error: %d", (int)status];
    return;
  }

  FBH264Encoder *encoder = (__bridge FBH264Encoder *)outputCallbackRefCon;

  // Check if this is a keyframe
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  BOOL isKeyframe = YES;
  if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
    CFBooleanRef notSync;
    if (CFDictionaryGetValueIfPresent(dict, kCMSampleAttachmentKey_NotSync, (const void **)&notSync)) {
      isKeyframe = !CFBooleanGetValue(notSync);
    }
  }

  NSMutableData *nalData = [NSMutableData data];

  // For keyframes, prepend SPS and PPS parameter sets
  if (isKeyframe) {
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    size_t spsSize, ppsSize;
    size_t spsCount, ppsCount;
    const uint8_t *spsData, *ppsData;

    OSStatus spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDesc, 0, &spsData, &spsSize, &spsCount, NULL);
    OSStatus ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDesc, 1, &ppsData, &ppsSize, &ppsCount, NULL);

    if (spsStatus == noErr && ppsStatus == noErr) {
      // Annex B start code
      static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
      [nalData appendBytes:startCode length:4];
      [nalData appendBytes:spsData length:spsSize];
      [nalData appendBytes:startCode length:4];
      [nalData appendBytes:ppsData length:ppsSize];
    }
  }

  // Extract NAL units from the sample buffer (AVCC format → Annex B)
  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  size_t totalLength = 0;
  size_t offset = 0;
  char *dataPointer = NULL;

  OSStatus blockStatus = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer);
  if (blockStatus != noErr) {
    return;
  }

  static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
  static const int AVCCHeaderLength = 4; // AVCC uses 4-byte length prefix

  while (offset < totalLength) {
    uint32_t nalUnitLength = 0;
    memcpy(&nalUnitLength, dataPointer + offset, AVCCHeaderLength);
    nalUnitLength = CFSwapInt32BigToHost(nalUnitLength);
    offset += AVCCHeaderLength;

    [nalData appendBytes:startCode length:4];
    [nalData appendBytes:dataPointer + offset length:nalUnitLength];
    offset += nalUnitLength;
  }

  if (encoder.onEncodedFrame && nalData.length > 0) {
    encoder.onEncodedFrame(nalData, isKeyframe);
  }
}


@interface FBH264Encoder ()

@property (nonatomic, assign) VTCompressionSessionRef session;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, assign) int bitrate;
@property (nonatomic, assign) int keyframeInterval;

@end


@implementation FBH264Encoder

- (nullable instancetype)initWithWidth:(int)width
                                height:(int)height
                               bitrate:(int)bitrate
                      keyframeInterval:(int)keyframeInterval
{
  if ((self = [super init])) {
    _width = width;
    _height = height;
    _bitrate = bitrate;
    _keyframeInterval = keyframeInterval;

    if (![self createSession]) {
      return nil;
    }
  }
  return self;
}

- (BOOL)createSession
{
  OSStatus status = VTCompressionSessionCreate(
      NULL,           // allocator
      self.width,
      self.height,
      kCMVideoCodecType_H264,
      NULL,           // encoder specification
      NULL,           // source image buffer attributes
      NULL,           // compressed data allocator
      compressionOutputCallback,
      (__bridge void *)self,
      &_session);

  if (status != noErr) {
    [FBLogger logFmt:@"Failed to create VTCompressionSession: %d", (int)status];
    return NO;
  }

  // Realtime encoding
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);

  // No B-frames — low latency
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

  // Baseline profile for maximum compatibility
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                       kVTProfileLevel_H264_Baseline_AutoLevel);

  // Keyframe interval
  CFNumberRef keyframeRef = CFNumberCreate(NULL, kCFNumberIntType, &_keyframeInterval);
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyframeRef);
  CFRelease(keyframeRef);

  // Average bitrate
  CFNumberRef bitrateRef = CFNumberCreate(NULL, kCFNumberIntType, &_bitrate);
  VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
  CFRelease(bitrateRef);

  VTCompressionSessionPrepareToEncodeFrames(_session);

  [FBLogger logFmt:@"H264 encoder created: %dx%d @ %d bps, keyframe every %d frames",
   _width, _height, _bitrate, _keyframeInterval];

  return YES;
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer timestamp:(uint64_t)timestamp
{
  if (!_session) {
    return;
  }

  CMTime pts = CMTimeMake(timestamp, (int32_t)NSEC_PER_SEC);
  VTCompressionSessionEncodeFrame(_session, pixelBuffer, pts, kCMTimeInvalid, NULL, NULL, NULL);
}

- (void)invalidate
{
  if (_session) {
    VTCompressionSessionInvalidate(_session);
    CFRelease(_session);
    _session = NULL;
    [FBLogger log:@"H264 encoder invalidated"];
  }
}

- (void)dealloc
{
  [self invalidate];
}

@end
