#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBXImportedCamera : NSObject
@property (nonatomic, copy) NSString *name;

// World-space camera pose
@property (nonatomic) simd_float3 position;
@property (nonatomic) simd_float3 forward;   // direction camera looks towards (world), normalized

// Lens
@property (nonatomic) float fovYDegrees;     // vertical FOV in degrees (for fallback)
@property (nonatomic) float fovHDegrees;     // horizontal FOV in degrees (preferred)
@property (nonatomic) float nearPlane;
@property (nonatomic) float farPlane;

// Optional lens metadata (may be 0 if not available)
@property (nonatomic) float focalLengthMm;
@property (nonatomic) float sensorWidthMm;
@property (nonatomic) float sensorHeightMm;

@end

NS_ASSUME_NONNULL_END
