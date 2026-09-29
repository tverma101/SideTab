//
//  CGVirtualDisplayBridge.h
//  Virtual Display Bridge for Private CoreGraphics API
//

#ifndef CGVirtualDisplayBridge_h
#define CGVirtualDisplayBridge_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Forward declarations for CGVirtualDisplay private API

@class CGVirtualDisplay;

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, assign) uint32_t vendorID;
@property (nonatomic, assign) uint32_t productID;
@property (nonatomic, assign) uint32_t serialNum;
@property (nonatomic, retain) NSString *name;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) uint32_t maxPixelsWide;
@property (nonatomic, assign) uint32_t maxPixelsHigh;
@property (nonatomic, assign) CGPoint redPrimary;
@property (nonatomic, assign) CGPoint greenPrimary;
@property (nonatomic, assign) CGPoint bluePrimary;
@property (nonatomic, assign) CGPoint whitePoint;
@property (nonatomic, retain, nullable) dispatch_queue_t queue;
// The real block takes the display: void (^)(id, CGVirtualDisplay *) — both
// parameters encode as an object pointer, and an ObjC block parameter of an
// interface type is always spelled as a pointer. Leave this UNSET. Two reasons:
// (1) the property's type encoding is opaque, so a wrong signature cannot be
// caught at compile time and only crashes at call time; (2) measured on
// macOS 26, installing a handler crashes when the window server invokes it
// during process exit. Nothing in SideScreen needs it — the manager observes
// NSApplication.didChangeScreenParametersNotification instead.
@property (nonatomic, copy, nullable) void (^terminationHandler)(id, CGVirtualDisplay *);

- (instancetype)init;
@end

@interface CGVirtualDisplayMode : NSObject
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) double refreshRate;

- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, assign) uint32_t hiDPI;
@property (nonatomic, retain) NSArray<CGVirtualDisplayMode *> *modes;

- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) uint32_t vendorID;
@property (nonatomic, readonly) uint32_t productID;
@property (nonatomic, readonly) uint32_t serialNum;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) CGSize sizeInMillimeters;
@property (nonatomic, readonly) uint32_t maxPixelsWide;
@property (nonatomic, readonly) uint32_t maxPixelsHigh;
@property (nonatomic, readonly) uint32_t hiDPI;
@property (nonatomic, readonly) NSArray<CGVirtualDisplayMode *> *modes;

- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END

#endif /* CGVirtualDisplayBridge_h */
