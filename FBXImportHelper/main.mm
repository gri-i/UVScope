// main.mm (target FBXImportHelper)
#import <Foundation/Foundation.h>
#import "ofbx.h"

using namespace ofbx;

static int runImport(NSString *path) {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data || data.length == 0) {
            printf("{\"ok\":false,\"error\":\"Failed to read FBX file\"}\n");
            return 1;
        }

        const u8 *bytes = (const u8 *)data.bytes;
        const int size = (int)data.length;

        LoadFlags flags = LoadFlags::NONE
                        | LoadFlags::IGNORE_ANIMATIONS
                        | LoadFlags::IGNORE_SKIN
                        | LoadFlags::IGNORE_BLEND_SHAPES
                        | LoadFlags::IGNORE_VIDEOS;

        IScene *scene = load(bytes, (usize)size, (u16)flags, nullptr, nullptr);
        if (!scene) {
            const char *err = getError();
            printf("{\"ok\":false,\"error\":\"%s\"}\n", err ? err : "OpenFBX failed to parse scene");
            return 1;
        }

        int meshCount = scene->getMeshCount();
        if (meshCount == 0) {
            printf("{\"ok\":false,\"error\":\"FBX has no meshes\"}\n");
            scene->destroy();
            return 1;
        }
        if (meshCount > 1) {
            printf("{\"ok\":false,\"error\":\"Multiple meshes (%d). Export as single mesh.\"}\n", meshCount);
            scene->destroy();
            return 1;
        }

        printf("{\"ok\":true,\"meshCount\":%d}\n", meshCount);
        scene->destroy();
        return 0;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: FBXImportHelper <path-to-fbx>\n");
            return 1;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        return runImport(path);
    }
}
