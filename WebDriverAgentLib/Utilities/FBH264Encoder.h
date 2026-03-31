/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Wraps VTCompressionSession for realtime H.264 encoding.
 Thread-safe: encode calls are serialized internally.
 */
@interface FBH264Encoder : NSObject

/**
 Called on the compression callback queue with each encoded NAL unit.
 The data includes start codes and is ready to be framed and sent over TCP.
 */
@property (nonatomic, copy, nullable) void (^onEncodedFrame)(NSData *nalData, BOOL isKeyframe);

/**
 Creates an encoder for the given dimensions.

 @param width Frame width in pixels
 @param height Frame height in pixels
 @param bitrate Target average bitrate in bits/sec (e.g. 4000000 for 4 Mbps)
 @param keyframeInterval Maximum number of frames between keyframes
 @return Configured encoder, or nil if VTCompressionSession creation failed
 */
- (nullable instancetype)initWithWidth:(int)width
                                height:(int)height
                               bitrate:(int)bitrate
                      keyframeInterval:(int)keyframeInterval;

/**
 Submits a pixel buffer for encoding.

 @param pixelBuffer The CVPixelBuffer to encode (must match configured dimensions)
 @param timestamp Presentation timestamp in nanoseconds (monotonic)
 */
- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer timestamp:(uint64_t)timestamp;

/**
 Tears down the compression session and releases all resources.
 Safe to call multiple times.
 */
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
