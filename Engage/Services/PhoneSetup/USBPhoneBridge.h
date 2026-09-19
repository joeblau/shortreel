#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Information read from an attached iPhone through Apple's USB lockdown service.
@interface USBPhoneSnapshot : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSString *productType;
@property (nonatomic, copy, readonly, nullable) NSString *bluetoothAddress;
@property (nonatomic, readonly) BOOL paired;
/// YES only after this Mac's pairing record validates and a session opens.
@property (nonatomic, readonly) BOOL trusted;
@property (nonatomic, strong, readonly, nullable) NSNumber *assistiveTouchEnabled;
@property (nonatomic, copy, readonly, nullable) NSString *statusMessage;
@end

/// All USB work is serialized. Every completion runs on the main queue.
@interface USBPhoneBridge : NSObject
- (void)fetchConnectedPhonesWithCompletion:(void (^)(NSArray<USBPhoneSnapshot *> *phones, NSError * _Nullable error))completion;

/// Requests iOS's normal Trust This Computer flow for this specific attached phone.
/// Pending trust is returned as an error with instructions; callers may refresh/retry.
- (void)requestTrustForIdentifier:(NSString *)identifier
                     completion:(void (^)(USBPhoneSnapshot * _Nullable phone, NSError * _Nullable error))completion;

/// Enables AssistiveTouch on the selected, trusted phone and verifies the value.
/// Never pairs, changes trust, or enables settings on another phone.
- (void)preparePhoneWithIdentifier:(NSString *)identifier
                      completion:(void (^)(USBPhoneSnapshot * _Nullable phone, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
