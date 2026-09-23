#import "CBClassicDiscovery.h"
#import <CoreBluetooth/CoreBluetooth.h>

@interface CBClassicManager : CBManager
- (instancetype)initWithQueue:(dispatch_queue_t)queue options:(NSDictionary *)options;
- (void)startInquiryWithOptions:(NSDictionary *)options classicPeerDiscovered:(void (^)(id, id, NSDictionary *))callback;
- (void)stopInquiry;
- (void)setClassicPeerDiscovered:(id)callback;
@property (nonatomic, readonly) BOOL inquiryState;
@end
@interface CBClassicPeer : CBPeer
@property (nonatomic, readonly) NSString *addressString;
@property (nonatomic, readonly) NSString *name;
@end

@implementation CBClassicDiscovery {
    CBClassicManager *_manager;
    BOOL _started;
    BOOL _stopping;
    BOOL _finished;
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"Discovery uses the main run loop");
    if (_manager) return;
    Class managerClass = NSClassFromString(@"CBClassicManager");
    if (!managerClass || ![managerClass instancesRespondToSelector:@selector(startInquiryWithOptions:classicPeerDiscovered:)]) {
        if (self.onError) self.onError(@"Classic Bluetooth discovery is unavailable on this macOS version.");
        return;
    }
    _manager = [[managerClass alloc] initWithQueue:dispatch_get_main_queue() options:nil];
    [_manager addObserver:self forKeyPath:@"state" options:0 context:NULL];
    [_manager addObserver:self forKeyPath:@"inquiryState" options:0 context:NULL];
    [self startWhenReady];
}

- (void)startWhenReady {
    if (_started || _stopping || !_manager) return;
    if (_manager.state == CBManagerStatePoweredOn) {
        _started = YES;
        __weak CBClassicDiscovery *weakSelf = self;
        [_manager startInquiryWithOptions:@{@"kCBInquiryLength": @12,
                                            @"kCBInquiryInfinite": @YES,
                                            @"kCBInquiryReportDuplicates": @YES}
                    classicPeerDiscovered:^(id manager, CBClassicPeer *peer, NSDictionary *info) {
            CBClassicDiscovery *owner = weakSelf;
            if (!owner || owner->_stopping || owner->_finished) return;
            if (peer.addressString.length && owner.onDeviceFound) {
                owner.onDeviceFound(peer.addressString, peer.name ?: @"Unnamed device");
            }
        }];
    } else if (_manager.state == CBManagerStateUnsupported || _manager.state == CBManagerStateUnauthorized) {
        if (self.onError) self.onError(@"Bluetooth discovery is unavailable or permission was denied.");
    }
}

- (void)stop {
    if (_stopping || _finished) return;
    _stopping = YES;
    [_manager setClassicPeerDiscovered:nil];
    if (_started) [_manager stopInquiry];
    if (!_manager.inquiryState) [self finish];
    __weak CBClassicDiscovery *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        CBClassicDiscovery *owner = weakSelf;
        if (owner && !owner->_finished) {
            owner->_finished = YES;
            if (owner.onError) owner.onError(@"Bluetooth scanning did not stop. Please try again.");
        }
    });
}

- (void)finish {
    if (_finished) return;
    _finished = YES;
    if (self.onFinished) self.onFinished();
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object != _manager) return;
    if ([keyPath isEqualToString:@"state"]) [self startWhenReady];
    if ([keyPath isEqualToString:@"inquiryState"] && _stopping && !_manager.inquiryState) [self finish];
}

- (void)dealloc {
    [_manager removeObserver:self forKeyPath:@"state"];
    [_manager removeObserver:self forKeyPath:@"inquiryState"];
    [_manager setClassicPeerDiscovered:nil];
    if (_started && !_stopping) [_manager stopInquiry];
}
@end
