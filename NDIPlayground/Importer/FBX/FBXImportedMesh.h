#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// One vertex, expanded (position + uv + normal). Must match Vertex struct in ShaderTypes.swift
/// NOTE: Do NOT use __attribute__((packed)) - it must match Swift's memory layout
typedef struct {
    simd_float3 position;
    simd_float2 uv;
    simd_float3 normal;
} FBXVertexPU;

@interface FBXImportedMesh : NSObject

/// Interleaved vertices (FBXVertexPU[])
@property(nonatomic, strong) NSData *vertexData;

/// Triangle indices (uint32_t[])
@property(nonatomic, strong) NSData *indexData;

@property(nonatomic, assign) NSInteger vertexCount;
@property(nonatomic, assign) NSInteger indexCount;

@end

NS_ASSUME_NONNULL_END
