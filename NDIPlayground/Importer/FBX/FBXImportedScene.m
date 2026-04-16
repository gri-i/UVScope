#import "FBXImportedScene.h"
#import "FBXImportedMesh.h"

@implementation FBXImportedScene

- (instancetype)init {
    self = [super init];
    if (self) {
        _cameras = @[];
        _sourceMeshCount = 0;
        _cameraCount = 0;
        _statusText = @"FBX: —";
        _warningText = @"";
    }
    return self;
}

@end
