// FBXSceneImporter.mm
#import "FBXSceneImporter.h"
#import "FBXImportedCamera.h"
#import "FBXImportedScene.h"
#import "FBXImportedMesh.h"

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#include <math.h>
#include <vector>
#include <map>

// OpenFBX (added as source files in project: Importer/OpenFBX/ofbx.h/.cpp)
#include "ofbx.h"

static inline simd_float3 V3(float x, float y, float z) { return simd_make_float3(x, y, z); }

static simd_float3 normalizeSafe(simd_float3 v) {
    float len = simd_length(v);
    if (len < 1e-6f) return V3(0, 0, -1);
    return v / len;
}

// ---------- Compile-time safe "try getName()" without __has_member ----------
template <typename T>
static auto TryGetName(const T* obj, int) -> decltype(obj->getName(), (const char*)nullptr) {
    return obj->getName();
}
template <typename T>
static const char* TryGetName(const T* obj, ...) {
    (void)obj;
    return nullptr;
}

template <typename T>
static const char* BestNameCStr(const T* obj) {
    if (!obj) return nullptr;

    // 1) if this OpenFBX build has getName()
    if (const char* n = TryGetName(obj, 0)) {
        if (n[0] != 0) return n;
    }

    // 2) fallback to public member "name" (exists in many OpenFBX builds)
    const char* n2 = obj->name;
    if (n2 && n2[0] != 0) return n2;

    return nullptr;
}

// OpenFBX DMatrix is 4x4 double array (m[16]). Convert into simd_float4x4.
// We treat it as column-major as used by most OpenFBX forks.
static simd_float4x4 toSimd(const ofbx::DMatrix& m) {
    simd_float4x4 r;
    r.columns[0] = simd_make_float4((float)m.m[0],  (float)m.m[1],  (float)m.m[2],  (float)m.m[3]);
    r.columns[1] = simd_make_float4((float)m.m[4],  (float)m.m[5],  (float)m.m[6],  (float)m.m[7]);
    r.columns[2] = simd_make_float4((float)m.m[8],  (float)m.m[9],  (float)m.m[10], (float)m.m[11]);
    r.columns[3] = simd_make_float4((float)m.m[12], (float)m.m[13], (float)m.m[14], (float)m.m[15]);
    return r;
}

static simd_float3 extractTranslation(const simd_float4x4& m) {
    return simd_make_float3(m.columns[3].x, m.columns[3].y, m.columns[3].z);
}

// In most DCC/FBX exports, camera looks down its local -Z axis.
// World-space forward = -(world Z axis of the transform)
static simd_float3 extractForwardMinusZ(const simd_float4x4& m) {
    simd_float3 zAxis = simd_make_float3(m.columns[2].x, m.columns[2].y, m.columns[2].z);
    return normalizeSafe(-zAxis);
}

// Transform a 3D point by a 4x4 matrix
static simd_float3 transformPoint(const simd_float4x4& m, simd_float3 p) {
    simd_float4 v = simd_make_float4(p.x, p.y, p.z, 1.0f);
    simd_float4 r = simd_mul(m, v);
    return simd_make_float3(r.x, r.y, r.z);
}

