#import <Foundation/Foundation.h>

@class FBXImportedMesh;
@class FBXImportedCamera;

NS_ASSUME_NONNULL_BEGIN

@interface FBXImportedScene : NSObject
@property(nonatomic, strong, nullable) FBXImportedMesh *mesh;
@property(nonatomic, strong) NSArray<FBXImportedCamera *> *cameras;

@property(nonatomic, assign) NSInteger sourceMeshCount;
@property(nonatomic, assign) NSInteger cameraCount;

@property(nonatomic, copy) NSString *statusText;
@property(nonatomic, copy) NSString *warningText;
@end

NS_ASSUME_NONNULL_END
