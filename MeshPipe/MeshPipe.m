//
//  MeshPipe.m
//  MeshPipe
//
//  Created by Nevyn Bengtsson on 2015-08-18.
//  Copyright © 2015 ThirdCog. All rights reserved.
//

#import "MeshPipe.h"
#import "AsyncUdpSocket.h"
#import "GZIP.h"

//#define MPDebug(...) NSLog(__VA_ARGS__)
#define MPDebug(...)

typedef NS_ENUM(uint8_t, _MeshPipeMessageType) {
	_MeshPipeMessageTypeInternal = 1,
	_MeshPipeMessageTypeData = 2,
};

@interface MeshPipe () <AsyncUdpSocketDelegate>
{
	NSMutableSet<MeshPipePeer*> *_peers;
	NSMutableArray<MeshPipePeer*> *_potentialPeers;
	int _myPort;
	NSTimer *_keepaliveTimer;
}
@property(nonatomic,readonly) AsyncUdpSocket *listenSocket;
@end

@interface MeshPipePeer ()
{
}
@property(nonatomic) int port;
@property(nonatomic,readwrite) NSString *name;
@property(nonatomic) AsyncUdpSocket *socket;
@property(nonatomic) NSTimer *expectKeepaliveTimer;
@property(nonatomic,weak) MeshPipe *parent;
- (void)sendInternal:(NSDictionary*)internal;
@end

@interface MeshPipeSelfPeer : MeshPipePeer
@end

static const NSTimeInterval kKeepaliveDuration = 5;
static const NSTimeInterval kKeepaliveExpectedWithin = kKeepaliveDuration*1.5;

static NSData *SerializeInternal(NSDictionary *internal);
static NSDictionary *DeserializeInternal(NSData *data);

///// ------ IMPL --------

@implementation MeshPipe
- (instancetype)initWithBasePort:(int)basePort count:(int)count peerName:(NSString*)peerName delegate:(id<MeshPipeDelegate>)delegate
{
	if(!(self = [super init]))
		return nil;
	
	_basePort = basePort;
	_count = count;
	_peerName = peerName;
	_delegate = delegate;
	
	_potentialPeers = [NSMutableArray new];
	_peers = [NSMutableSet new];
	
	_listenSocket = [[AsyncUdpSocket alloc] initWithDelegate:self];

	for(int i = 0; i < count; i++) {
		int port = _basePort + i;
		BOOL success = [_listenSocket bindToAddress:@"localhost" port:port error:NULL];
		if(success) {
			_myPort = port;
			break;
		}
	}
	if(!_myPort) {
		NSLog(@"No free MeshPipe slots, not creating pipe");
		return nil;
	}
	
	MPDebug(@"MeshPipe listening on %d", _myPort);
	
	[_listenSocket receiveWithTimeout:-1 tag:0];
	
	for(int i = 0; i < count; i++) {
		int port = _basePort + i;
		MeshPipePeer *potentialPeer = (port == _myPort) ? [MeshPipeSelfPeer new] : [MeshPipePeer new];
		potentialPeer.parent = self;
		potentialPeer.socket = [[AsyncUdpSocket alloc] initWithDelegate:self];
		potentialPeer.port = port;
		[_potentialPeers addObject:potentialPeer];
		
		NSError *err;
		if(![potentialPeer.socket connectToHost:@"localhost" onPort:potentialPeer.port error:&err]) {
			NSLog(@"Unexectedly couldn't connect to MeshPipe potential peer %d, giving up: %@", i, err);
			return nil;
		}
		[self announceTo:potentialPeer];
		[potentialPeer sendInternal:@{
			@"cmd": @"pleaseAnnounceTo",
		}];
	}
	
	_keepaliveTimer = [NSTimer scheduledTimerWithTimeInterval:kKeepaliveDuration target:self selector:@selector(keepalive) userInfo:nil repeats:YES];
	
	return self;
}

- (void)dealloc
{

}

