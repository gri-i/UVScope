import Foundation
import simd

struct Mesh {
    let vertices: [Vertex]
    let indices: [UInt32]
}

enum OBJError: Error {
    case invalidUTF8
    case parseFailed(String)
    case validationFailed([String]) // Multiple validation errors
}

struct OBJValidationResult {
    var objectCount: Int = 0
    var hasNgons: Bool = false
    var ngonCount: Int = 0
    var maxNgonVertices: Int = 0
    var ngonExamples: [(lineNumber: Int, vertexCount: Int)] = []
    
    var errors: [String] {
        var errs: [String] = []
        if objectCount > 1 {
            errs.append("File contains multiple objects (\(objectCount)). Please export as single object.")
        }
        if hasNgons {
            let examples = ngonExamples.prefix(3).map { "\($0.vertexCount) vertices" }.joined(separator: ", ")
            errs.append("N-gons found: \(ngonCount) (max \(maxNgonVertices) vertices). Export triangulated/quads. Examples: \(examples)")
        }
        return errs
    }
}

final class OBJLoader {
    static func load(url: URL) throws -> Mesh {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw OBJError.invalidUTF8 }

        // First pass: validation
        let validation = validateOBJ(text: text)
        if !validation.errors.isEmpty {
            throw OBJError.validationFailed(validation.errors)
        }

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var normals: [SIMD3<Float>] = []

        struct Key: Hashable { let v: Int; let vt: Int; let vn: Int }
        var map: [Key: UInt32] = [:]
        var outVerts: [Vertex] = []
        var outIdx: [UInt32] = []

        func idx(_ s: Substring, count: Int) -> Int {
            let i = Int(s) ?? 0
            if i > 0 { return i - 1 }
            if i < 0 { return count + i }
            return 0
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("v ") {
                let p = line.split(separator: " ")
                if p.count >= 4 {
                    positions.append(SIMD3<Float>(Float(p[1]) ?? 0, Float(p[2]) ?? 0, Float(p[3]) ?? 0))
                }
            } else if line.hasPrefix("vt ") {
                let p = line.split(separator: " ")
                if p.count >= 3 {
                    let u = Float(p[1]) ?? 0
                    let v = Float(p[2]) ?? 0
                    uvs.append(SIMD2<Float>(u, 1.0 - v)) // flip V
                }
            } else if line.hasPrefix("vn ") {
                let p = line.split(separator: " ")
                if p.count >= 4 {
                    normals.append(SIMD3<Float>(Float(p[1]) ?? 0, Float(p[2]) ?? 0, Float(p[3]) ?? 0))
                }
            } else if line.hasPrefix("f ") {
                let p = line.split(separator: " ")
                if p.count < 4 { continue }

                var face: [UInt32] = []
                for i in 1..<p.count {
                    let c = p[i].split(separator: "/")
                    let vi = idx(c.count > 0 ? c[0] : "1", count: positions.count)
                    let ti = (c.count > 1 && !c[1].isEmpty) ? idx(c[1], count: uvs.count) : 0
                    let ni = (c.count > 2 && !c[2].isEmpty) ? idx(c[2], count: normals.count) : 0

                    let k = Key(v: vi, vt: ti, vn: ni)
                    if let ex = map[k] {
                        face.append(ex)
                    } else {
                        let pos = positions.indices.contains(vi) ? positions[vi] : .zero
                        let uv  = uvs.indices.contains(ti) ? uvs[ti] : SIMD2<Float>(0, 0)
                        let n   = normals.indices.contains(ni) ? normals[ni] : SIMD3<Float>(0, 1, 0)

                        let newIndex = UInt32(outVerts.count)
                        outVerts.append(Vertex(position: pos, uv: uv, normal: n))
                        map[k] = newIndex
                        face.append(newIndex)
                    }
                }

                if face.count == 3 {
                    outIdx.append(contentsOf: face)
                } else if face.count > 3 {
                    for i in 1..<(face.count - 1) {
                        outIdx.append(face[0])
                        outIdx.append(face[i])
                        outIdx.append(face[i + 1])
                    }
                }
            }
        }

        guard !outVerts.isEmpty, !outIdx.isEmpty else {
            throw OBJError.parseFailed("No geometry found")
        }

        return Mesh(vertices: outVerts, indices: outIdx)
    }
    
    // MARK: - Validation
    
    private static func validateOBJ(text: String) -> OBJValidationResult {
        var result = OBJValidationResult()
        var lineNumber = 0
        
        for raw in text.split(whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            
            // Check for object declarations (o)
            if line.hasPrefix("o ") {
                result.objectCount += 1
            }
            
            // Check for N-gons in faces (f)
            if line.hasPrefix("f ") {
                let p = line.split(separator: " ")
                if p.count >= 4 {
                    // Count vertices in face (excluding "f" prefix)
                    let vertexCount = p.count - 1
                    if vertexCount > 4 {
                        result.hasNgons = true
                        result.ngonCount += 1
                        if vertexCount > result.maxNgonVertices {
                            result.maxNgonVertices = vertexCount
                        }
                        // Store first 3 examples
                        if result.ngonExamples.count < 3 {
                            result.ngonExamples.append((lineNumber: lineNumber, vertexCount: vertexCount))
                        }
                    }
                }
            }
        }
        
        return result
    }
}
