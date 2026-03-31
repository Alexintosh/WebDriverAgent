/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBH264Server.h"

#import <mach/mach_time.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreVideo/CoreVideo.h>
@import UniformTypeIdentifiers;

#import "GCDAsyncSocket.h"
#import "FBConfiguration.h"
#import "FBH264Encoder.h"
#import "FBLogger.h"
#import "FBScreenshot.h"
#import "XCUIScreen.h"

static const NSUInteger MAX_FPS = 60;
static const NSTimeInterval FRAME_TIMEOUT = 1.;
static const NSTimeInterval FAILURE_BACKOFF_MIN = 1.0;
static const NSTimeInterval FAILURE_BACKOFF_MAX = 10.0;

static NSString *const SERVER_NAME = @"WDA H264 Server";
static const char *QUEUE_NAME = "H264 Screenshots Provider Queue";


static NSInteger _h264ActiveClientCount = 0;

@interface FBH264Server ()

@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) NSMutableArray<GCDAsyncSocket *> *listeningClients;
@property (nonatomic, readonly) long long mainScreenID;
@property (nonatomic, assign) NSUInteger consecutiveScreenshotFailures;
@property (nonatomic, strong) FBH264Encoder *encoder;
@property (nonatomic, assign) int lastWidth;
@property (nonatomic, assign) int lastHeight;
@property (nonatomic, assign) BOOL captureLoopRunning;

@end


@implementation FBH264Server

+ (BOOL)hasActiveClients
{
  @synchronized (self) {
    return _h264ActiveClientCount > 0;
  }
}

- (instancetype)init
{
  if ((self = [super init])) {
    _consecutiveScreenshotFailures = 0;
    _listeningClients = [NSMutableArray array];
    dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    _backgroundQueue = dispatch_queue_create(QUEUE_NAME, queueAttributes);
    // Don't start capture loop here — start on first client connect
    _mainScreenID = [XCUIScreen.mainScreen displayID];
    _lastWidth = 0;
    _lastHeight = 0;
  }
  return self;
}

- (void)scheduleNextFrameWithInterval:(uint64_t)timerInterval timeStarted:(uint64_t)timeStarted
{
  uint64_t timeElapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - timeStarted;
  int64_t nextTickDelta = timerInterval - timeElapsed;
  if (nextTickDelta > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nextTickDelta), self.backgroundQueue, ^{
      [self streamFrame];
    });
  } else {
    dispatch_async(self.backgroundQueue, ^{
      [self streamFrame];
    });
  }
}

- (void)streamFrame
{
  NSUInteger framerate = FBConfiguration.mjpegServerFramerate;
  uint64_t timerInterval = (uint64_t)(1.0 / ((0 == framerate || framerate > MAX_FPS) ? MAX_FPS : framerate) * NSEC_PER_SEC);
  uint64_t timeStarted = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

  @synchronized (self.listeningClients) {
    if (0 == self.listeningClients.count) {
      // No clients — stop the loop entirely (will restart on next connect)
      self.captureLoopRunning = NO;
      [FBLogger log:@"H264: no clients, capture loop stopped"];
      return;
    }
  }

  // Capture JPEG screenshot
  NSError *error;
  NSData *screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:self.mainScreenID
                                                           compressionQuality:0.8
                                                                          uti:UTTypeJPEG
                                                                      timeout:FRAME_TIMEOUT
                                                                        error:&error];
  if (nil == screenshotData) {
    [FBLogger logFmt:@"H264: %@", error.description];
    self.consecutiveScreenshotFailures++;
    NSTimeInterval backoffSeconds = MIN(FAILURE_BACKOFF_MAX,
                                        FAILURE_BACKOFF_MIN * (1 << MIN(self.consecutiveScreenshotFailures, 4)));
    uint64_t backoffInterval = (uint64_t)(backoffSeconds * NSEC_PER_SEC);
    [self scheduleNextFrameWithInterval:backoffInterval timeStarted:timeStarted];
    return;
  }

  self.consecutiveScreenshotFailures = 0;

  // Decode JPEG to CGImage
  CGImageRef cgImage = [self decodeJPEG:screenshotData];
  if (!cgImage) {
    [self scheduleNextFrameWithInterval:timerInterval timeStarted:timeStarted];
    return;
  }

  CGFloat scale = FBConfiguration.h264ServerResolutionScale / 100.0;
  int width = (int)(CGImageGetWidth(cgImage) * scale);
  int height = (int)(CGImageGetHeight(cgImage) * scale);
  // Ensure even dimensions (H.264 requirement)
  width &= ~1;
  height &= ~1;

  // Create or recreate encoder if dimensions changed
  if (!self.encoder || width != self.lastWidth || height != self.lastHeight) {
    [self.encoder invalidate];
    self.encoder = [[FBH264Encoder alloc] initWithWidth:width
                                                 height:height
                                                bitrate:FBConfiguration.h264ServerBitrate
                                       keyframeInterval:FBConfiguration.h264ServerKeyframeInterval];
    if (!self.encoder) {
      [FBLogger log:@"H264: Failed to create encoder"];
      CGImageRelease(cgImage);
      [self scheduleNextFrameWithInterval:timerInterval timeStarted:timeStarted];
      return;
    }
    self.lastWidth = width;
    self.lastHeight = height;

    __weak typeof(self) weakSelf = self;
    self.encoder.onEncodedFrame = ^(NSData *nalData, BOOL isKeyframe) {
      [weakSelf sendEncodedData:nalData];
    };
  }

  // Convert CGImage to CVPixelBuffer
  CVPixelBufferRef pixelBuffer = [self pixelBufferFromCGImage:cgImage];
  CGImageRelease(cgImage);

  if (pixelBuffer) {
    uint64_t timestamp = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    [self.encoder encodePixelBuffer:pixelBuffer timestamp:timestamp];
    CVPixelBufferRelease(pixelBuffer);
  }

  [self scheduleNextFrameWithInterval:timerInterval timeStarted:timeStarted];
}

