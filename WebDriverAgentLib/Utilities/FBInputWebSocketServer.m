/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBInputWebSocketServer.h"

#import <XCTest/XCTest.h>

#import "GCDAsyncSocket.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCUIDevice+FBHelpers.h"
#import "XCUIElement+FBTyping.h"
#import "XCSynthesizedEventRecord.h"
#import "XCPointerEventPath.h"

static const uint64_t kMaxLineLength = 65536; // 64 KB

@interface FBInputWebSocketServer () <GCDAsyncSocketDelegate>
@property (nonatomic, strong) GCDAsyncSocket *listenSocket;
@property (nonatomic, strong) dispatch_queue_t socketQueue;
@property (nonatomic, strong) NSMutableArray<GCDAsyncSocket *> *clients;
@end

@implementation FBInputWebSocketServer

- (instancetype)init
{
  if ((self = [super init])) {
    _socketQueue = dispatch_queue_create("com.specchio.inputtcp", DISPATCH_QUEUE_SERIAL);
    _listenSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:_socketQueue];
    _clients = [NSMutableArray array];
  }
  return self;
}

- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error
{
  if (![self.listenSocket acceptOnPort:port error:error]) {
    return NO;
  }
  [FBLogger logFmt:@"InputTCP: listening on port %d", port];
  return YES;
}

- (void)stop
{
  @synchronized (self.clients) {
    for (GCDAsyncSocket *c in self.clients) {
      [c disconnect];
    }
    [self.clients removeAllObjects];
  }
  [self.listenSocket disconnect];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket
{
  @synchronized (self.clients) {
    [self.clients addObject:newSocket];
  }
  [FBLogger logFmt:@"InputTCP: client connected from %@:%d", newSocket.connectedHost, newSocket.connectedPort];
  // Start reading newline-delimited JSON
  [newSocket readDataToData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]
                withTimeout:-1
                  maxLength:kMaxLineLength
                        tag:0];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
  @synchronized (self.clients) {
    [self.clients removeObject:sock];
  }
  [FBLogger logFmt:@"InputTCP: client disconnected%@",
   err ? [NSString stringWithFormat:@" (%@)", err.localizedDescription] : @""];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
  // Strip trailing newline / carriage return
  NSUInteger len = data.length;
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  while (len > 0 && (bytes[len - 1] == '\n' || bytes[len - 1] == '\r')) {
    len--;
  }

  if (len > 0) {
    NSData *lineData = [data subdataWithRange:NSMakeRange(0, len)];
    [self handleLine:lineData];
  }

  // Read next line immediately
  [sock readDataToData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]
           withTimeout:-1
             maxLength:kMaxLineLength
                   tag:0];
}

#pragma mark - Message Dispatch

- (void)handleLine:(NSData *)data
{
  NSError *jsonError;
  NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:data
                                                     options:(NSJSONReadingOptions)0
                                                       error:&jsonError];
  if (!msg || ![msg isKindOfClass:[NSDictionary class]]) {
    [FBLogger logFmt:@"InputTCP: invalid JSON: %@", jsonError.localizedDescription];
    return;
  }

  NSString *type = msg[@"type"];
  if (!type) return;

  // Dispatch on main queue — XCTest APIs need the main thread
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([type isEqualToString:@"keys"]) {
      [self handleKeysMessage:msg];
    } else if ([type isEqualToString:@"tap"]) {
      [self handleTapMessage:msg];
    } else if ([type isEqualToString:@"swipe"]) {
      [self handleSwipeMessage:msg];
    } else if ([type isEqualToString:@"button"]) {
      [self handleButtonMessage:msg];
    }
  });
}

#pragma mark - Input Handlers

- (void)handleKeysMessage:(NSDictionary *)msg
{
  NSArray *valueArray = msg[@"value"];
  if (![valueArray isKindOfClass:[NSArray class]] || valueArray.count == 0) return;

  NSString *text = [valueArray componentsJoinedByString:@""];
  NSUInteger frequency = [msg[@"frequency"] unsignedIntegerValue] ?: [FBConfiguration maxTypingFrequency];

  NSError *error;
  if (!FBTypeText(text, frequency, &error)) {
    [FBLogger logFmt:@"InputTCP: FBTypeText failed: %@", error.localizedDescription];
  }
}

- (void)handleTapMessage:(NSDictionary *)msg
{
  double x = [msg[@"x"] doubleValue];
  double y = [msg[@"y"] doubleValue];

  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"TCP tap"];
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(x, y)
                                                                      offset:0.0];
  [path liftUpAtOffset:0.05];
  [record addPointerEventPath:path];

  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    [FBLogger logFmt:@"InputTCP: tap failed: %@", error.localizedDescription];
  }
}

- (void)handleSwipeMessage:(NSDictionary *)msg
{
  double fromX = [msg[@"fromX"] doubleValue];
  double fromY = [msg[@"fromY"] doubleValue];
  double toX   = [msg[@"toX"] doubleValue];
  double toY   = [msg[@"toY"] doubleValue];
  double durationMs = msg[@"duration"] ? [msg[@"duration"] doubleValue] : 200.0;
  double durationSec = durationMs / 1000.0;

  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"TCP swipe"];
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(fromX, fromY)
                                                                      offset:0.0];
  [path moveToPoint:CGPointMake(toX, toY) atOffset:durationSec];
  [path liftUpAtOffset:durationSec + 0.01];
  [record addPointerEventPath:path];

  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    [FBLogger logFmt:@"InputTCP: swipe failed: %@", error.localizedDescription];
  }
}

- (void)handleButtonMessage:(NSDictionary *)msg
{
  NSString *name = msg[@"name"];
  if (!name) return;

  NSError *error;
  if (![XCUIDevice.sharedDevice fb_pressButton:name forDuration:nil error:&error]) {
    [FBLogger logFmt:@"InputTCP: button press failed: %@", error.localizedDescription];
  }
}

@end
