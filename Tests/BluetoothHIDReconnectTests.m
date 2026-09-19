#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <unistd.h>
#import "../Engage/Services/BluetoothHID/CBHIDBridge.m"

// No CoreBluetooth manager or IOBluetooth device is created in this test.
// Real socket pairs exercise the bridge's channel readiness checks.
static void check(BOOL passed, NSString *reason) {
    if (!passed) { NSLog(@"FAIL: %@", reason); exit(1); }
}

@interface ReconnectPeer : NSObject
@property NSString *addressString;
@property NSString *name;
@property NSInteger state;
@property NSMutableDictionary<NSNumber *, id> *channels;
@property NSMutableArray<NSNumber *> *opens;
@property NSMutableArray<NSNumber *> *closes;
@property (copy) void (^connectL2CAPCallback)(id, long);
@property (copy) void (^disconnectL2CAPCallback)(id, long);
- (id)channelWithPSM:(unsigned short)psm;
- (void)openL2CAPChannel:(unsigned short)psm;
- (void)closeL2CAPChannel:(unsigned short)psm;
@end
@implementation ReconnectPeer
- (id)init {
    if ((self = [super init])) {
        _addressString = @"80:B9:89:32:E0:28";
        _name = @"Test phone";
        _channels = [NSMutableDictionary dictionary];
        _opens = [NSMutableArray array];
        _closes = [NSMutableArray array];
    }
    return self;
}
- (id)channelWithPSM:(unsigned short)psm { return _channels[@(psm)]; }
- (void)openL2CAPChannel:(unsigned short)psm { [_opens addObject:@(psm)]; }
- (void)closeL2CAPChannel:(unsigned short)psm { [_closes addObject:@(psm)]; }
@end

@interface ReconnectManager : NSObject
@property NSInteger state;
@property ReconnectPeer *peer;
@property NSUInteger retrievals;
@property NSUInteger connections;
@property NSString *requestedAddress;
@property NSDictionary *connectionOptions;
- (id)retrievePeerWithAddress:(NSString *)address;
- (void)connectPeer:(ReconnectPeer *)peer options:(NSDictionary *)options;
@end
@implementation ReconnectManager
- (id)retrievePeerWithAddress:(NSString *)address { _retrievals++; _requestedAddress = address; return _peer; }
- (void)connectPeer:(ReconnectPeer *)peer options:(NSDictionary *)options {
    check(peer == _peer, @"only the retrieved peer is connected");
    _connections++; _connectionOptions = options; peer.state = 1;
}
@end

@interface ReconnectChannel : NSObject
@property unsigned short PSM;
@property unsigned short outgoingMTU;
@property int socketFD;
@property int otherFD;
@property (weak) ReconnectPeer *peer;
@end
@implementation ReconnectChannel
- (id)init {
    if ((self = [super init])) { _socketFD = -1; _otherFD = -1; _outgoingMTU = 64; }
    return self;
}
- (void)dealloc { if (_socketFD >= 0) close(_socketFD); if (_otherFD >= 0) close(_otherFD); }
@end

@interface ReconnectBridge : CBHIDBridge
@property BOOL bonded;
@property NSUInteger bondChecks;
@property NSMutableArray<NSError *> *failures;
@property NSMutableArray<CBHIDPeerState *> *states;
@end
@implementation ReconnectBridge
- (BOOL)isBondedAddress:(NSString *)address { _bondChecks++; return _bonded; }
@end