- (void)disconnect
{
	MPDebug(@"Disconnecting from %@", _peers);
	for(MeshPipePeer *peer in _peers)
		[peer sendInternal:@{
			@"cmd": @"disconnected",
		}];
	[_keepaliveTimer invalidate];
	[_listenSocket closeAfterSending];
}

- (void)keepalive
{
	if(_peers.count == 0)
		return;
	
	MPDebug(@"Sending keepalive to %@", _peers);
	for(MeshPipePeer *peer in _peers) {
		[peer sendInternal:@{
			@"cmd": @"keepalive",
		}];
	}
}
- (void)keepaliveExpected:(NSTimer*)timer
{
	MeshPipePeer *peer = timer.userInfo;
	MPDebug(@"%@ timed out", peer);
	
	[peer sendInternal:@{
		@"cmd": @"youTimedOut"
	}];
	[self markPeerAsUnavailable:peer forReason:[NSError errorWithDomain:MeshPipeErrorDomain code:MeshPipeErrorPeerTimedOut userInfo:@{
		NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ timed out", peer.name],
	}]];
}

- (void)announceTo:(MeshPipePeer*)peer
{
	[peer sendInternal:@{
		@"cmd": @"announce",
		@"name": _peerName,
	}];
}

- (BOOL)onUdpSocket:(AsyncUdpSocket *)sock
     didReceiveData:(NSData *)data
            withTag:(long)tag
           fromHost:(NSString *)host
               port:(UInt16)port
{
	if(![host isEqual:@"localhost"] && ![host isEqual:@"127.0.0.1"]) {
		MPDebug(@"Received unexpected message from host %@", host);
		return NO;
	}
	
	if(port < _basePort || port >= _basePort + _count) {
		MPDebug(@"Received unexpected message on port %d", port);
		return NO;
	}
	int i = port - _basePort;
	
	MeshPipePeer *peer = _potentialPeers[i];
	
	_MeshPipeMessageType type = ((uint8_t*)[data bytes])[0];
	NSData *payload = [data subdataWithRange:NSMakeRange(1, data.length-1)];
	if(type == _MeshPipeMessageTypeInternal) {
		NSDictionary *internal = DeserializeInternal(payload);
		if(!internal) {
			MPDebug(@"Unable to deserialize %@", payload);
			return NO;
		}
		if(![self handleInternal:internal fromPeer:peer])
			return NO;
	} else if(type == _MeshPipeMessageTypeData) {
		MPDebug(@"Reveived from peer %@ message %@", peer, payload);
		if([self.delegate respondsToSelector:@selector(meshPipe:receivedData:fromPeer:)]) {
			[self.delegate meshPipe:self receivedData:payload fromPeer:peer];
		}
		if([peer.delegate respondsToSelector:@selector(meshPipePeer:receivedData:)]) {
			[peer.delegate meshPipePeer:peer receivedData:payload];
		}
	} else {
		MPDebug(@"Received unexpected message type from %@", peer);
		return NO;
	}
	
	[sock receiveWithTimeout:-1 tag:0];
	return YES;
}

- (BOOL)handleInternal:(NSDictionary*)internal fromPeer:(MeshPipePeer*)peer
{
	MPDebug(@"Handling peer %@ internal %@", peer, internal);
	
	NSString *cmd = internal[@"cmd"];
	if(!cmd) return NO;
	
	if([cmd isEqual:@"pleaseAnnounceTo"]) {
		[self announceTo:peer];
	} else if([cmd isEqual:@"announce"]) {
		NSString *name = internal[@"name"];
		if(!name) return NO;
		peer.name = name;
		[self markPeerAsAvailable:peer];
	} else if([cmd isEqual:@"disconnected"]) {
		[self markPeerAsUnavailable:peer forReason:[NSError errorWithDomain:MeshPipeErrorDomain code:MeshPipeErrorPeerDisconnected userInfo:@{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ disconnected", peer.name],
		}]];
	} else if([cmd isEqual:@"youTimedOut"]) {
		[self announceTo:peer];
	} else if([cmd isEqual:@"keepalive"]) {
		[peer.expectKeepaliveTimer invalidate];
		peer.expectKeepaliveTimer = [NSTimer scheduledTimerWithTimeInterval:kKeepaliveExpectedWithin target:self selector:@selector(keepaliveExpected:) userInfo:peer repeats:YES];
	} else {
		MPDebug(@"Unexpected internal command %@", internal);
		return NO;
	}
	return YES;
}

