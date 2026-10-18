//
//  MeshGeometryStore.swift
//  Echo
//
//  Actor that owns a copy of every LiDAR mesh chunk and does all of the heavy
//  geometry math off the main thread:
//
//    * builds render data (triangles with per-face material buckets) for each chunk,
//    * estimates the local ground plane (ARPlaneAnchor floor, cross-checked
//      against the median height of floor-classified mesh vertices),
//    * finds the nearest obstacle for the wall sonar per 15-degree sector (published
//      as 8 coarse sectors) and in a narrow corridor straight ahead, using distance
//      histograms (a bin needs several vertices, so one stray vertex is not a wall)
//      smoothed over time (approach is instant, recession is rate-limited),
//    * builds a top-down occupancy map (mesh plus this frame's depth map) for the HUD,
//    * scans a 1-3 m corridor along the walking direction for negative drops
//      (potholes, stairs) and positive spikes (curbs, rocks) relative to ground,
//      clusters them into `TripHazard`s, reports only those that persist over several
//      analyses, and emits the red overlay triangles.
//
//  The sonar fuses two sources: the accumulated mesh (full 360 degrees, but smoothed
//  and a second or so behind reality) and the live LiDAR depth map (camera field of
//  view only, but dense and instantaneous). Inside the depth map's cone the corridor
//  trusts the depth map, and any mesh the camera can currently see past is treated as
//  stale, so a person stepping in front is seen on the next analysis and stops
//  counting the moment they walk on.
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

    /// Sonar histograms: fine yaw sectors x distance bins, plus the forward corridor
    /// (one histogram for the mesh, one for the live depth map).
    private struct SonarBins {
        let nSectors: Int
        let nBins: Int
        let sectorWidth: Float
        let binSize: Float
        let maxRange: Float
        let forwardHalfWidth: Float
        var count: [Int]
        var sum: [SIMD3<Float>]
        var cls: [UInt8]
        var fwdCount: [Int]
        var fwdSum: [SIMD3<Float>]
        var fwdClass: [UInt8]
        var depthFwdCount: [Int]
        var depthFwdSum: [SIMD3<Float>]

        init(nSectors: Int, nBins: Int, config cfg: PerceptionConfig) {
            self.nSectors = nSectors
            self.nBins = nBins
            sectorWidth = 2 * .pi / Float(nSectors)
            binSize = cfg.obstacleBinSize
            maxRange = cfg.obstacleMaxRange
            forwardHalfWidth = cfg.forwardHalfWidth
            count = [Int](repeating: 0, count: nSectors * nBins)
            sum = [SIMD3<Float>](repeating: .zero, count: nSectors * nBins)
            cls = [UInt8](repeating: MeshClass.none, count: nSectors * nBins)
            fwdCount = [Int](repeating: 0, count: nBins)
            fwdSum = [SIMD3<Float>](repeating: .zero, count: nBins)
            fwdClass = [UInt8](repeating: MeshClass.none, count: nBins)
            depthFwdCount = [Int](repeating: 0, count: nBins)
            depthFwdSum = [SIMD3<Float>](repeating: .zero, count: nBins)
        }

        /// Drops one solid point into the sector histogram and, if it is in the walking
        /// corridor, into the forward histogram (`fromDepth` selects which one).
        mutating func accumulate(_ v: SIMD3<Float>, _ c: UInt8, t: Float, s: Float, fromDepth: Bool) {
            let dist = (t * t + s * s).squareRoot()
            guard dist < maxRange, dist > 0.05 else { return }
            let angle = atan2(s, t)                                   // 0 = ahead, +pi/2 = right
            var k = Int(((angle + sectorWidth / 2) / sectorWidth).rounded(.down))
            k = ((k % nSectors) + nSectors) % nSectors
            let b = min(Int(dist / binSize), nBins - 1)
            let bin = k * nBins + b
            count[bin] += 1
            sum[bin] += v
            if c != MeshClass.none { cls[bin] = c }
            guard t > 0.05, abs(s) <= forwardHalfWidth else { return }
            let fb = min(Int(t / binSize), nBins - 1)
            if fromDepth {
                depthFwdCount[fb] += 1
                depthFwdSum[fb] += v
            } else {
                fwdCount[fb] += 1
                fwdSum[fb] += v
                if c != MeshClass.none { fwdClass[fb] = c }
            }
        }
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
    private var lastHeading: SIMD3<Float>?
    private var lastPosition: SIMD3<Float>?
    private var walkingSpeed: Float = 0
    /// Fine sonar sectors (15 degrees each, index 0 centred dead ahead, clockwise).
    private static let sectorCount = 24
    private var smoothedSectors = [Float](repeating: .infinity, count: sectorCount)
    private var sectorHits = [ObstacleHit?](repeating: nil, count: sectorCount)
    private var sectorStreaks = [Int](repeating: 0, count: sectorCount)
    /// Narrow corridor straight ahead ("is there something in my path?").
    private var smoothedForward: Float = .infinity
    private var forwardHit: ObstacleHit?
    private var forwardStreak = 0
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

        // Render geometry: the real triangles, bucketed per face by class. Ceilings are
        // dropped (nothing to walk into, and they fill the view); everything else is drawn
        // and the surface shader decides how visible it is from its distance to the user.
        var keptIndices: [UInt32] = []
        keptIndices.reserveCapacity(chunk.indices.count)
        var rawMaterials: [UInt32] = []
        rawMaterials.reserveCapacity(faceCount)
        var usedBuckets = [Bool](repeating: false, count: SurfaceBucket.allCases.count)
        chunk.indices.withUnsafeBufferPointer { idx in
            for f in 0..<faceCount {
                let base = f * 3
                guard base + 2 < idx.count else { break }
                let bucket = SurfaceBucket(meshClass: chunk.faceClasses[f])
                guard bucket != .ceiling else { continue }
                keptIndices.append(idx[base])
                keptIndices.append(idx[base + 1])
                keptIndices.append(idx[base + 2])
                rawMaterials.append(bucket.rawValue)
                usedBuckets[Int(bucket.rawValue)] = true
            }
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
            center: (aabbMin + aabbMax) / 2,
            positions: chunk.localPositions,
            indices: keptIndices,
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
        lastHeading = nil
        lastPosition = nil
        walkingSpeed = 0
        smoothedSectors = [Float](repeating: .infinity, count: Self.sectorCount)
        sectorHits = [ObstacleHit?](repeating: nil, count: Self.sectorCount)
        sectorStreaks = [Int](repeating: 0, count: Self.sectorCount)
        smoothedForward = .infinity
        forwardHit = nil
        forwardStreak = 0
        trackedHazards.removeAll()
    }

    // MARK: Analysis

    /// Runs the ground estimate, obstacle sonar and trip-hazard scan for the given camera pose.
    /// `depthPoints` are world-space samples of this frame's LiDAR depth map (may be empty).
    func analyze(cameraTransform: simd_float4x4, timestamp: TimeInterval,
                 depthPoints: [SIMD3<Float>]) -> AnalysisResult {
        let cfg = config
        let p0 = cameraTransform.translation

        // Walking direction: the camera's view direction (-Z) projected onto the floor.
        // Nothing else is mixed in: adding the phone's long axis made the heading swing
        // sideways with every roll of the hand, which made every bearing wander. When the
        // phone is pointed almost straight down the projection is meaningless, so the
        // previous heading is kept.
        let camZ = SIMD3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        var heading = (-camZ).xz
        if simd_length(heading) >= 0.3 {
            heading = simd_normalize(heading)
        } else {
            heading = lastHeading ?? SIMD3(0, 0, -1)
        }
        lastHeading = heading
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

        // Walking speed (horizontal), exponentially smoothed over ~0.4 s.
        if let last = lastPosition, dt > 0.01 {
            let instantaneous = simd_length((p0 - last).xz) / dt
            let blend = min(1, dt / 0.4)
            walkingSpeed += (instantaneous - walkingSpeed) * blend
        }
        lastPosition = p0

        // The sonar works off an assumed floor height (walls span floor to ceiling), but
        // trip hazards are height differences, so they wait for a real floor.
        let hazardsEnabled = groundSource != .assumed
        if !hazardsEnabled { trackedHazards.removeAll() }

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

        let nSectors = Self.sectorCount
        let nBins = max(1, Int((cfg.obstacleMaxRange / cfg.obstacleBinSize).rounded(.up)))
        var bins = SonarBins(nSectors: nSectors, nBins: nBins, config: cfg)

        // Live depth map: no classes, but every point is a real surface seen this frame.
        // Also build a 1-degree profile of the nearest body-height depth per bearing: any
        // mesh the camera currently sees *past* (a person who has walked on, a chair that
        // moved) is stale and must not count, however recently the mesh was updated.
        var profile = [Float](repeating: .infinity, count: 360)
        for v in depthPoints {
            let dy = v.y - ground
            guard dy >= cfg.obstacleMinHeight, dy <= cfg.obstacleMaxHeight else { continue }
            let d = v - p0
            let t = d.x * heading.x + d.z * heading.z
            let s = d.x * right.x + d.z * right.z
            let dist = (t * t + s * s).squareRoot()
            let bin = Self.bearingBin(t: t, s: s)
            if dist < profile[bin] { profile[bin] = dist }
            bins.accumulate(v, MeshClass.none, t: t, s: s, fromDepth: true)
        }
        let depthProfile = profile
        let ghostMargin = cfg.ghostMargin
        func isGhost(t: Float, s: Float) -> Bool {
            let seen = depthProfile[Self.bearingBin(t: t, s: s)]
            return seen.isFinite && (t * t + s * s).squareRoot() < seen - ghostMargin
        }

        // Top-down occupancy map (world-aligned grid centred on the user).
        let mapSize = Int((2 * cfg.mapRadius / cfg.mapCellSize).rounded(.up))
        let mapOrigin = SIMD2<Float>(
            ((p0.x - cfg.mapRadius) / cfg.mapCellSize).rounded(.down) * cfg.mapCellSize,
            ((p0.z - cfg.mapRadius) / cfg.mapCellSize).rounded(.down) * cfg.mapCellSize
        )
        var mapObstacle = [UInt16](repeating: 0, count: mapSize * mapSize)
        var mapObstacleClass = [UInt8](repeating: MeshClass.none, count: mapSize * mapSize)
        var mapFloor = [UInt16](repeating: 0, count: mapSize * mapSize)
        var mapLive = [UInt16](repeating: 0, count: mapSize * mapSize)
        func mapIndex(_ v: SIMD3<Float>) -> Int? {
            let column = Int((v.x - mapOrigin.x) / cfg.mapCellSize)
            let row = Int((v.z - mapOrigin.y) / cfg.mapCellSize)
            guard column >= 0, column < mapSize, row >= 0, row < mapSize else { return nil }
            return row * mapSize + column
        }
        for v in depthPoints {
            let dy = v.y - ground
            guard dy >= cfg.obstacleMinHeight, dy <= cfg.obstacleMaxHeight, let idx = mapIndex(v) else { continue }
            mapLive[idx] += 1
        }

        for (ci, sc) in chunkList.enumerated() {
            let horizontal = Self.horizontalDistance(from: p0, toBox: sc.aabbMin, sc.aabbMax)
            let sonarRelevant =
                horizontal <= cfg.obstacleMaxRange
                && sc.aabbMax.y >= sonarYMin && sc.aabbMin.y <= sonarYMax
            let corridorRelevant = hazardsEnabled && Self.overlaps(sc.aabbMin, sc.aabbMax, corridorMin, corridorMax)
            let mapRelevant = horizontal <= cfg.mapRadius
            if !sonarRelevant && !corridorRelevant && !mapRelevant { continue }

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
                        let solid = dy >= cfg.obstacleMinHeight && dy <= cfg.obstacleMaxHeight
                            && c != MeshClass.floor && c != MeshClass.ceiling
                        let stale = solid && isGhost(t: t, s: s)
                        if sonarRelevant, solid, !stale {
                            bins.accumulate(v, c, t: t, s: s, fromDepth: false)
                        }

                        // -- Occupancy map: solid things at body height, and the floor.
                        if mapRelevant, !stale, let idx = mapIndex(v) {
                            if solid {
                                mapObstacle[idx] += 1
                                if c != MeshClass.none { mapObstacleClass[idx] = c }
                            } else if c == MeshClass.floor || abs(dy) < 0.15 {
                                mapFloor[idx] += 1
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
        func firstSolidBin(_ counts: ArraySlice<Int>, _ sums: ArraySlice<SIMD3<Float>>,
                           _ classes: ArraySlice<UInt8>) -> ObstacleHit? {
            for (bin, count) in zip(counts.indices, counts) where count >= cfg.minObstacleVertices {
                let centroid = sums[bin] / Float(count)
                return ObstacleHit(
                    point: centroid,
                    horizontalDistance: simd_length((centroid - p0).xz),
                    bucket: SurfaceBucket(meshClass: classes[bin])
                )
            }
            return nil
        }
        for k in 0..<nSectors {
            let range = (k * nBins)..<((k + 1) * nBins)
            smooth(raw: firstSolidBin(bins.count[range], bins.sum[range], bins.cls[range]),
                   distance: &smoothedSectors[k], hit: &sectorHits[k], streak: &sectorStreaks[k], dt: dt)
        }
        // Corridor: the depth map is the authority inside its cone; the mesh fills in the
        // corridor's edges that the camera cannot see.
        let meshForward = firstSolidBin(bins.fwdCount[...], bins.fwdSum[...], bins.fwdClass[...])
        var rawForward = depthPoints.isEmpty
            ? meshForward
            : firstSolidBin(bins.depthFwdCount[...], bins.depthFwdSum[...], [UInt8](repeating: MeshClass.none, count: nBins)[...])
        if let m = meshForward, m.horizontalDistance < (rawForward?.horizontalDistance ?? .infinity) {
            let d = m.point - p0
            let bearing = atan2(d.x * right.x + d.z * right.z, d.x * heading.x + d.z * heading.z)
            if depthPoints.isEmpty || abs(bearing) > cfg.depthFOVHalfAngle { rawForward = m }
        }
        smooth(raw: rawForward, distance: &smoothedForward, hit: &forwardHit, streak: &forwardStreak, dt: dt)

        let nearestSector = (0..<nSectors).min { smoothedSectors[$0] < smoothedSectors[$1] }!
        let best = sectorHits[nearestSector]
        let bestFwd = forwardHit

        // Publish 8 coarse sectors (45 degrees each) as the minimum of their 3 fine sectors.
        var coarseSectors = [Float](repeating: .infinity, count: 8)
        for k in 0..<nSectors {
            let coarse = ((k + 1) / 3) % 8
            coarseSectors[coarse] = min(coarseSectors[coarse], smoothedSectors[k])
        }

        // ---- 3. Classify cells ------------------------------------------------
        var kinds = [CellKind](repeating: .none, count: cells.count)
        for idx in 0..<cells.count where hazardsEnabled {
            let cell = cells[idx]
            let minShare = cfg.minHazardFraction * Float(cell.count)
            if cell.dropCount >= cfg.minHazardVertices, Float(cell.dropCount) >= minShare,
               cell.dropCount >= cell.bumpCount {
                kinds[idx] = .drop
            } else if cell.bumpCount >= cfg.minHazardVertices, Float(cell.bumpCount) >= minShare {
                kinds[idx] = .bump
            }
        }
        if cfg.reportUnknownSurfaces, hazardsEnabled {
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

            // A step or curb spans the path and has nothing standing on it. A one-cell ridge
            // is clutter (a cable, a chair leg), and elevated floor with solid geometry above
            // it is the foot of a wall or a piece of furniture, not something to step onto.
            if kind != .unknown {
                let columns = Set(members.map { $0 % nS })
                let underSomething = members.contains { cells[$0].obstacleCount >= cfg.minHazardVertices }
                if columns.count < cfg.minHazardWidthCells || underSomething { continue }
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

        // ---- 6. Occupancy map cells ---------------------------------------------
        var mapCells = [UInt8](repeating: 0, count: mapSize * mapSize)
        let minVertices = UInt16(cfg.mapMinVertices)
        for idx in 0..<mapCells.count {
            var cell = OccupancyMap.Cell.empty
            if mapObstacle[idx] >= minVertices {
                switch mapObstacleClass[idx] {
                case MeshClass.wall, MeshClass.door, MeshClass.window: cell = .wall
                case MeshClass.table, MeshClass.seat:                   cell = .furniture
                default:                                                cell = .obstacle
                }
            } else if mapFloor[idx] >= minVertices {
                cell = .floor
            }
            var value = cell.rawValue
            if mapLive[idx] >= 2 {
                if cell == .empty || cell == .floor { value = OccupancyMap.Cell.obstacle.rawValue }
                value |= OccupancyMap.liveFlag
            }
            mapCells[idx] = value
        }
        let map = OccupancyMap(origin: mapOrigin, cellSize: cfg.mapCellSize, size: mapSize, cells: mapCells)

        // ---- 7. Snapshot -------------------------------------------------------
        let snapshot = SceneSnapshot(
            timestamp: timestamp,
            cameraTransform: cameraTransform,
            cameraPosition: p0,
            heading: heading,
            groundHeight: ground,
            groundSource: groundSource,
            nearestObstacle: best,
            nearestForwardObstacle: bestFwd,
            sectorDistances: coarseSectors,
            fineSectorHits: sectorHits,
            map: map,
            tripHazards: hazards,
            walkingSpeed: walkingSpeed,
            meshAnchorCount: chunks.count,
            vertexCount: totalVertices
        )
        return AnalysisResult(snapshot: snapshot, overlay: overlay, evicted: evicted)
    }

    // MARK: Sonar smoothing

    /// Approaching readings take effect at once (a brand-new obstacle must be seen twice);
    /// receding or missing readings release at `obstacleReleaseRate` so one missed scan
    /// does not flicker.
    private func smooth(raw: ObstacleHit?, distance: inout Float, hit: inout ObstacleHit?,
                        streak: inout Int, dt: Float) {
        streak = raw == nil ? 0 : streak + 1
        if let raw, raw.horizontalDistance <= distance {
            if distance.isFinite || streak >= 2 {
                distance = raw.horizontalDistance
                hit = raw
            }
        } else if distance.isFinite {
            let receded = distance + config.obstacleReleaseRate * dt
            if let raw, raw.horizontalDistance <= receded {
                distance = raw.horizontalDistance
                hit = raw
            } else if receded >= config.obstacleMaxRange {
                distance = .infinity
                hit = nil
            } else {
                distance = receded
                if let old = hit {
                    hit = ObstacleHit(point: old.point, horizontalDistance: receded, bucket: old.bucket)
                }
            }
        }
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

    /// 1-degree bearing bin (0 = directly behind, 180 = ahead) for the depth profile.
    private static func bearingBin(t: Float, s: Float) -> Int {
        let degrees = atan2(s, t) * 180 / .pi + 180
        return min(359, max(0, Int(degrees)))
    }

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
