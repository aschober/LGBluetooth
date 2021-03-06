// The MIT License (MIT)
//
// Created by : l0gg3r
// Copyright (c) 2014 l0gg3r. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "LGCentralManager.h"

#if TARGET_OS_IPHONE
#import <CoreBluetooth/CoreBluetooth.h>
#elif TARGET_OS_MAC
#import <IOBluetooth/IOBluetooth.h>
#endif
#import "LGPeripheral.h"
#import "LGUtils.h"

@interface LGCentralManager() <CBCentralManagerDelegate>

/**
 * Ongoing operations
 */
@property (strong, atomic) NSMutableDictionary *operations;

/**
 * CBCentralManager's dispatch queue
 */
@property (strong, nonatomic) dispatch_queue_t centralQueue;

/**
 * List of scanned peripherals
 */
@property (strong, nonatomic) NSMutableArray *scannedPeripherals;

/**
 * Completion block for starting central manager
 */
@property (copy, nonatomic) LGCentralManagerStartCallback startBlock;

/**
 * Completion block for peripheral scanning after interval
 */
@property (copy, nonatomic) LGCentralManagerDiscoverPeripheralsAfterIntervalCallback scanBlock;

/**
 * Completion block for peripheral scanning
 */
@property (copy, nonatomic) LGCentralManagerDiscoveredPeripheralCallback discoverBlock;

/**
 * Completion block for peripheral incremental scanning
 */
@property (copy, nonatomic) LGCentralManagerDiscoverPeripheralsChangesCallback changesBlock;

/**
 * CBCentralManager's state updated by centralManagerDidUpdateState:
 */
@property(nonatomic) CBCentralManagerState cbCentralManagerState;

@end

@implementation LGCentralManager

/*----------------------------------------------------*/
#pragma mark - Getter/Setter -
/*----------------------------------------------------*/

- (BOOL)isCentralReady
{
    return (self.manager.state == CBCentralManagerStatePoweredOn);
}

- (NSString *)centralNotReadyReason
{
    return [self stateMessage];
}

- (NSArray *)peripherals
{
    // Sorting LGPeripherals by RSSI values
    NSArray *sortedArray;
    sortedArray = [_scannedPeripherals sortedArrayUsingComparator:^NSComparisonResult(LGPeripheral *a, LGPeripheral *b) {
        return a.RSSI < b.RSSI;
    }];
    return sortedArray;
}

/*----------------------------------------------------*/
#pragma mark - KVO -
/*----------------------------------------------------*/

+ (NSSet *)keyPathsForValuesAffectingCentralReady
{
    return [NSSet setWithObject:@"cbCentralManagerState"];
}

+ (NSSet *)keyPathsForValuesAffectingCentralNotReadyReason
{
    return [NSSet setWithObject:@"cbCentralManagerState"];
}

/*----------------------------------------------------*/
#pragma mark - Public Methods -
/*----------------------------------------------------*/

- (void)startCentralManagerCompletion:(LGCentralManagerStartCallback)aCallback
{
    if(_manager && _manager.state == CBCentralManagerStatePoweredOn) {
        aCallback(nil);
        return;
    }
    
    self.startBlock = aCallback;
    _manager = [[CBCentralManager alloc] initWithDelegate:self
                                                    queue:self.centralQueue
                                                  options:@{CBCentralManagerOptionRestoreIdentifierKey:@"centralManagerIdentifier",
                                                            CBCentralManagerOptionShowPowerAlertKey:[NSNumber numberWithBool:YES]}];
    _cbCentralManagerState = _manager.state;
}

- (void)scanForPeripheralsWithChanges:(LGCentralManagerDiscoverPeripheralsChangesCallback)aChangesCallback
{
    self.changesBlock = aChangesCallback;
    [self scanForPeripherals];
}

- (void)scanForPeripherals
{
    [self scanForPeripheralsWithServices:nil
                                 options:@{CBCentralManagerScanOptionAllowDuplicatesKey : @YES}];
}

- (void)stopScanForPeripherals
{
    self.scanning = NO;
	[self.manager stopScan];
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(stopScanForPeripherals)
                                               object:nil];
    if (self.scanBlock) {
        self.scanBlock(self.peripherals, nil);
    }
    self.scanBlock = nil;
	self.changesBlock = nil;
    self.discoverBlock = nil;
}