@interface ReconnectFixture : NSObject
@property ReconnectBridge *bridge;
@property ReconnectManager *manager;
@property ReconnectPeer *peer;
@property dispatch_queue_t queue;
- (void)flush;
- (void)request;
- (void)connected;
- (ReconnectChannel *)channel:(unsigned short)psm validSocket:(BOOL)valid;
- (void)opened:(ReconnectChannel *)channel;
- (NSUInteger)pendingCount;
@end
@implementation ReconnectFixture
- (id)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("engage.reconnect.test", DISPATCH_QUEUE_SERIAL);
        _bridge = [ReconnectBridge new]; _bridge.bonded = YES;
        _bridge.failures = [NSMutableArray array]; _bridge.states = [NSMutableArray array];
        _peer = [ReconnectPeer new]; _manager = [ReconnectManager new];
        _manager.state = CBManagerStatePoweredOn; _manager.peer = _peer;
        [_bridge setValue:_queue forKey:@"queue"];
        [_bridge setValue:_manager forKey:@"manager"];
        [_bridge setValue:[NSMutableDictionary dictionary] forKey:@"entries"];
        [_bridge setValue:[NSMutableDictionary dictionary] forKey:@"connectionRequests"];
        [_bridge setValue:@YES forKey:@"published"];
        dispatch_queue_set_specific(_queue, CBHIDBridgeQueueKey, (__bridge void *)_bridge, NULL);
        __weak ReconnectBridge *weakBridge = _bridge;
        _bridge.onConnectionFailed = ^(NSString *address, NSError *error) {
            check([address isEqualToString:@"80b98932e028"], @"failure keeps the requested address");
            [weakBridge.failures addObject:error];
        };
        _bridge.onPeerChannelsChanged = ^(CBHIDPeerState *state) { [weakBridge.states addObject:state]; };
    }
    return self;
}
- (void)flush { dispatch_sync(_queue, ^{}); }
- (void)request { [_bridge requestConnectionToPeerWithAddress:@"80-b9-89-32-e0-28"]; [self flush]; }
- (void)connected {
    dispatch_sync(_queue, ^{ self.peer.state = 2; [self.bridge handlePeerConnected:(id)self.peer errorCode:0]; });
}
- (ReconnectChannel *)channel:(unsigned short)psm validSocket:(BOOL)valid {
    ReconnectChannel *channel = [ReconnectChannel new]; channel.PSM = psm; channel.peer = _peer;
    if (valid) {
        int pair[2]; check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, @"socket pair created");
        channel.socketFD = pair[0]; channel.otherFD = pair[1];
    }
    _peer.channels[@(psm)] = channel;
    return channel;
}
- (void)opened:(ReconnectChannel *)channel {
    dispatch_sync(_queue, ^{ self.peer.connectL2CAPCallback(channel, 0); });
}
- (NSUInteger)pendingCount { return [(NSDictionary *)[_bridge valueForKey:@"connectionRequests"] count]; }
- (void)dealloc {
    // Teardown only our socket adapters. Do not call the production stop path,
    // which correctly expects a real manager with its KVO observation installed.
    for (CBHIDPeerEntry *entry in [(NSDictionary *)[_bridge valueForKey:@"entries"] allValues]) {
        [entry.controlSocket close]; [entry.interruptSocket close];
    }
}
@end

