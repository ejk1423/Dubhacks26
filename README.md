# Echo

Spatial navigation aid for blind and low-vision users, built at DubHacks 2026
(Community Kitchen track). Echo turns an iPhone Pro's LiDAR, camera and headphones
into a parking sensor for walking: it beeps for whatever you are about to walk into,
speaks the things a beep can't ("Step up", "Person coming toward you", "Chair ahead"),
and describes the room on demand. Everything runs on the phone; nothing leaves it.

Built and tested on an iPhone 15 Pro Max. About 6,700 lines of Swift and Metal,
written during the hackathon.

---

## What it does

### 1. Collision beeps for what you'd actually hit

- The sonar picks **the surface with the shortest distance along your walking line**
  among everything within shoulder width (±0.5 m) of it, inside a 40° cone and 1.6 m.
  A wall a metre to your side as you walk past it makes no sound; the chair in your
  path does.
- Beeps are timed by **time-to-collision**, not distance: they start when you are about
  1.3 s from contact at your current closing speed, or inside 0.35 m regardless. Standing
  in front of something, or walking past it, is silent.
- One pitch (520 Hz; a fifth higher for head-height obstacles). Urgency is carried by
  cadence and loudness: one beep every 1.4 s far out, down to one every 0.2 s, and in
  the last stretch the beeps run together into a continuous tone, as a parking sensor
  does at the bumper.
- Beeps are panned toward the obstacle with a constant-power pan, a 0.45 ms interaural
  delay and a head-shadow low-pass on the far ear, capped so a cue never sits fully in
  one ear. A Stereo Width setting scales it.
- The target's distance and bearing are smoothed (approach instant, recede gentle) and
  tracked with hysteresis, and the pan is computed for where the obstacle will be ~100 ms
  later, so the sound never hops between two obstacles or twitches with sonar noise.
- Beeps duck while the voice is speaking. A haptic tick accompanies every beep. Settings
  offer Beeps / Haptics only / Off.

### 2. Spoken narration, timed to matter

A narrator (`AVSpeechSynthesizer`, best installed English voice, premium preferred)
speaks only what a beep cannot convey, and only when it is about to matter. Timing is by
**time-to-reach** (distance over walking speed), so a step 2 m away is silent while you
stand still and "Step up" lands about 1.5 s before your foot gets there.

The standard level (shown as *Normal*) says:
- **Trip hazards**: "Step up", "Step down", "Drop-off" (floor ends), "Something on the
  floor" / "Bag on the floor ahead" for objects, "Watch your step" when the evidence is
  weak but you are within 0.5 m. Preceded by a two-tone chime. Once per hazard.
- **People and animals** in your walking line, and "Person coming toward you" (with a
  side) when the camera has tracked someone closing in for at least a second.