// Extract cameras from scene (shared between loadCamerasFromURL and loadSceneFromURL)
static NSArray<FBXImportedCamera *> *extractCameras(ofbx::IScene* scene) {
    NSMutableArray<FBXImportedCamera *> *out = [NSMutableArray array];
    
    const int camCount = scene->getCameraCount();
    NSLog(@"FBX: Found %d cameras", camCount);
    
    for (int i = 0; i < camCount; i++) {
        const ofbx::Camera* cam = scene->getCamera(i);
        if (!cam) continue;
        
        FBXImportedCamera *c = [FBXImportedCamera new];
        
        // Try to get name from camera object first
        const char* nm = BestNameCStr(cam);
        
        // If no name, try parent node (in FBX, cameras are usually parented to a node with the name)
        if (!nm || nm[0] == 0) {
            const ofbx::Object* parent = cam->getParent();
            if (parent) {
                nm = BestNameCStr(parent);
            }
        }
        
        if (nm && nm[0] != 0) {
            c.name = [NSString stringWithUTF8String:nm];
        } else {
            c.name = [NSString stringWithFormat:@"Camera %d", i + 1];
        }
        
        // Get transform - try parent node first (camera position is usually on the node)
        const ofbx::Object* parent = cam->getParent();
        ofbx::DMatrix gm;
        if (parent) {
            gm = parent->getGlobalTransform();
        } else {
            gm = cam->getGlobalTransform();
        }
        simd_float4x4 M = toSimd(gm);
        
        // Camera position - same coordinate system as mesh (no Z inversion)
        simd_float3 pos = extractTranslation(M);
        c.position = pos;
        
        // In C4D/FBX, the camera's forward direction is the +X axis of the transform
        simd_float3 xAxis = simd_make_float3(M.columns[0].x, M.columns[0].y, M.columns[0].z);
        // forward = +X axis (camera looks along local +X in C4D FBX export)
        c.forward = normalizeSafe(xAxis);
        
        // DEBUG: Print camera info
        NSLog(@"Camera[%d]: name='%@', pos=(%.2f, %.2f, %.2f), forward=(%.2f, %.2f, %.2f)",
              i, c.name, c.position.x, c.position.y, c.position.z,
              c.forward.x, c.forward.y, c.forward.z);
        
        c.nearPlane = (float)cam->getNearPlane();
        c.farPlane  = (float)cam->getFarPlane();
        
        float fl = (float)cam->getFocalLength();
        float filmW = (float)cam->getFilmWidth();
        float filmH = (float)cam->getFilmHeight();
        
        // DEBUG: raw values
        NSLog(@"Camera[%d] RAW: focal=%.4f, filmW=%.4f, filmH=%.4f", i, fl, filmW, filmH);
        
        c.focalLengthMm = fl;
        
        float sensorW_mm = filmW;
        float sensorH_mm = filmH;
        // Convert from inches to mm if values seem to be in inches
        if (sensorW_mm > 0.0001f && sensorW_mm < 10.0f) sensorW_mm *= 25.4f;
        if (sensorH_mm > 0.0001f && sensorH_mm < 10.0f) sensorH_mm *= 25.4f;
        
        c.sensorWidthMm  = sensorW_mm;
        c.sensorHeightMm = sensorH_mm;
        
        // Calculate horizontal FOV from sensor width and focal length
        if (fl > 0.0001f && sensorW_mm > 0.0001f) {
            float radH = 2.0f * atanf((sensorW_mm * 0.5f) / fl);
            c.fovHDegrees = radH * (180.0f / 3.1415926535f);
            // Also calculate vertical FOV from sensor height for fallback
            float radV = 2.0f * atanf((sensorH_mm * 0.5f) / fl);
            c.fovYDegrees = radV * (180.0f / 3.1415926535f);
            NSLog(@"Camera[%d]: fovH=%.1f°, fovV=%.1f°, focal=%.1fmm, sensor=%.1fx%.1fmm",
                  i, c.fovHDegrees, c.fovYDegrees, c.focalLengthMm, c.sensorWidthMm, c.sensorHeightMm);
        } else {
            c.fovHDegrees = 70.0f;
            c.fovYDegrees = 50.0f;
            NSLog(@"Camera[%d]: using default fovH=70°, fovV=50°", i);
        }
        
        if (!(c.nearPlane > 0.0f)) c.nearPlane = 0.01f;
        if (!(c.farPlane > c.nearPlane)) c.farPlane = 1000.0f;
        
        [out addObject:c];
    }
    
    return out;
}

@implementation FBXSceneImporter