- (void)markPeerAsAvailable:(MeshPipePeer*)peer
{
	if(![_peers containsObject:peer]) {
		MPDebug(@"Peer is now available: %@", peer);
		peer.expectKeepaliveTimer = [NSTimer scheduledTimerWithTimeInterval:kKeepaliveExpectedWithin target:self selector:@selector(keepaliveExpected:) userInfo:peer repeats:YES];
		[self willChangeValueForKey:@"peers"];
		[_peers addObject:peer];
		[self didChangeValueForKey:@"peers"];
		if([self.delegate respondsToSelector:@selector(meshPipe:acceptedNewPeer:)])
			[self.delegate meshPipe:self acceptedNewPeer:peer];
	}
}

- (void)markPeerAsUnavailable:(MeshPipePeer*)peer forReason:(NSError*)error
{
	if([_peers containsObject:peer]) {
		MPDebug(@"Peer is now unavailable: %@: reason %@", peer, error);
		[peer.expectKeepaliveTimer invalidate]; peer.expectKeepaliveTimer = nil;
		[self willChangeValueForKey:@"peers"];
		[_peers removeObject:peer];
		[self didChangeValueForKey:@"peers"];
		if([self.delegate respondsToSelector:@selector(meshPipe:lostPeer:withError:)])
			[self.delegate meshPipe:self lostPeer:peer withError:error];
	}
	peer.name = @"Unavailable";

}
@end

@implementation MeshPipePeer
- (instancetype)init
{
	if(!(self = [super init]))
		return nil;
	self.name = @"Unavailable";
	return self;
}

- (void)_send:(NSData*)data asType:(_MeshPipeMessageType)type
{
	NSMutableData *send = [NSMutableData dataWithCapacity:data.length + 1];
	[send appendBytes:&type length:1];
	[send appendData:data];
	
	// Send through the listenSocket so that the sending port is correct
	[self.parent.listenSocket sendData:send toHost:@"localhost" port:self.port withTimeout:-1 tag:0];
}

- (void)sendData:(NSData*)data
{
	[self _send:data asType:_MeshPipeMessageTypeData];
}
- (void)sendInternal:(NSDictionary *)internal
{
	MPDebug(@"%@ sending internal: %@", self, internal);
	[self _send:SerializeInternal(internal) asType:_MeshPipeMessageTypeInternal];
}
- (NSString*)description
{
	return [NSString stringWithFormat:@"<%@@%p: %d %@>", [self class], self, self.port, self.name];
}
@end

@implementation MeshPipeSelfPeer
- (void)_send:(NSData*)data asType:(_MeshPipeMessageType)type
{
	MPDebug(@"Not sending to self");
}

@end

static NSData *SerializeInternal(NSDictionary *internal)
{
	NSError *err;
	NSData *d = [NSJSONSerialization dataWithJSONObject:internal options:0 error:&err];
	if(!d) {
		NSCAssert(d != nil, @"Couldn't serialize: %@", err);
		return nil;
	}
	return d; // [d gzippedData]; gzipped data is bigger!
}

static NSDictionary *DeserializeInternal(NSData *data)
{
	//NSData *unzipped = [data gunzippedData];
	NSError *err;
	id ret = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
	if(!ret) {
		MPDebug(@"Unable to deserialize: %@ %@", data, err);
		return nil;
	}
	return ret;
}

NSString *const MeshPipeErrorDomain = @"eu.thirdcog.meshpipe";
