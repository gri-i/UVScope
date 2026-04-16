#import <Foundation/Foundation.h>

@class FBXImportedCamera;
@class FBXImportedScene;

NS_ASSUME_NONNULL_BEGIN

@interface FBXSceneImporter : NSObject

/// Existing cameras-only API (kept for compatibility)
+ (NSArray<FBXImportedCamera *> *)loadCamerasFromURL:(NSURL *)url
                                               error:(NSError * _Nullable * _Nullable)error;

/// ✅ New: full scene API (mesh + UV + cameras), meshes merged into one
+ (FBXImportedScene *)loadSceneFromURL:(NSURL *)url
                                 error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