- (CGImageRef)decodeJPEG:(NSData *)jpegData
{
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpegData, NULL);
  if (!source) {
    return NULL;
  }
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  CFRelease(source);
  return image;
}

- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image
{
  int width = (int)CGImageGetWidth(image);
  int height = (int)CGImageGetHeight(image);

  NSDictionary *attrs = @{
    (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
  };

  CVPixelBufferRef pixelBuffer = NULL;
  CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width, height,
                                         kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)attrs,
                                         &pixelBuffer);

  if (status != kCVReturnSuccess) {
    return NULL;
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);

  void *pxdata = CVPixelBufferGetBaseAddress(pixelBuffer);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(pxdata,
                                                width, height,
                                                8,
                                                CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                colorSpace,
                                                kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
  CGContextRelease(context);
  CGColorSpaceRelease(colorSpace);

  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

  return pixelBuffer;
}

- (void)sendEncodedData:(NSData *)nalData
{
  // Wire format: [4 bytes big-endian length][NAL data]
  uint32_t length = CFSwapInt32HostToBig((uint32_t)nalData.length);
  NSMutableData *framedData = [NSMutableData dataWithCapacity:4 + nalData.length];
  [framedData appendBytes:&length length:4];
  [framedData appendData:nalData];

  @synchronized (self.listeningClients) {
    for (GCDAsyncSocket *client in self.listeningClients) {
      [client writeData:framedData withTimeout:-1 tag:0];
    }
  }
}

#pragma mark - FBTCPSocketDelegate

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [FBLogger logFmt:@"H264: client connected from %@:%d", newClient.connectedHost, newClient.connectedPort];
  @synchronized (self.listeningClients) {
    [self.listeningClients addObject:newClient];
  }
  @synchronized ([FBH264Server class]) {
    _h264ActiveClientCount++;
  }
  // Start capture loop on first client
  if (!self.captureLoopRunning) {
    self.captureLoopRunning = YES;
    dispatch_async(self.backgroundQueue, ^{
      [self streamFrame];
    });
  }
  [FBLogger logFmt:@"H264: active clients = %ld (MJPEG capture paused)", (long)_h264ActiveClientCount];
}

- (void)didClientSendData:(GCDAsyncSocket *)client
{
  // H.264 server is push-only — no client data expected
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
  }
  @synchronized ([FBH264Server class]) {
    _h264ActiveClientCount = MAX(0, _h264ActiveClientCount - 1);
  }
  [FBLogger logFmt:@"H264: client disconnected, active clients = %ld", (long)_h264ActiveClientCount];
}

@end
