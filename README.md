# Echo

Spatial navigation aid for blind and low-vision users, built for DubHacks 2026.
Echo turns an iPhone Pro's LiDAR, camera and AirPods into a parking sensor for
walking: it beeps for whatever is about to be in your way, speaks the things a beep
can't ("Step up", "Person ahead, slightly left", "Door ahead"), and can describe the
room on demand.

## What it does

- **Collision beeps.** The nearest surface in a cone ahead drives a soft, low beep
  that gets faster, louder and higher as you close in, and goes solid near contact.
  The range grows with your walking speed, and nothing beside or behind you makes a
  sound. Beeps duck while the voice is talking.
- **Spoken narration.** Trip hazards ("Step up", "Step down") are announced about a
  second and a half before your foot gets there, timed by walking speed rather than a
  fixed distance. People and animals in your path, the object you are about to reach,
  and wayfinding signs (EXIT, RESTROOM, STAIRS...) are named.
- **Describe.** One button speaks a summary: the kind of place, what is ahead and how
  far, which sides are open, people nearby, steps and signs. If you stop at an
  obstacle it tells you which side is clear.
- **Live map.** A heading-up blueprint of the room from the LiDAR mesh, with the cells
  the camera sees right now drawn live, plus a see-through rendering of the nearby
  surfaces over the camera feed.
- Haptic ticks mirror the beeps, so the phone in your hand backs up the audio.

## How it works

Everything runs on-device.

| Layer | Source | What it contributes |
| --- | --- | --- |
| ARKit scene reconstruction | LiDAR mesh | Classified surfaces (wall, floor, furniture...) in 360°, used for the map, the rendering and the sonar |
| ARKit `sceneDepth` | LiDAR + camera fused depth map | Instant, dense depth in the camera's view: drives the walking-corridor sonar and vetoes stale mesh the camera can see past (someone who walked on, a chair that moved) |
| Apple Vision | Camera image | People and animals (boxed, fused with depth for distance and bearing), classification of the object ahead and of the scene, sign text |
| Trip-hazard scan | Mesh floor vertices vs. estimated ground | Drops, curbs and steps in a corridor ahead, confirmed over several frames |
| AVAudioEngine + AVSpeechSynthesizer | | Stereo beeps with a gentle bearing nudge; spoken lines with per-kind repeat limits |

Geometry is processed on a Swift actor off the main thread; Vision runs on its own
queue with one frame in flight. A Metal surface shader fades and grids the mesh from
the camera position each frame with no CPU work.

## Requirements

- iPhone with LiDAR (12 Pro or later; built and tested on a 15 Pro Max)
- iOS 27, Xcode 26 with the Metal toolchain component installed
  (`xcodebuild -downloadComponent MetalToolchain`)
- Headphones for the directional cues. AirPods work; turn off Spatial Audio in
  Control Center for Echo so iOS does not re-process the stereo

## Build

1. Open `Echo/Echo.xcodeproj`.
2. In Signing & Capabilities, pick your team (the bundle id is `com.jasonzhou.echo`;
   change it if you need to).
3. Run on a device. The simulator has no camera or LiDAR.

## Project layout

```
Echo/Echo
├── ContentView.swift          HUD: minimap, proximity gauge, controls, settings
├── Audio/
│   ├── SpatialAudioEngine.swift   collision beeps (rate, loudness, pitch, stereo nudge)
│   └── Narrator.swift             speech: hazards, people, objects, signs, describe
├── Perception/
│   ├── ARLiDARManager.swift       ARSession, mesh ingest, depth unprojection, Vision submit
│   ├── MeshGeometryStore.swift    actor: sonar, ground, hazards, occupancy map
│   ├── VisionObserver.swift       Vision requests fused with the depth map
│   ├── PerceptionModels.swift     Sendable models + PerceptionConfig (all tunables)
│   └── SurfaceRenderer.swift      RealityKit entities + CustomMaterial
├── Shaders/EchoSurface.metal  surface fade / grid / sweep
└── Views/ARWireframeView.swift
```

Tunables live in `PerceptionConfig` (ranges, thresholds, rates) and at the top of
`SpatialAudioEngine` and `Narrator` (lead times, repeat intervals).