- (void)scanForPeripheralsWithServices:(NSArray *)serviceUUIDs
                               options:(NSDictionary *)options
{
    if(self.manager.state != CBCentralManagerStatePoweredOn) {
        LGLog(@"Error scanning for peripherals! CBCentralManager not PoweredOn");
        if(self.scanBlock) {
            NSError *error = [NSError errorWithDomain:kLGUtilsCentralManagerErrorDomain
                                                 code:kLGUtilsCentralManagerStartErrorCode
                                             userInfo:@{kLGErrorMessageKey : [self stateMessage]}];
            self.scanBlock(nil, error);
            self.scanBlock = nil;
        }
    }
    
    [self.scannedPeripherals removeAllObjects];
    self.scanning = YES;
	[self.manager scanForPeripheralsWithServices:serviceUUIDs
                                         options:options];
}

- (void)scanForPeripheralsWithServices:(NSArray *)serviceUUIDs
                               options:(NSDictionary *)options
                      discoveredDevice:(LGCentralManagerDiscoveredPeripheralCallback)aCallback
{
    self.discoverBlock = aCallback;

    if(self.manager.state != CBCentralManagerStatePoweredOn) {
        LGLog(@"Error scanning for peripherals! CBCentralManager not PoweredOn");
        if(self.scanBlock) {
            NSError *error = [NSError errorWithDomain:kLGUtilsCentralManagerErrorDomain
                                                 code:kLGUtilsCentralManagerStartErrorCode
                                             userInfo:@{kLGErrorMessageKey : [self stateMessage]}];
            self.discoverBlock(nil, error);
            self.discoverBlock = nil;
        }
    }

    [self.scannedPeripherals removeAllObjects];
    self.scanning = YES;
	[self.manager scanForPeripheralsWithServices:serviceUUIDs
                                         options:options];
}

- (void)scanForPeripheralsByInterval:(NSUInteger)aScanInterval
                             changes:(LGCentralManagerDiscoverPeripheralsChangesCallback)aChangesCallback
                          completion:(LGCentralManagerDiscoverPeripheralsAfterIntervalCallback)aCallback
{
    self.changesBlock = aChangesCallback;
    [self scanForPeripheralsByInterval:aScanInterval
                            completion:aCallback];
}

- (void)scanForPeripheralsByInterval:(NSUInteger)aScanInterval
                          completion:(LGCentralManagerDiscoverPeripheralsAfterIntervalCallback)aCallback
{
    [self scanForPeripheralsByInterval:aScanInterval
                              services:nil
                               options:@{CBCentralManagerScanOptionAllowDuplicatesKey : @YES}
                            completion:aCallback];
}

- (void)scanForPeripheralsByInterval:(NSUInteger)aScanInterval
                            services:(NSArray *)serviceUUIDs
                             options:(NSDictionary *)options
                          completion:(LGCentralManagerDiscoverPeripheralsAfterIntervalCallback)aCallback
{
    self.scanBlock = aCallback;
    [self scanForPeripheralsWithServices:serviceUUIDs
                                 options:options];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(stopScanForPeripherals)
                                               object:nil];
    [self performSelector:@selector(stopScanForPeripherals)
               withObject:nil
               afterDelay:aScanInterval];
}

- (NSArray *)retrievePeripheralsWithIdentifiers:(NSArray *)identifiers
{
    // iOS7 Check
    if([CBCentralManager instancesRespondToSelector:@selector(retrievePeripheralsWithIdentifiers:)]){
        // translate array of nsstring identifiers to NSUUID identifiers
        NSMutableArray *nsuuidIdentifiers = [NSMutableArray arrayWithCapacity:identifiers.count];
        for(NSString *stringIdentifier in identifiers) {
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:stringIdentifier];
            [nsuuidIdentifiers addObject:uuid];
        }
        return [self wrappersByPeripherals:[self.manager retrievePeripheralsWithIdentifiers:nsuuidIdentifiers]];
    } else {
        return nil;
    }
}

- (NSArray *)retrieveConnectedPeripheralsWithServices:(NSArray *)serviceUUIDS
{
    return [self wrappersByPeripherals:[self.manager retrieveConnectedPeripheralsWithServices:serviceUUIDS]];
}

/*----------------------------------------------------*/
#pragma mark - Private Methods -
/*----------------------------------------------------*/

- (NSString *)stateMessage
{
	NSString *message = nil;
	switch (self.manager.state) {
		case CBCentralManagerStateUnsupported:
			message = @"The platform/hardware doesn't support Bluetooth Low Energy.";
			break;
		case CBCentralManagerStateUnauthorized:
			message = @"The app is not authorized to use Bluetooth Low Energy.";
			break;
        case CBCentralManagerStateUnknown:
            message = @"Central not initialized yet.";
            break;
		case CBCentralManagerStatePoweredOff:
			message = @"Bluetooth is currently powered off.";
			break;
		case CBCentralManagerStatePoweredOn:
            break;
		default:
			break;
	}
	return message;
}

