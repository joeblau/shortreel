#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface USBPhoneSnapshot : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSString *productType;
@property (nonatomic, copy, readonly, nullable) NSString *bluetoothAddress;
@property (nonatomic, readonly) BOOL paired;
@property (nonatomic, readonly) BOOL trusted;
@property (nonatomic, strong, readonly, nullable) NSNumber *assistiveTouchEnabled;
@property (nonatomic, copy, readonly, nullable) NSString *statusMessage;
@end

@interface USBPhoneBridge : NSObject
- (void)fetchConnectedPhonesWithCompletion:(void (^)(NSArray<USBPhoneSnapshot *> *phones, NSError * _Nullable error))completion;

- (void)requestTrustForIdentifier:(NSString *)identifier
                     completion:(void (^)(USBPhoneSnapshot * _Nullable phone, NSError * _Nullable error))completion;

- (void)preparePhoneWithIdentifier:(NSString *)identifier
                      completion:(void (^)(USBPhoneSnapshot * _Nullable phone, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
