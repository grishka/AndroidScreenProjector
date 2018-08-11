//
//  SPADBWrapper.h
//  ScreenProjectorClient
//
//  Created by Grishka on 14.10.2017.
//  Copyright © 2017 Grishka. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SPDevice : NSObject

@property (retain) NSString* serial;
@property (retain) NSString* name;
@property (retain) NSString* androidVersion;
@property int apiLevel;

@end

@protocol SPADBDelegate

- (void)adbCommand: (NSString*)cmd onDeviceWithSerial: (NSString*)serial didFailWithError: (NSString*)error;
- (void)adbDeviceAdded: (SPDevice*)device;
- (void)adbDeviceRemoved: (SPDevice*)device;

@end

@interface SPADBWrapper : NSObject

- (void)listConnectedDevicesWithCompletionBlock: (void (^)(NSArray<SPDevice*>*))completion;
- (void)runShellCommand: (NSString*)cmd onDeviceWithSerial: (NSString*)serial completion: (void (^)(NSString*))completion;
- (void)connectToTcpPort: (uint16_t)port onDeviceWithSerial: (NSString*)serial completion: (void (^)(int))completion;
- (void)forwardTcpPort: (uint16_t)port onDeviceWithSerial: (NSString*)serial toHostPort: (uint16_t)hport completion: (void (^)())completion;
- (void)connectToTcpPortOnLocalHost: (uint16_t)port completion: (void (^)(int))completion;
- (void)setDelegate: (id)delegate;
- (void)startTrackingDevices;
- (void)stopTrackingDevices;
- (void)pushFileFromLocalPath: (NSString*)localPath toRemotePath: (NSString*)remotePath onDeviceWithSerial: (NSString*)serial completion: (void (^)())completion;

@end