- (LGPeripheral *)wrapperByPeripheral:(CBPeripheral *)aPeripheral
{
    LGPeripheral *wrapper = nil;
    for (LGPeripheral *scanned in self.scannedPeripherals) {
        if (scanned.cbPeripheral == aPeripheral) {
            wrapper = scanned;
            break;
        }
    }
    if (!wrapper) {
        wrapper = [[LGPeripheral alloc] initWithPeripheral:aPeripheral manager:self];
        [self.scannedPeripherals addObject:wrapper];
    }
    return wrapper;
}

- (NSArray *)wrappersByPeripherals:(NSArray *)peripherals
{
    NSMutableArray *lgPeripherals = [NSMutableArray new];
    
    for (CBPeripheral *peripheral in peripherals) {
        [lgPeripherals addObject:[self wrapperByPeripheral:peripheral]];
    }
    return lgPeripherals;
}

//-------------------------------------------------------------------------//
#pragma mark - Central Manager Delegate
//-------------------------------------------------------------------------//

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self wrapperByPeripheral:peripheral] handleConnectionWithError:nil];
    });
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self wrapperByPeripheral:peripheral] handleConnectionWithError:error];
    });
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        LGPeripheral *lgPeripheral = [self wrapperByPeripheral:peripheral];
        [lgPeripheral handleDisconnectWithError:error];
        [self.scannedPeripherals removeObject:lgPeripheral];
    });
}

- (void)centralManager:(CBCentralManager *)central willRestoreState:(NSDictionary *)state {
    LGLog(@"centralManager:willRestoreState:");
    
    NSArray *peripherals = state[CBCentralManagerRestoredStatePeripheralsKey];
    
    //TODO: test restoring peripherals to see what state they are in...
    for(CBPeripheral *peripheral in peripherals) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[self wrapperByPeripheral:peripheral] handleConnectionWithError:nil];
        });
    }
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    LGLog(@"centralManagerDidUpdateState:");
    self.cbCentralManagerState = central.state;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(self.startBlock) {
            if(self.manager.state == CBCentralManagerStatePoweredOn) {
                self.startBlock(nil);
            }
            else {
                // error starting Central Manager
                NSError *error = [NSError errorWithDomain:kLGUtilsCentralManagerErrorDomain
                                                     code:kLGUtilsCentralManagerStartErrorCode
                                                 userInfo:@{kLGErrorMessageKey : [self stateMessage]}];
                self.startBlock(error);
            }
            self.startBlock = nil;
        }
        
        NSString *message = [self stateMessage];
        if (message) {
            LGLogError(@"%@", message);
        }
    });
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary *)advertisementData
                  RSSI:(NSNumber *)RSSI
{
    dispatch_async(dispatch_get_main_queue(), ^{
        LGPeripheral *lgPeripheral = [self wrapperByPeripheral:peripheral];
        if (!lgPeripheral.RSSI) {
            lgPeripheral.RSSI = [RSSI integerValue];
        } else {
            // Calculating AVG RSSI
            lgPeripheral.RSSI = (lgPeripheral.RSSI + [RSSI integerValue]) / 2;
        }
        lgPeripheral.advertisingData = advertisementData;
        
        if (self.changesBlock != nil) {
            self.changesBlock(lgPeripheral);
        }
        
        if ([self.scannedPeripherals count] >= self.peripheralsCountToStop) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(stopScanForPeripherals)
                                                       object:nil];
            [self stopScanForPeripherals];
        }
        if(self.discoverBlock) {
            self.discoverBlock(lgPeripheral, nil);
        }
    });
}

/*----------------------------------------------------*/
#pragma mark - LifeCycle -
/*----------------------------------------------------*/

static LGCentralManager *sharedInstance = nil;

+ (LGCentralManager *)sharedInstance
{
    // Thread blocking to be sure for singleton instance
	@synchronized(self) {
		if (!sharedInstance) {
			sharedInstance = [LGCentralManager new];
		}
	}
	return sharedInstance;
}

- (id)init
{
	self = [super init];
	if (self) {
        _centralQueue = dispatch_queue_create("com.LGBluetooth.LGCentralQueue", DISPATCH_QUEUE_SERIAL);
        _scannedPeripherals = [NSMutableArray new];
        _peripheralsCountToStop = NSUIntegerMax;
	}
	return self;
}

@end
