/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTCPSocket.h"

NS_ASSUME_NONNULL_BEGIN

/**
 Streams H.264-encoded screenshots over TCP.
 Wire format: [4-byte big-endian length][NAL unit data] per frame.
 Parallel to FBMjpegServer — uses the same FBTCPSocketDelegate pattern.
 */
@interface FBH264Server : NSObject <FBTCPSocketDelegate>

- (instancetype)init;

/**
 Returns YES when at least one H.264 client is connected.
 Used by FBMjpegServer to pause its capture loop and avoid
 competing for the serialized XCTest screenshot API.
 */
@property (class, readonly, atomic) BOOL hasActiveClients;

@end

NS_ASSUME_NONNULL_END
