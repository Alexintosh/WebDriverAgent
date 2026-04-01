/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Plain TCP server for low-latency input.
 Accepts TCP connections on its own port and reads newline-delimited JSON.
 Dispatches input commands (keys, tap, swipe, button) to XCTest APIs.
 Fire-and-forget: no response is sent.
 */
@interface FBInputWebSocketServer : NSObject

/**
 Start accepting connections on the given port.

 @param port The TCP port to bind on.
 @param error Set on failure.
 @return YES if the server started.
 */
- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error;

/**
 Stop the server and disconnect all clients.
 */
- (void)stop;

@end

NS_ASSUME_NONNULL_END