+ (NSArray<FBXImportedCamera *> *)loadCamerasFromURL:(NSURL *)url
                                               error:(NSError * _Nullable * _Nullable)error
{
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data || data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"FBXSceneImporter"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to read FBX file."}];
        }
        return @[];
    }

    const ofbx::u8* bytes = (const ofbx::u8*)data.bytes;
    const int size = (int)data.length;

    // Keep flags minimal for maximum compatibility across OpenFBX forks.
    ofbx::IScene* scene = ofbx::load(bytes, (ofbx::usize)size, 0);

    if (!scene) {
        if (error) {
            const char* err = ofbx::getError();
            NSString* msg = err ? [NSString stringWithUTF8String:err] : @"OpenFBX failed to parse scene.";
            *error = [NSError errorWithDomain:@"FBXSceneImporter"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return @[];
    }

    NSArray<FBXImportedCamera *> *out = extractCameras(scene);

    scene->destroy();
    return out;
}

// ✅ Full scene loading: meshes + cameras
+ (FBXImportedScene *)loadSceneFromURL:(NSURL *)url
                                 error:(NSError * _Nullable * _Nullable)error
{
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data || data.length == 0) {
    if (error) {
        *error = [NSError errorWithDomain:@"FBXSceneImporter"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to read FBX file."}];
        }
        return nil;
    }
    
    const ofbx::u8* bytes = (const ofbx::u8*)data.bytes;
    const int size = (int)data.length;
    
    ofbx::IScene* scene = ofbx::load(bytes, (ofbx::usize)size, 0);
    
    if (!scene) {
        if (error) {
            const char* err = ofbx::getError();
            NSString* msg = err ? [NSString stringWithUTF8String:err] : @"OpenFBX failed to parse scene.";
            *error = [NSError errorWithDomain:@"FBXSceneImporter"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return nil;
    }
    
    FBXImportedScene *result = [FBXImportedScene new];
    
    // Extract cameras
    result.cameras = extractCameras(scene);
    result.cameraCount = (NSInteger)result.cameras.count;
    
    // Extract meshes
    const int meshCount = scene->getMeshCount();
    result.sourceMeshCount = (NSInteger)meshCount;
    
    if (meshCount == 0) {
        result.statusText = @"FBX loaded: no meshes";
        result.mesh = nil;
        scene->destroy();
        return result;
    }
    
    // ✅ EARLY VALIDATION: Check mesh count before processing (prevents crashes)
    if (meshCount > 1) {
        if (error) {
            *error = [NSError errorWithDomain:@"FBXSceneImporter"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Multiple meshes found: %d. Export as a single mesh.", meshCount]}];
        }
        scene->destroy();
        return nil;
    }
    
    // ✅ VALIDATION: Count meshes with geometry
    int meshesWithGeometry = 0;
    int ngonCount = 0;
    int maxNgonVertices = 0;
    NSMutableArray<NSNumber *> *ngonExamples = [NSMutableArray array];
    
    for (int meshIdx = 0; meshIdx < meshCount; meshIdx++) {
        const ofbx::Mesh* mesh = scene->getMesh(meshIdx);
        if (!mesh) continue;
        
        const ofbx::GeometryData& geom = mesh->getGeometryData();
        if (!geom.hasVertices()) {
            continue;
        }
        
        meshesWithGeometry++;
        
        // Check for N-gons in partitions (before triangulation)
        const int partitionCount = geom.getPartitionCount();
        if (partitionCount == 0) continue;
        
        for (int partIdx = 0; partIdx < partitionCount; partIdx++) {
            ofbx::GeometryPartition partition = geom.getPartition(partIdx);
            
            for (int polyIdx = 0; polyIdx < partition.polygon_count; polyIdx++) {
                const ofbx::GeometryPartition::Polygon& poly = partition.polygons[polyIdx];
                
                if (poly.vertex_count < 3) continue;
                
                // Check for N-gons (> 4 vertices)
                if (poly.vertex_count > 4) {
                    ngonCount++;
                    if (poly.vertex_count > maxNgonVertices) {
                        maxNgonVertices = poly.vertex_count;
                    }
                    // Store first 3 examples
                    if (ngonExamples.count < 3) {
                        [ngonExamples addObject:@(poly.vertex_count)];
                    }
                }
            }
        }
    }
    
    // ✅ VALIDATION: Check errors
    NSMutableArray<NSString *> *validationErrors = [NSMutableArray array];
    
    if (meshesWithGeometry > 1) {
        [validationErrors addObject:[NSString stringWithFormat:@"Multiple meshes found: %d. Export as a single mesh.", meshesWithGeometry]];
    }
    
    if (ngonCount > 0) {
        NSMutableString *examplesStr = [NSMutableString string];
        for (NSNumber *n in ngonExamples) {
            if (examplesStr.length > 0) [examplesStr appendString:@", "];
            [examplesStr appendFormat:@"%d vertices", n.intValue];
        }
        [validationErrors addObject:[NSString stringWithFormat:@"N-gons found: %d (max %d vertices). Export triangulated/quads. Examples: %@", ngonCount, maxNgonVertices, examplesStr]];
    }
    
    // If validation fails, return error
    if (validationErrors.count > 0) {
        NSString *errorMsg = [validationErrors componentsJoinedByString:@"\n"];
        if (error) {
            *error = [NSError errorWithDomain:@"FBXSceneImporter"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        scene->destroy();
        return nil;
    }
    
    // Collect all vertices and indices from all meshes
    // Use a map to deduplicate vertices by position AND UV (like OBJLoader)
    // This is correct for FBX - vertices with same position but different UVs
    // should be different vertices (e.g., cube corners on different faces)
    struct VertexKey {
        simd_float3 pos;
        simd_float2 uv;
        
        bool operator<(const VertexKey& other) const {
            const float eps = 1e-5f;
            if (fabsf(pos.x - other.pos.x) > eps) return pos.x < other.pos.x;
            if (fabsf(pos.y - other.pos.y) > eps) return pos.y < other.pos.y;
            if (fabsf(pos.z - other.pos.z) > eps) return pos.z < other.pos.z;
            if (fabsf(uv.x - other.uv.x) > eps) return uv.x < other.uv.x;
            return uv.y < other.uv.y;
        }
    };
    
    std::map<VertexKey, UInt32> vertexMap;
    std::vector<FBXVertexPU> allVertices;
    std::vector<UInt32> allIndices;
    
    NSMutableString *warnings = [NSMutableString string];
    meshesWithGeometry = 0; // Reset counter for actual processing
    
    // Helper to get or create vertex index (deduplicate by position + UV)
    auto getOrCreateVertex = [&](simd_float3 pos, simd_float2 uv, simd_float3 normal) -> UInt32 {
        VertexKey key{pos, uv};
        auto it = vertexMap.find(key);
        if (it != vertexMap.end()) {
            return it->second;
        }
        UInt32 idx = (UInt32)allVertices.size();
        allVertices.push_back({pos, uv, normal});
        vertexMap[key] = idx;
        return idx;
    };
    
    for (int meshIdx = 0; meshIdx < meshCount; meshIdx++) {
        const ofbx::Mesh* mesh = scene->getMesh(meshIdx);
        if (!mesh) continue;
        
        const ofbx::GeometryData& geom = mesh->getGeometryData();
        
        if (!geom.hasVertices()) {
            continue;
        }
        
        meshesWithGeometry++;
        
        // Get mesh transform
        // In FBX: geometric transform is applied first (local), then global transform
        // So: final = global * geometric
        const ofbx::DMatrix globalMtx = mesh->getGlobalTransform();
        const ofbx::DMatrix geomMtx = mesh->getGeometricMatrix();
        simd_float4x4 globalTransform = toSimd(globalMtx);
        simd_float4x4 geomTransform = toSimd(geomMtx);
        
        // Standard FBX: global * geometric (position, rotation, scale from FBX)
        simd_float4x4 combinedTransform = simd_mul(globalTransform, geomTransform);
        
        // Get positions and UVs
        ofbx::Vec3Attributes positions = geom.getPositions();
        ofbx::Vec2Attributes uvs = geom.getUVs(0); // Use first UV set
        
        if (positions.count == 0) {
            continue;
        }
        
        // Get partitions (polygon groups)
        const int partitionCount = geom.getPartitionCount();
        
        if (partitionCount == 0) {
            // No partitions - treat as single partition
            // For now, skip meshes without partitions (they need special handling)
            if (warnings.length > 0) [warnings appendString:@"; "];
            [warnings appendFormat:@"Mesh %d: no partitions", meshIdx];
            continue;
        }
        
        // Process each partition
        for (int partIdx = 0; partIdx < partitionCount; partIdx++) {
            ofbx::GeometryPartition partition = geom.getPartition(partIdx);
            
            // Triangulate polygons in this partition
            for (int polyIdx = 0; polyIdx < partition.polygon_count; polyIdx++) {
                const ofbx::GeometryPartition::Polygon& poly = partition.polygons[polyIdx];
                
                if (poly.vertex_count < 3) continue;
                
                // Allocate temp buffer for triangulation (max 128 vertices per polygon)
                int tmpBuf[128];
                int triIndices[256]; // Enough for most polygons
                
                // triangulate returns number of indices (3 per triangle)
                const ofbx::u32 indexCount = ofbx::triangulate(geom, poly, triIndices, 
                                                               poly.vertex_count <= 128 ? tmpBuf : nullptr);
                
                if (indexCount == 0 || indexCount % 3 != 0) continue;
                
                const ofbx::u32 triCount = indexCount / 3;
                
                for (ofbx::u32 tri = 0; tri < triCount; tri++) {
                    const int rawIdx0 = triIndices[tri * 3 + 0];
                    const int rawIdx1 = triIndices[tri * 3 + 1];
                    const int rawIdx2 = triIndices[tri * 3 + 2];
                    
                    // Validate indices before access
                    if (rawIdx0 < 0 || rawIdx0 >= positions.count ||
                        rawIdx1 < 0 || rawIdx1 >= positions.count ||
                        rawIdx2 < 0 || rawIdx2 >= positions.count) {
                        continue; // Skip invalid triangle
                    }
                    
                    // Use positions.get() - it handles the indices array correctly
                    ofbx::Vec3 pos0 = positions.get(rawIdx0);
                    ofbx::Vec3 pos1 = positions.get(rawIdx1);
                    ofbx::Vec3 pos2 = positions.get(rawIdx2);
                    
                    // Transform positions
                    simd_float3 p0 = transformPoint(combinedTransform, V3((float)pos0.x, (float)pos0.y, (float)pos0.z));
                    simd_float3 p1 = transformPoint(combinedTransform, V3((float)pos1.x, (float)pos1.y, (float)pos1.z));
                    simd_float3 p2 = transformPoint(combinedTransform, V3((float)pos2.x, (float)pos2.y, (float)pos2.z));
                    
                    // Get UVs
                    simd_float2 uv0 = simd_make_float2(0, 0);
                    simd_float2 uv1 = simd_make_float2(0, 0);
                    simd_float2 uv2 = simd_make_float2(0, 0);
                    
                    if (uvs.count > 0 && uvs.values != nullptr) {
                        ofbx::Vec2 uv0_raw = uvs.get(rawIdx0);
                        ofbx::Vec2 uv1_raw = uvs.get(rawIdx1);
                        ofbx::Vec2 uv2_raw = uvs.get(rawIdx2);
                        // Flip V coordinate (1 - v) for Metal texture coordinate system
                        uv0 = simd_make_float2((float)uv0_raw.x, 1.0f - (float)uv0_raw.y);
                        uv1 = simd_make_float2((float)uv1_raw.x, 1.0f - (float)uv1_raw.y);
                        uv2 = simd_make_float2((float)uv2_raw.x, 1.0f - (float)uv2_raw.y);
                    }
                    
                    // Create unique vertices per triangle (NO deduplication)
                    // This is the most reliable way to ensure correct geometry
                    simd_float3 normal = simd_make_float3(0, 1, 0);
                    
                    const UInt32 baseIdx = (UInt32)allVertices.size();
                    allVertices.push_back({p0, uv0, normal});
                    allVertices.push_back({p1, uv1, normal});
                    allVertices.push_back({p2, uv2, normal});
                    
                    // Add triangle indices (Counter-Clockwise order for Metal)
                    allIndices.push_back(baseIdx + 0);
                    allIndices.push_back(baseIdx + 1);
                    allIndices.push_back(baseIdx + 2);
                }
            }
        }
    }
    
    // DEBUG: Print struct size and all vertices
    NSLog(@"=== FBX Import Debug ===");
    NSLog(@"sizeof(FBXVertexPU) = %zu bytes", sizeof(FBXVertexPU));
    NSLog(@"Total vertices: %zu", allVertices.size());
    NSLog(@"Total indices: %zu", allIndices.size());
    NSLog(@"Total triangles: %zu", allIndices.size() / 3);
    
    NSLog(@"\n=== All Vertices ===");
    for (size_t i = 0; i < allVertices.size(); i++) {
        const FBXVertexPU& v = allVertices[i];
        NSLog(@"Vertex[%zu]: pos=(%.2f, %.2f, %.2f), uv=(%.2f, %.2f)",
              i, v.position.x, v.position.y, v.position.z, v.uv.x, v.uv.y);
    }
    
    NSLog(@"\n=== All Triangles (indices) ===");
    for (size_t i = 0; i < allIndices.size(); i += 3) {
        if (i + 2 < allIndices.size()) {
            NSLog(@"Triangle[%zu]: (%u, %u, %u)",
                  i / 3, allIndices[i], allIndices[i+1], allIndices[i+2]);
        }
    }
    NSLog(@"=== End Debug ===");
    
    // Create merged mesh
    if (allVertices.size() > 0) {
        FBXImportedMesh *mergedMesh = [FBXImportedMesh new];
        
        NSData *vertexData = [NSData dataWithBytes:allVertices.data() 
                                             length:allVertices.size() * sizeof(FBXVertexPU)];
        NSData *indexData = [NSData dataWithBytes:allIndices.data() 
                                            length:allIndices.size() * sizeof(UInt32)];
        
        mergedMesh.vertexData = vertexData;
        mergedMesh.indexData = indexData;
        mergedMesh.vertexCount = (NSInteger)allVertices.size();
        mergedMesh.indexCount = (NSInteger)allIndices.size();
        
        result.mesh = mergedMesh;
        
        NSMutableString *status = [NSMutableString string];
        [status appendFormat:@"FBX loaded: %d mesh(es)", meshesWithGeometry];
        [status appendFormat:@", %ld vertices", (long)allVertices.size()];
        [status appendFormat:@", %ld triangles", (long)(allIndices.size() / 3)];
        result.statusText = status;
    } else {
        result.mesh = nil;
        result.statusText = @"FBX loaded: no valid geometry";
    }
    
    if (warnings.length > 0) {
        result.warningText = warnings;
    }
    
    scene->destroy();
    return result;
}

@end
