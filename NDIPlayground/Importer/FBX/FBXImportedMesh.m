#import "FBXImportedMesh.h"

@implementation FBXImportedMesh

- (instancetype)init {
    self = [super init];
    if (self) {
        _vertexData = [NSData data];
        _indexData  = [NSData data];
        _vertexCount = 0;
        _indexCount = 0;
    }
    return self;
}

@end
