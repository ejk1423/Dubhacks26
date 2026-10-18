//
//  MeshGeometryStore.swift
//  Echo
//
//  Actor that owns a copy of every LiDAR mesh chunk and does all of the heavy
//  geometry math off the main thread:
//
//    * builds point-cloud render data (per-face material buckets) for each chunk,
//    * estimates the local ground plane (ARPlaneAnchor floor, cross-checked
//      against the median height of floor-classified mesh vertices),
//    * finds the nearest obstacle for the wall sonar per 45-degree sector, using a
//      distance histogram (a bin needs several vertices, so one stray vertex is not
//      a wall) smoothed over time (approach is instant, recession is rate-limited),
//    * scans a 1-3 m corridor along the walking direction for negative drops
//      (potholes, stairs) and positive spikes (curbs, rocks) relative to ground,
//      clusters them into `TripHazard`s, reports only those that persist over several
//      analyses, and emits the red overlay triangles.
//
//  Only `Sendable` value types cross into or out of this actor.
//

import Foundation
import simd

actor MeshGeometryStore {

    // MARK: Types

    private struct StoredChunk {
        let chunk: MeshChunk
        /// Vertex positions in world space (anchor transform baked in).
        let world: [SIMD3<Float>]
        /// Classification per vertex, derived from the faces that touch it.
        let vertexClasses: [UInt8]
        let aabbMin: SIMD3<Float>
        let aabbMax: SIMD3<Float>
    }

    /// Accumulator for one corridor grid cell.
    private struct Cell {
        var count = 0            // floor-ish vertices inside the trip band
        var obstacleCount = 0    // vertices above `maxTripHeight`
        var dropCount = 0
        var bumpCount = 0
        var dropSum = SIMD3<Float>(repeating: 0)
        var bumpSum = SIMD3<Float>(repeating: 0)
        var minDy: Float = .infinity
        var maxDy: Float = -.infinity
    }

    private struct Candidate {
        let chunkIndex: Int
        let vertex: Int
        let cell: Int
    }

    private enum CellKind: UInt8 {
        case none = 0, drop, bump, unknown
    }

    private struct TrackedHazard {
        var hazard: TripHazard
        var streak: Int
        var cells: [Int]
    }

    struct AnalysisResult: Sendable {
        let snapshot: SceneSnapshot
        let overlay: HazardOverlayData
        /// Chunks dropped for being far away; the renderer should remove them too.
        let evicted: [UUID]
    }

    // MARK: State

    private let config: PerceptionConfig
    private var chunks: [UUID: StoredChunk] = [:]
    private var planes: [UUID: PlaneInfo] = [:]
    private var totalVertices = 0
    private var lastGround: Float?
    private var lastAnalysisTime: TimeInterval?
    private var smoothedSectors = [Float](repeating: .infinity, count: 8)
    private var sectorHits = [ObstacleHit?](repeating: nil, count: 8)
    private var sectorStreaks = [Int](repeating: 0, count: 8)
    private var trackedHazards: [TrackedHazard] = []

    init(config: PerceptionConfig) {
        self.config = config
    }

    // MARK: Chunk / plane bookkeeping

    /// Stores (or replaces) a chunk and returns the wireframe data for the renderer.
    func upsert(_ chunk: MeshChunk) -> WireframeMeshData {
        let n = chunk.localPositions.count
        let faceCount = chunk.faceClasses.count

        // World-space positions + bounding box.
        var world = [SIMD3<Float>](repeating: .zero, count: n)
        var aabbMin = SIMD3<Float>(repeating: .infinity)
        var aabbMax = SIMD3<Float>(repeating: -.infinity)
        for i in 0..<n {
            let w = chunk.transform.transformPoint(chunk.localPositions[i])
            world[i] = w
            aabbMin = simd_min(aabbMin, w)
            aabbMax = simd_max(aabbMax, w)
        }

        // Per-vertex class (a classified face wins over `none`).
        var vertexClasses = [UInt8](repeating: MeshClass.none, count: n)
        chunk.indices.withUnsafeBufferPointer { idx in
            for f in 0..<faceCount {
                let base = f * 3
                guard base + 2 < idx.count else { break }
                let c = chunk.faceClasses[f]
                if c != MeshClass.none {
                    for k in 0..<3 {
                        let vi = Int(idx[base + k])
                        if vi < n { vertexClasses[vi] = c }
                    }
                }
            }
        }

        // Point cloud: one dot per `dotSpacing` voxel (anchor-local), drawn as a tiny
        // octahedron so it reads as a point from any angle. Only walls and furniture (the
        // things you can walk into) are drawn; floor, ceiling and unclassified surfaces
        // are skipped to keep the view clean.
        let spacing = config.dotSpacing
        let r = config.dotRadius
        let offsets: [SIMD3<Float>] = [[r, 0, 0], [-r, 0, 0], [0, r, 0], [0, -r, 0], [0, 0, r], [0, 0, -r]]
        let octahedron: [UInt32] = [0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0, 4, 2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3, 5]
        var seen = Set<SIMD3<Int32>>()
        var dotPositions: [SIMD3<Float>] = []
        var dotIndices: [UInt32] = []
        var rawMaterials: [UInt32] = []
        var usedBuckets = [Bool](repeating: false, count: SurfaceBucket.allCases.count)
        for i in 0..<n {
            let bucket = SurfaceBucket(meshClass: vertexClasses[i])
            guard bucket == .wall || bucket == .furniture else { continue }
            let p = chunk.localPositions[i]
            guard seen.insert(SIMD3<Int32>(p / spacing, rounding: .down)).inserted else { continue }
            let base = UInt32(dotPositions.count)
            for o in offsets { dotPositions.append(p + o) }
            for v in octahedron { dotIndices.append(base + v) }
            for _ in 0..<(octahedron.count / 3) { rawMaterials.append(bucket.rawValue) }
            usedBuckets[Int(bucket.rawValue)] = true
        }

        // Dense material indices so the renderer only allocates the materials this chunk uses.
        var remap = [UInt32](repeating: 0, count: usedBuckets.count)
        var buckets: [SurfaceBucket] = []
        for bucket in SurfaceBucket.allCases where usedBuckets[Int(bucket.rawValue)] {
            remap[Int(bucket.rawValue)] = UInt32(buckets.count)
            buckets.append(bucket)
        }
        let faceMaterials = rawMaterials.map { remap[Int($0)] }

        if let old = chunks[chunk.anchorID] { totalVertices -= old.world.count }
        totalVertices += n
        chunks[chunk.anchorID] = StoredChunk(
            chunk: chunk,
            world: world,
            vertexClasses: vertexClasses,
            aabbMin: aabbMin,
            aabbMax: aabbMax
        )

        return WireframeMeshData(
            anchorID: chunk.anchorID,
            sequence: chunk.sequence,
            transform: chunk.transform,
            positions: dotPositions,
            indices: dotIndices,
            faceMaterials: faceMaterials,
            buckets: buckets
        )
    }

    func remove(anchorID: UUID) {
        if let old = chunks.removeValue(forKey: anchorID) {
            totalVertices -= old.world.count
        }
    }

    func upsertPlane(_ plane: PlaneInfo) {
        planes[plane.anchorID] = plane
    }

    func removePlane(anchorID: UUID) {
        planes[anchorID] = nil
    }

    func removeAll() {
        chunks.removeAll()
        planes.removeAll()
        totalVertices = 0
        lastGround = nil
        resetTracking()
    }

    private func resetTracking() {
        lastAnalysisTime = nil
        smoothedSectors = [Float](repeating: .infinity, count: 8)
        sectorHits = [ObstacleHit?](repeating: nil, count: 8)
        sectorStreaks = [Int](repeating: 0, count: 8)
        trackedHazards.removeAll()
    }

    // MARK: Analysis

    /// Runs the ground estimate, obstacle sonar and trip-hazard scan for the given camera pose.
    func analyze(cameraTransform: simd_float4x4, timestamp: TimeInterval) -> AnalysisResult {
        let cfg = config
        let p0 = cameraTransform.translation

        // Walking direction. ARKit camera space is landscape-right: -Z is the view
        // direction and +X is the top edge of a portrait phone. Summing both XZ
        // projections gives a stable forward vector whether the phone is held level
        // or pitched down at the floor.
        let camX = SIMD3(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
        let camZ = SIMD3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        var heading = (-camZ).xz + camX.xz
        if simd_length(heading) < 0.05 { heading = (-camZ).xz }
        if simd_length(heading) < 1e-4 { heading = SIMD3(0, 0, -1) }
        heading = simd_normalize(heading)
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))

        // ---- 0. Forget mesh far behind us so memory stays bounded --------------
        var evicted: [UUID] = []
        for (id, sc) in chunks
        where Self.horizontalDistance(from: p0, toBox: sc.aabbMin, sc.aabbMax) > cfg.chunkEvictionRadius {
            evicted.append(id)
        }
        for id in evicted { remove(anchorID: id) }

        // ---- 1. Ground plane -------------------------------------------------
        let (ground, groundSource) = estimateGround(cameraPosition: p0)
        if groundSource != .assumed { lastGround = ground }

        let dt = Float(min(max(timestamp - (lastAnalysisTime ?? timestamp), 0), 0.5))
        lastAnalysisTime = timestamp

        // Without a real floor every height is relative to a guess; report nothing yet.
        guard groundSource != .assumed else {
            resetTracking()
            lastAnalysisTime = timestamp
            let snapshot = SceneSnapshot(
                timestamp: timestamp,
                cameraTransform: cameraTransform,
                cameraPosition: p0,
                heading: heading,
                groundHeight: ground,
                groundSource: groundSource,
                nearestObstacle: nil,
                nearestForwardObstacle: nil,
                sectorDistances: smoothedSectors,
                tripHazards: [],
                meshAnchorCount: chunks.count,
                vertexCount: totalVertices
            )
            var overlay = HazardOverlayData()
            overlay.timestamp = timestamp
            return AnalysisResult(snapshot: snapshot, overlay: overlay, evicted: evicted)
        }

        // ---- 2. Single pass: sonar + corridor accumulation --------------------
        let chunkList = Array(chunks.values)

        let nT = max(1, Int(((cfg.pathFar - cfg.pathNear) / cfg.cellSize).rounded(.up)))
        let nS = max(1, Int(((2 * cfg.pathHalfWidth) / cfg.cellSize).rounded(.up)))
        var cells = [Cell](repeating: Cell(), count: nT * nS)
        var candidates: [Candidate] = []

        // Corridor AABB in world space, used to skip irrelevant chunks early.
        let cornerA = p0 + heading * cfg.pathNear - right * cfg.pathHalfWidth
        let cornerB = p0 + heading * cfg.pathNear + right * cfg.pathHalfWidth
        let cornerC = p0 + heading * cfg.pathFar - right * cfg.pathHalfWidth
        let cornerD = p0 + heading * cfg.pathFar + right * cfg.pathHalfWidth
        var corridorMin = simd_min(simd_min(cornerA, cornerB), simd_min(cornerC, cornerD))
        var corridorMax = simd_max(simd_max(cornerA, cornerB), simd_max(cornerC, cornerD))
        corridorMin.y = ground - 1.5                       // deep enough to see a stairwell
        corridorMax.y = ground + cfg.maxTripHeight + 0.1

        let sonarYMin = ground + cfg.obstacleMinHeight
        let sonarYMax = ground + cfg.obstacleMaxHeight

        // Sonar histogram: 8 yaw sectors x distance bins.
        let nBins = max(1, Int((cfg.obstacleMaxRange / cfg.obstacleBinSize).rounded(.up)))
        var binCount = [Int](repeating: 0, count: 8 * nBins)
        var binSum = [SIMD3<Float>](repeating: .zero, count: 8 * nBins)
        var binClass = [UInt8](repeating: MeshClass.none, count: 8 * nBins)

        for (ci, sc) in chunkList.enumerated() {
            let sonarRelevant =
                Self.horizontalDistance(from: p0, toBox: sc.aabbMin, sc.aabbMax) <= cfg.obstacleMaxRange
                && sc.aabbMax.y >= sonarYMin && sc.aabbMin.y <= sonarYMax
            let corridorRelevant = Self.overlaps(sc.aabbMin, sc.aabbMax, corridorMin, corridorMax)
            if !sonarRelevant && !corridorRelevant { continue }

            sc.world.withUnsafeBufferPointer { w in
                sc.vertexClasses.withUnsafeBufferPointer { cls in
                    for i in 0..<w.count {
                        let v = w[i]
                        let c = cls[i]
                        let dy = v.y - ground
                        let d = v - p0
                        let t = d.x * heading.x + d.z * heading.z   // ahead
                        let s = d.x * right.x + d.z * right.z       // right

                        // -- Wall sonar: anything solid between shin and head height.
                        if sonarRelevant,
                           dy >= cfg.obstacleMinHeight, dy <= cfg.obstacleMaxHeight,
                           c != MeshClass.floor, c != MeshClass.ceiling {
                            let dist = (d.x * d.x + d.z * d.z).squareRoot()
                            if dist < cfg.obstacleMaxRange, dist > 0.05 {
                                let angle = atan2(s, t)                                   // 0 = ahead, +pi/2 = right
                                var k = Int(((angle + .pi / 8) / (.pi / 4)).rounded(.down))
                                k = ((k % 8) + 8) % 8
                                let bin = k * nBins + min(Int(dist / cfg.obstacleBinSize), nBins - 1)
                                binCount[bin] += 1
                                binSum[bin] += v
                                if c != MeshClass.none { binClass[bin] = c }
                            }
                        }

                        // -- Trip-hazard corridor: floor-ish surfaces only.
                        if corridorRelevant,
                           t >= cfg.pathNear, t <= cfg.pathFar, abs(s) <= cfg.pathHalfWidth,
                           c != MeshClass.wall, c != MeshClass.ceiling,
                           c != MeshClass.window, c != MeshClass.door {
                            let ti = min(Int((t - cfg.pathNear) / cfg.cellSize), nT - 1)
                            let si = min(Int((s + cfg.pathHalfWidth) / cfg.cellSize), nS - 1)
                            let idx = ti * nS + si
                            if dy > cfg.maxTripHeight {
                                cells[idx].obstacleCount += 1
                            } else {
                                cells[idx].count += 1
                                if dy < cells[idx].minDy { cells[idx].minDy = dy }
                                if dy > cells[idx].maxDy { cells[idx].maxDy = dy }
                                if dy <= -cfg.dropThreshold {
                                    cells[idx].dropCount += 1
                                    cells[idx].dropSum += v
                                    candidates.append(Candidate(chunkIndex: ci, vertex: i, cell: idx))
                                } else if dy >= cfg.bumpThreshold {
                                    cells[idx].bumpCount += 1
                                    cells[idx].bumpSum += v
                                    candidates.append(Candidate(chunkIndex: ci, vertex: i, cell: idx))
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---- 2b. Resolve sonar sectors + temporal smoothing ---------------------
        for k in 0..<8 {
            var raw: ObstacleHit?
            for b in 0..<nBins {
                let bin = k * nBins + b
                guard binCount[bin] >= cfg.minObstacleVertices else { continue }
                let centroid = binSum[bin] / Float(binCount[bin])
                raw = ObstacleHit(
                    point: centroid,
                    horizontalDistance: simd_length((centroid - p0).xz),
                    bucket: SurfaceBucket(meshClass: binClass[bin])
                )
                break
            }
            sectorStreaks[k] = raw == nil ? 0 : sectorStreaks[k] + 1

            if let raw, raw.horizontalDistance <= smoothedSectors[k] {
                // Closer: take it immediately, but a brand-new obstacle must be seen twice.
                if smoothedSectors[k].isFinite || sectorStreaks[k] >= 2 {
                    smoothedSectors[k] = raw.horizontalDistance
                    sectorHits[k] = raw
                }
            } else if smoothedSectors[k].isFinite {
                // Farther or gone: recede at a limited rate so one missed scan does not flicker.
                let receded = smoothedSectors[k] + cfg.obstacleReleaseRate * dt
                if let raw, raw.horizontalDistance <= receded {
                    smoothedSectors[k] = raw.horizontalDistance
                    sectorHits[k] = raw
                } else if receded >= cfg.obstacleMaxRange {
                    smoothedSectors[k] = .infinity
                    sectorHits[k] = nil
                } else {
                    smoothedSectors[k] = receded
                    if let hit = sectorHits[k] {
                        sectorHits[k] = ObstacleHit(point: hit.point, horizontalDistance: receded, bucket: hit.bucket)
                    }
                }
            }
        }
        let nearestSector = (0..<8).min { smoothedSectors[$0] < smoothedSectors[$1] }!
        let best = sectorHits[nearestSector]
        let forwardSector = [7, 0, 1].min { smoothedSectors[$0] < smoothedSectors[$1] }!
        let bestFwd = sectorHits[forwardSector]

        // ---- 3. Classify cells ------------------------------------------------
        var kinds = [CellKind](repeating: .none, count: cells.count)
        for idx in 0..<cells.count {
            let cell = cells[idx]
            let minShare = cfg.minHazardFraction * Float(cell.count)
            if cell.dropCount >= cfg.minHazardVertices, Float(cell.dropCount) >= minShare,
               cell.dropCount >= cell.bumpCount {
                kinds[idx] = .drop
            } else if cell.bumpCount >= cfg.minHazardVertices, Float(cell.bumpCount) >= minShare {
                kinds[idx] = .bump
            }
        }
        if cfg.reportUnknownSurfaces {
            // A cell with no LiDAR returns at all, surrounded by scanned floor and within
            // close range, usually means the floor is not there (edge of a platform,
            // glass, or a very deep hole). Reported at low confidence.
            for ti in 0..<nT {
                let tCenter = cfg.pathNear + (Float(ti) + 0.5) * cfg.cellSize
                guard tCenter <= cfg.unknownSurfaceMaxDistance else { continue }
                for si in 0..<nS {
                    let idx = ti * nS + si
                    guard cells[idx].count == 0, cells[idx].obstacleCount == 0 else { continue }
                    var populated = 0
                    if ti > 0, cells[idx - nS].count >= cfg.minHazardVertices { populated += 1 }
                    if ti < nT - 1, cells[idx + nS].count >= cfg.minHazardVertices { populated += 1 }
                    if si > 0, cells[idx - 1].count >= cfg.minHazardVertices { populated += 1 }
                    if si < nS - 1, cells[idx + 1].count >= cfg.minHazardVertices { populated += 1 }
                    if populated >= 2 { kinds[idx] = .unknown }
                }
            }
        }

        // ---- 4. Flood-fill cells into hazards ---------------------------------
        var found: [(hazard: TripHazard, cells: [Int])] = []
        var visited = [Bool](repeating: false, count: cells.count)
        for start in 0..<cells.count where kinds[start] != .none && !visited[start] {
            let kind = kinds[start]
            var stack = [start]
            var members: [Int] = []
            visited[start] = true
            while let idx = stack.popLast() {
                members.append(idx)
                let ti = idx / nS, si = idx % nS
                let neighbours = [
                    ti > 0 ? idx - nS : -1,
                    ti < nT - 1 ? idx + nS : -1,
                    si > 0 ? idx - 1 : -1,
                    si < nS - 1 ? idx + 1 : -1,
                ]
                for n in neighbours where n >= 0 && !visited[n] && kinds[n] == kind {
                    visited[n] = true
                    stack.append(n)
                }
            }

            var position = SIMD3<Float>(repeating: 0)
            var count = 0
            var elevation: Float = 0
            switch kind {
            case .drop:
                for idx in members {
                    position += cells[idx].dropSum
                    count += cells[idx].dropCount
                    elevation = min(elevation, cells[idx].minDy)
                }
                position /= Float(max(count, 1))
            case .bump:
                for idx in members {
                    position += cells[idx].bumpSum
                    count += cells[idx].bumpCount
                    elevation = max(elevation, cells[idx].maxDy)
                }
                position /= Float(max(count, 1))
            case .unknown:
                for idx in members {
                    let ti = idx / nS, si = idx % nS
                    let t = cfg.pathNear + (Float(ti) + 0.5) * cfg.cellSize
                    let s = -cfg.pathHalfWidth + (Float(si) + 0.5) * cfg.cellSize
                    position += p0 + heading * t + right * s
                }
                position /= Float(members.count)
                position.y = ground
                count = members.count
            case .none:
                continue
            }

            let rel = position - p0
            let hazardKind: TripHazardKind = kind == .drop ? .drop : (kind == .bump ? .bump : .unknownSurface)
            let confidence: Float = kind == .unknown
                ? 0.3
                : min(1, Float(count) / Float(cfg.minHazardVertices * 4))

            var hasher = Hasher()
            hasher.combine(Int((position.x / 0.25).rounded()))
            hasher.combine(Int((position.z / 0.25).rounded()))
            hasher.combine(hazardKind.rawValue)

            found.append((TripHazard(
                id: hasher.finalize(),
                kind: hazardKind,
                position: position,
                distanceAhead: rel.x * heading.x + rel.z * heading.z,
                lateralOffset: rel.x * right.x + rel.z * right.z,
                elevation: elevation,
                confidence: confidence,
                vertexCount: count
            ), members))
        }

        // ---- 4b. Persistence: report a hazard only once it survives several scans --
        var next: [TrackedHazard] = []
        for (hazard, members) in found {
            var tracked = TrackedHazard(hazard: hazard, streak: 1, cells: members)
            if let m = trackedHazards.firstIndex(where: {
                $0.hazard.kind == hazard.kind
                    && simd_length(($0.hazard.position - hazard.position).xz) <= cfg.hazardMatchRadius
            }) {
                tracked.streak = trackedHazards[m].streak + 1
                tracked.hazard = hazard.withID(trackedHazards[m].hazard.id)   // keep a stable id
                trackedHazards.remove(at: m)
            }
            next.append(tracked)
        }
        trackedHazards = next
        let confirmed = next.filter { $0.streak >= cfg.hazardConfirmFrames }
        let confirmedCells = Set(confirmed.flatMap(\.cells))
        let hazards = confirmed.map(\.hazard).sorted { $0.distanceAhead < $1.distanceAhead }

        // ---- 5. Red overlay triangles ----------------------------------------
        var overlay = HazardOverlayData()
        overlay.timestamp = timestamp
        if !candidates.isEmpty, !confirmedCells.isEmpty {
            var masks: [Int: [Bool]] = [:]
            for cand in candidates where confirmedCells.contains(cand.cell) {
                if masks[cand.chunkIndex] == nil {
                    masks[cand.chunkIndex] = [Bool](repeating: false, count: chunkList[cand.chunkIndex].world.count)
                }
                masks[cand.chunkIndex]![cand.vertex] = true
            }

            let lift = SIMD3<Float>(0, cfg.hazardOverlayLift, 0)
            var triangles = 0
            outer: for (ci, mask) in masks {
                let sc = chunkList[ci]
                let idx = sc.chunk.indices
                var remap = [Int32](repeating: -1, count: sc.world.count)
                var f = 0
                while f + 2 < idx.count {
                    defer { f += 3 }
                    let a = Int(idx[f]), b = Int(idx[f + 1]), c = Int(idx[f + 2])
                    guard a < mask.count, b < mask.count, c < mask.count else { continue }
                    let hits = (mask[a] ? 1 : 0) + (mask[b] ? 1 : 0) + (mask[c] ? 1 : 0)
                    if hits < 2 { continue }
                    for vi in [a, b, c] {
                        if remap[vi] < 0 {
                            remap[vi] = Int32(overlay.positions.count)
                            overlay.positions.append(sc.world[vi] + lift)
                        }
                        overlay.indices.append(UInt32(remap[vi]))
                    }
                    triangles += 1
                    if triangles >= cfg.maxOverlayTriangles { break outer }
                }
            }
        }

        // ---- 6. Snapshot -------------------------------------------------------
        let snapshot = SceneSnapshot(
            timestamp: timestamp,
            cameraTransform: cameraTransform,
            cameraPosition: p0,
            heading: heading,
            groundHeight: ground,
            groundSource: groundSource,
            nearestObstacle: best,
            nearestForwardObstacle: bestFwd,
            sectorDistances: smoothedSectors,
            tripHazards: hazards,
            meshAnchorCount: chunks.count,
            vertexCount: totalVertices
        )
        return AnalysisResult(snapshot: snapshot, overlay: overlay, evicted: evicted)
    }

    // MARK: Ground estimation

    /// Combines the largest floor `ARPlaneAnchor` under the user with the median height of
    /// nearby floor-classified mesh vertices. The plane is the "established" ground; the mesh
    /// median protects against a stale plane from another level (ramps, split levels).
    private func estimateGround(cameraPosition p0: SIMD3<Float>) -> (Float, GroundSource) {
        let cfg = config

        // (a) Plane anchors.
        var planeY: Float?
        var bestArea: Float = 0
        for plane in planes.values where plane.isFloor {
            let c = plane.worldCenter
            let reach = max(plane.width, plane.height) * 0.5 + 1.0
            if simd_length((c - p0).xz) <= reach, plane.area > bestArea {
                bestArea = plane.area
                planeY = c.y
            }
        }

        // (b) Mesh median of floor vertices within `groundSampleRadius`, well below the phone.
        var samples: [Float] = []
        samples.reserveCapacity(min(cfg.maxGroundSamples, 4096))
        let r2 = cfg.groundSampleRadius * cfg.groundSampleRadius
        let yLo = p0.y - 2.5
        let yHi = p0.y - 0.3
        sampling: for sc in chunks.values {
            if sc.aabbMax.y < yLo || sc.aabbMin.y > yHi { continue }
            if Self.horizontalDistance(from: p0, toBox: sc.aabbMin, sc.aabbMax) > cfg.groundSampleRadius { continue }
            for i in 0..<sc.world.count where sc.vertexClasses[i] == MeshClass.floor {
                let v = sc.world[i]
                if v.y < yLo || v.y > yHi { continue }
                let dx = v.x - p0.x, dz = v.z - p0.z
                if dx * dx + dz * dz > r2 { continue }
                samples.append(v.y)
                if samples.count >= cfg.maxGroundSamples { break sampling }
            }
        }
        var meshY: Float?
        if samples.count >= cfg.minGroundSamples {
            samples.sort()
            meshY = samples[samples.count / 2]
        }

        switch (planeY, meshY) {
        case let (p?, m?):
            return abs(p - m) <= cfg.planeMeshAgreement ? (p, .planeAnchor) : (m, .meshMedian)
        case let (p?, nil):
            return (p, .planeAnchor)
        case let (nil, m?):
            return (m, .meshMedian)
        case (nil, nil):
            if let last = lastGround, abs(last - (p0.y - cfg.assumedCameraHeight)) < 1.0 {
                return (last, .meshMedian)
            }
            return (p0.y - cfg.assumedCameraHeight, .assumed)
        }
    }

    // MARK: Geometry helpers

    private static func overlaps(_ aMin: SIMD3<Float>, _ aMax: SIMD3<Float>,
                                 _ bMin: SIMD3<Float>, _ bMax: SIMD3<Float>) -> Bool {
        aMin.x <= bMax.x && aMax.x >= bMin.x &&
        aMin.y <= bMax.y && aMax.y >= bMin.y &&
        aMin.z <= bMax.z && aMax.z >= bMin.z
    }

    /// Horizontal distance from a point to an axis-aligned box (0 when inside its XZ footprint).
    private static func horizontalDistance(from p: SIMD3<Float>, toBox bMin: SIMD3<Float>, _ bMax: SIMD3<Float>) -> Float {
        let dx = max(bMin.x - p.x, 0, p.x - bMax.x)
        let dz = max(bMin.z - p.z, 0, p.z - bMax.z)
        return (dx * dx + dz * dz).squareRoot()
    }
}