- **"Blocked. Open on your left"** (or a doorway's side) once per stop, when you have
  stood against something for a moment.
- **Safety signs** read from the camera: Exit, Emergency, Caution, No entry.

*More* adds the object ahead by name, "Low overhead", doorways coming up, "Path clear",
"Narrowing" / "Opening up", all signs with their side. *Everything* adds people nearby
and shorter repeats. Nothing is repeated while it stays true; every line has its own
repeat limit, and the level is persisted.

### 3. Describe

One button speaks a summary ordered by importance: hazards and people coming at you,
what is ahead and how far (by name when known), other named objects by side ("Table
about a metre on your right"), doorways, which sides are open, the width of the space,
the last sign seen ("Exit sign was on your right, a moment ago"), and the kind of place
("You're in a hallway"). Distances are natural ("about a metre", "right in front of you").

### 4. The screen, built for low vision

- **One layout.** The way ahead in giant type at the bottom: the state word with a
  symbol ("Clear ahead", "Chair ahead", "Slow down", "Stop", "Step up", "Drop-off", "On
  the floor") above the distance in metres; both in fixed slots so nothing shifts.
  Colour (green / amber / red) is never the only carrier.
- **Map** floating in the top-right corner with no frame: a soft dark backing that fades
  into the camera. Heading-up, with a smoothed heading so it turns without jitter.
  Walls are drawn as connected line strokes, furniture and unclassified obstacles as
  cells, the floor faintly, cells the depth camera sees *right now* in blue, doorways as
  white bars, trip hazards as orange triangles, people as teal dots (filled when walking
  toward you), the sonar target as a blue dot, and you as a red arrow. Tap for a
  full-screen map with metre rings, the alert cone, a legend and Ahead/Right/Behind/Left
  distances.
- **Surfaces over the camera.** The LiDAR mesh is drawn as a faint fill with a glowing
  20 cm grid that fades out by 4 m. Colour is spent sparingly: walls, floor and
  unclassified mesh are neutral; furniture and obstacles are amber; trip hazards red.
- **Controls:** Describe (prominent), mute, settings. Problems such as "No headphones"
  or "Finding the floor" appear as one small line under the state.
- First-run tutorial, VoiceOver labels on everything with announcements only on
  meaningful state changes, Dynamic Type, solid surfaces under Reduce Transparency /
  Increase Contrast, no animation under Reduce Motion. Apple HIG throughout: system
  Liquid Glass buttons, system text styles, semantic colour.

---

## How it works

### Pipeline

```
ARKit (60 Hz)
 ├─ ARMeshAnchor (LiDAR scene reconstruction, classified)  ──┐
 ├─ sceneDepth (LiDAR + camera fused depth, 256×192)       ──┤
 └─ capturedImage ───────────────────────────────────────┐   │
                                                         │   ▼
                                     VisionObserver      │  MeshGeometryStore (actor, 20 Hz)
                                     (4 Hz, own queue)   │   ├─ ground estimate
                                      ├─ people/animals ◄┘   ├─ sonar: 24 sectors + corridor
                                      ├─ object names ◄───── ├─ trip hazards + edges
                                      ├─ scene + signs       ├─ occupancy map, doorways
                                      └─ floor-patch check   ├─ object clusters
                                                             └─ clearance, approach
                                                   ▼
                        SceneSnapshot (Sendable, every analysis)
                                                   ▼
            SpatialAudioEngine      Narrator       HUD (SwiftUI)     SurfaceRenderer
            beeps, haptics          speech         map, state        RealityKit + Metal
```

Everything that crosses a thread boundary is a `Sendable` value type (Swift 6 strict
concurrency, default main-actor isolation). Geometry runs on an actor; Vision on a
serial queue with one frame in flight; rendering on RealityKit with a custom Metal
surface shader. The main thread only copies mesh buffers and schedules work.

### Geometry (`MeshGeometryStore`)

- **Mesh ingest.** Each `ARMeshAnchor` is copied out of its Metal buffers into a
  `MeshChunk` (world-space vertices, per-vertex class derived from face classification).
  At most two anchors per frame are converted and three are in flight, so a burst of
  mesh updates never stalls rendering; chunks farther than 15 m are evicted.
- **Depth fusion.** Every analysis unprojects the full-resolution depth map (medium
  confidence or better) with the camera intrinsics into world points. Depth is
  instantaneous and dense; the mesh is complete but a second behind. Depth drives the
  walking corridor inside the camera's cone, the mesh fills in everything else.
- **Stale-mesh veto.** A 48×36 camera-space z-buffer of this frame's depth answers "can
  the camera see past this mesh point along its line of sight?" Mesh within 3 m that the
  camera sees ≥0.3 m past, in a cell with at least four confident returns, is ignored
  by the sonar (≥0.8 m for the map), so a person who walked on stops counting on the
  next frame, while windows and glossy surfaces, which return little, cannot erase a
  real wall.
- **Ground.** Floor-classified `ARPlaneAnchor`s cross-checked against the median height
  of floor-classified mesh within 3 m; outdoors, where nothing is classified, a 2.5 cm
  height histogram of all mesh 0.6–2.5 m below the phone. Any estimate not 0.6–2.3 m
  below the phone is rejected (LiDAR multipath paints phantom points under glossy
  floors) and the last good value is kept. Trip-hazard detection waits for a real floor;
  the sonar runs on the assumed height.
- **Sonar.** Solid points between 0.30 m and 2.0 m above ground go into 24 yaw sectors
  (15°) × 10 cm distance bins; a bin needs eight points, so one stray vertex is never a
  wall. The forward corridor (±0.4 m) is split into a body band and a head band
  (≥1.5 m), each with its own histogram, so a sign or branch is reported separately.
  Readings approach instantly and recede at 3 m/s; a new obstacle must be seen twice.
- **Trip hazards.** A 20 cm grid over a corridor 0.3–2.5 m ahead accumulates
  floor-ish vertices by height relative to ground. A cell is a drop at ≤ −12 cm or a bump
  at ≥ +10 cm with eight vertices and 40 % of its floor points; cells flood-fill into
  hazards that must span ≥2 cells across the path, have nothing standing on them, and
  persist for five analyses (≈0.25 s) within 0.3 m. Each hazard carries its footprint:
  compact ones (< 0.6 m across) or tall ones (≥ 25 cm), or any bump the body-height sonar
  also sees as an obstacle, are objects on the floor, not steps. A drop needs its lower
  floor confirmed (depth returns below it, or floor-classified mesh), and a cell where
  the depth camera sees floor at normal height cannot be a drop. **Edges** where the
  floor simply ends inside the live depth view are reported as drop-offs after eight
  frames, with a drag check so a dark floor at the depth map's confidence limit does not
  masquerade as an edge.
- **Occupancy map.** A world-aligned 6 m × 6 m grid of 2.5 cm cells: floor, wall,
  furniture, obstacle, plus a *live* flag for cells the depth camera sees this frame.
  It is cleaned before drawing (lone cells dropped, gaps filled by majority) and walls
  are joined into line strokes on a 5 cm grid.
- **Doorways.** 120 rays at 3° are marched through a 15 cm coarsening of the map. A gap
  is a run of rays reaching ≥0.8 m past a left flank and closed by a right flank at about
  the same distance, 0.7–3 m wide, with floor seen through it; wall-classified flanks
  make it a doorway. Persisted by position, published after four hits.
- **Objects.** Non-wall obstacle cells are clustered (10 cm grid, 8-connected) into
  discrete things with a footprint, height, nearest distance and bearing; the six
  nearest are published for the camera to name.
- **Clearance and approach.** Lateral clearance left and right of the walking line
  0.5–2 m ahead; the forward target's own velocity (user motion removed) from a
  least-squares fit over 0.7 s, flagged as approaching at ≥0.35 m/s for two analyses.
- **Walking speed** is estimated from camera motion and smoothed over ~0.4 s; the
  heading is the camera's view direction projected onto the floor.

### Vision (`VisionObserver`)

Apple's on-device Vision framework on the camera image, four passes a second, each
fused with the depth map and the camera geometry:

- **People and animals** (`VNDetectHumanRectanglesRequest`, `VNRecognizeAnimalsRequest`):
  each box's distance is the 30th percentile of confident depth in its centre, its
  bearing comes from unprojecting the box centre. Detections are matched to short-lived
  tracks (1.5 s) by bearing and distance; position is smoothed and a least-squares fit
  over 1.4 s gives closing speed and the person's own world-frame velocity, so
  "coming toward you" means they are walking at you, not that you are walking at them.
- **Object names**: each nearby LiDAR object's 3D box is projected into the image and
  that crop is classified (`VNClassifyImageRequest`, ~1,300 classes). Scores accumulate
  per object across passes and decay, so a name must be seen repeatedly and one bad
  frame cannot rename a chair. Names that contradict the scene (a "car" indoors) are
  rejected. A fallback classifies the crop around the sonar target directly.
- **Floor patch at a hazard**: the image region around the nearest trip hazard is
  classified and voted 2-of-3 into *step* (stairs, curb, ramp…), *object* (bag, box,
  shoes, bean bag…) or *flat* (rug, mat, cable, threshold, plain floor). "Step up" far
  out needs strong geometry or the camera's agreement; flat patches are ignored.
- **Scene**: whole-image classification voted over five passes ("Hallway", "Kitchen",
  "Street"…) and an indoors/outdoors judgement.
- **Signs**: `VNRecognizeTextRequest` every third pass; wayfinding words (EXIT,
  RESTROOM, STAIRS, PUSH, room numbers…) are kept with a world position for 60 s so
  the narrator can say where a sign was relative to where you now face.

### Audio (`SpatialAudioEngine`, `Narrator`)

- `AVAudioEngine` with a `.playback` session (never `.playAndRecord`, which drops
  AirPods to mono), 48 kHz, 23 ms I/O buffer; the graph restarts itself on route
  changes and interruptions. Beeps are synthesised in code (sine with a faint 2.5 f
  partial and a 1 ms onset tick, so the ear can place them) and mixed to stereo per beep.
- Earcons: a two-tone chime before spoken warnings, a soft tick when the path clears
  after being blocked.
- The narrator pre-loads the voice at launch, interrupts for hazards, keys every line
  by what it is about (hazard id, person track, object name, sign text) and throttles
  per key, with a global spacing between lines of the same kind.

### Rendering (`SurfaceRenderer`, `EchoSurface.metal`)

One `ModelEntity` per mesh anchor, real triangles (ceilings dropped) with per-face
material buckets. A RealityKit `CustomMaterial` surface shader reads the camera
position from the view transform each frame and computes a distance fade (full to
2.2 m, gone by 4 m), a world-space 20 cm grid and a per-class strength passed through
the material's custom parameter, so nothing is rebuilt on the CPU as you move. Chunks
beyond 4 m are culled by their stored world centre.

### Launch

For the first five seconds the analysis runs at ~8 Hz on every third depth pixel, mesh
rebuilds are rationed to one per frame and Vision waits, so the main thread stays
responsive while the mesh floods in and shader pipelines compile.

---

## Honest limits

- Needs an iPhone with LiDAR; ARKit only exposes the 1× wide camera for world tracking,
  so there is no ultra-wide scan.
- Edge (drop-off) detection only fires when the floor beyond the edge is inside the
  live depth view, i.e. with the phone tilted somewhat down. It is deliberately
  conservative.
- Object naming is a classifier on a crop, not a detector: it names the most prominent
  thing in the crop and can be wrong on unusual objects. People are boxed and reliable.
- Glossy floors and large windows degrade LiDAR; the ground and veto guards above are
  there for that, but they are guards, not a cure.
- Not yet tested with blind users. Tuned by sighted testing on one phone.

---

## Requirements

- iPhone with LiDAR (12 Pro or later; built and tested on a 15 Pro Max)
- iOS 26 or later for Liquid Glass (the app targets iOS 18 with material fallbacks);
  Xcode 26 with the Metal toolchain component (`xcodebuild -downloadComponent MetalToolchain`)
- Headphones for the directional cues. AirPods work; turn off Spatial Audio in
  Control Center for Echo so iOS does not re-process the stereo.

## Build

1. Open `Echo/Echo.xcodeproj`.
2. In Signing & Capabilities, pick your team (bundle id `com.jasonzhou.echo`; change it
   if you need to).
3. Run on a device. The simulator has no camera or LiDAR.

## Project layout

```
Echo/Echo
├── ContentView.swift             HUD composition; wires perception → audio, narrator, HUD
├── Views/
│   ├── HUDStyle.swift            spacing scale, Liquid Glass surfaces, button styles, haptics
│   ├── ProximityDisplay.swift    the focal point: state word + distance in fixed slots
│   ├── ProximityState.swift      one value for the way ahead; VoiceOver announcer
│   ├── HUDBar.swift              Describe, control group, map panel
│   ├── MinimapView.swift         map (raster + wall lines + markers), full-screen map, legend
│   ├── OnboardingView.swift      first-run tutorial
│   ├── SettingsView.swift        sound, voice, display, map, help, about
│   ├── HUDPreferences.swift      persisted settings
│   └── ARWireframeView.swift     the ARView
├── Audio/
│   ├── SpatialAudioEngine.swift  target choice, time-to-collision beeps, stereo rendering, earcons
│   └── Narrator.swift            speech policy, naming, describe
├── Perception/
│   ├── ARLiDARManager.swift      ARSession, mesh ingest, depth unprojection, Vision submission
│   ├── MeshGeometryStore.swift   actor: ground, sonar, hazards, edges, map, doorways, objects
│   ├── VisionObserver.swift      Vision requests fused with depth; tracks, names, signs
│   ├── PerceptionModels.swift    Sendable models + PerceptionConfig (every tunable)
│   └── SurfaceRenderer.swift     RealityKit entities + CustomMaterial
└── Shaders/EchoSurface.metal     distance fade, grid, per-class strength
```

Tunables live in `PerceptionConfig` (ranges, thresholds, rates) and at the top of
`SpatialAudioEngine` and `Narrator` (lead times, repeat intervals).