int main(void) { @autoreleasepool {
    check([CBHIDExactAddress(@"80:B9:89:32:E0:28") isEqualToString:@"80b98932e028"], @"canonical address");
    check(CBHIDExactAddress(@"pending-80:B9:89:32:E0:28") == nil, @"placeholder cannot become another address");
    check(CBHIDExactAddress(@"80:B9:89:32:E0:2Z") == nil, @"nonhex address rejected");
    check(CBHIDExactAddress(@"80:B9:89") == nil, @"short address rejected");

    ReconnectFixture *ordered = [ReconnectFixture new];
    [ordered.bridge setValue:@NO forKey:@"published"];
    [ordered request];
    check(ordered.manager.retrievals == 0, @"request waits for service publication");
    dispatch_sync(ordered.queue, ^{
        [ordered.bridge setValue:@YES forKey:@"published"];
        [ordered.bridge startConnectionRequestsWhenReady];
    });
    check(ordered.manager.connections == 1 && [ordered.manager.connectionOptions isEqual:@{}], @"one ACL request with nonnil options");
    check([ordered.manager.requestedAddress isEqualToString:@"80:B9:89:32:E0:28"], @"only the exact formatted address is retrieved");
    check(ordered.peer.opens.count == 0, @"no L2CAP before connected callback");
    [ordered connected]; [ordered request];
    check([ordered.peer.opens isEqual:@[@17]] && ordered.manager.connections == 1, @"control requested once before interrupt");
    [ordered opened:[ordered channel:17 validSocket:YES]];
    check([ordered.peer.opens isEqual:@[@17,@19]], @"interrupt requested after usable control socket");
    check(ordered.bridge.connectedPeerAddresses.count == 0, @"control alone is not connected");
    [ordered opened:[ordered channel:19 validSocket:YES]];
    check([ordered.bridge.connectedPeerAddresses isEqual:@[@"80b98932e028"]] && ordered.pendingCount == 0, @"both channels complete the attempt");
    [ordered request];
    check(ordered.peer.opens.count == 2 && ordered.manager.connections == 1, @"ready device is reused");

    ReconnectFixture *incoming = [ReconnectFixture new]; incoming.peer.state = 2;
    [incoming channel:17 validSocket:YES]; [incoming channel:19 validSocket:YES];
    [incoming request];
    check(incoming.manager.connections == 0 && incoming.peer.opens.count == 0, @"incoming channels are adopted without duplicate opens");
    check(incoming.bridge.connectedPeerAddresses.count == 1 && incoming.pendingCount == 0, @"adopted socket pair is ready");

    ReconnectFixture *cancelled = [ReconnectFixture new]; [cancelled request]; [cancelled connected];
    [cancelled.bridge cancelConnectionRequestWithAddress:@"80b98932e028"]; [cancelled flush];
    check(cancelled.pendingCount == 0 && [cancelled.peer.closes isEqual:@[@17]], @"timeout cancels only its requested control channel");
    [cancelled opened:[cancelled channel:17 validSocket:YES]];
    check([cancelled.peer.opens isEqual:@[@17]], @"late control callback cannot initiate interrupt after cancellation");

    ReconnectFixture *unbonded = [ReconnectFixture new]; unbonded.bridge.bonded = NO; [unbonded request];
    check(unbonded.manager.retrievals == 0 && unbonded.bridge.failures.count == 1 && unbonded.pendingCount == 0, @"unbonded phone fails without connecting or pairing");
    ReconnectFixture *mismatch = [ReconnectFixture new]; mismatch.peer.addressString = @"00:11:22:33:44:55"; [mismatch request];
    check(mismatch.manager.connections == 0 && mismatch.bridge.failures.count == 1, @"lookup cannot silently substitute another phone");

    ReconnectFixture *nilFailure = [ReconnectFixture new]; [nilFailure request]; [nilFailure connected];
    dispatch_sync(nilFailure.queue, ^{ nilFailure.peer.connectL2CAPCallback(nil, 5); nilFailure.peer.connectL2CAPCallback(nil, 5); });
    check(nilFailure.bridge.failures.count == 1 && nilFailure.pendingCount == 0, @"nil-channel error completes a request exactly once");
    ReconnectFixture *connectFailure = [ReconnectFixture new]; [connectFailure request];
    dispatch_sync(connectFailure.queue, ^{ [connectFailure.bridge handlePeerConnected:(id)connectFailure.peer errorCode:6]; });
    check(connectFailure.bridge.failures.count == 1 && connectFailure.pendingCount == 0 && connectFailure.peer.opens.count == 0, @"ACL failure never opens HID channels");

    ReconnectFixture *badSocket = [ReconnectFixture new]; badSocket.peer.state = 2;
    [badSocket channel:17 validSocket:NO]; [badSocket request];
    check(badSocket.bridge.failures.count == 1 && badSocket.pendingCount == 0 && badSocket.peer.opens.count == 0, @"existing invalid socket fails without recursion or interrupt open");
    NSLog(@"PASS: exact bonded lookup, queued readiness, ordered channels, incoming reuse, cancellation, callback failures, and invalid socket handling");
}}
