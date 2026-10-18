## Inspiration

We started from a simple question: what if you could *hear* the space around you?

A white cane finds the ground. It does not find the sign at head height, the person walking toward you, the open door you just passed, or the chair someone moved into the hallway. The hardware to fix that is already in a lot of pockets: an iPhone Pro has a LiDAR scanner, a depth camera, and a neural engine, and AirPods are the headphones people already wear. We wanted to connect those pieces into something a blind or low-vision person could use the moment they walk out the door, with no new device to buy. That became Echo.

## What it does

Echo is a parking sensor for walking, plus a narrator for everything a beep cannot say.

- **Beeps for what you would actually hit.** Echo picks the surface with the shortest distance *along your walking line*, inside shoulder width of it, and beeps for that. A wall you are walking past is silent; the chair in your path is not. The beeps start about 1.3 seconds before contact at your current speed, get closer together and louder as you close in, and run into a continuous tone at the end. They are panned toward the obstacle, gently, so a doorframe on your left sounds on your left.
- **A voice for the rest.** "Step up." "Step down." "Drop-off." "Person coming toward you, on your right." "Chair ahead." "Blocked. Open on your left." "Exit sign on your right." Each line is timed by how long until you reach the thing, not by a fixed distance, so nothing is announced while you stand still, and each is said once.
- **Describe.** One button speaks what matters now, most important first: hazards, people, what is ahead and how far (by name), other objects by side, doorways, which sides are open, the width of the space, the last sign seen, and the kind of place you are in.
- **A screen built for low vision.** One giant state word and distance, a map in the corner that fades into the camera, colour-coded surfaces over the feed, and full VoiceOver support. Everything runs on the phone; no network, nothing leaves the device.

## How we built it

Swift, ARKit, RealityKit, Apple Vision, Metal, AVFoundation. About 6,700 lines written over the hackathon.

```
LiDAR mesh + fused depth map + camera image
        │
        ▼
MeshGeometryStore (actor, 20 Hz)        VisionObserver (4 Hz)
  ground · sonar · trip hazards           people & animals (tracked, with depth)
  occupancy map · doorways · objects      object naming (per LiDAR cluster, voted)
        │                                 floor-patch check · scene · signs
        └──────────► SceneSnapshot ◄──────────┘
                           │
          beeps + haptics · narrator · HUD · Metal surfaces
```

**Geometry.** ARKit's LiDAR mesh gives us classified surfaces in every direction but lags reality by about a second; the fused depth map is instant but only sees where the camera points. We use both: the depth map is the authority inside the camera's view, and a per-frame z-buffer of it vetoes any mesh the camera can currently see *past*, so a person who walked on stops counting on the next frame. Solid points between shin and head height go into 24 sonar sectors of 15° and a walking corridor split into body and head bands. The ground is estimated from floor planes and floor-classified mesh, with a height-histogram fallback for outdoors, and a plausibility check that rejects the phantom points LiDAR paints under glossy floors.

**Trip hazards.** A grid over the corridor ahead accumulates floor points by height relative to ground. A cell is a step at ±10–12 cm; cells cluster into hazards that must span the path, have nothing standing on them, and persist across frames. Each hazard carries its footprint, so a compact or tall bump (a bag, a bean bag) is "something on the floor", not a step. Drops need their lower floor confirmed by the depth camera.

**Timing.** Both the beeps and the voice work on time-to-reach rather than distance. With distance $d$ and closing speed $v$,

$$t_{\text{reach}} = \frac{d}{v}, \qquad \text{warn when } t_{\text{reach}} \le \tau \ \text{ or } \ d \le d_{\min}$$

with $\tau = 1.3\,\text{s}$ for beeps and $1.5\,\text{s}$ for "Step up". The HUD's closeness, which drives cadence and loudness, is measured against the distance you cover in that lead time:

$$c = \frac{r - d}{r - d_{\text{touch}}}, \qquad r = \min\big(r_{\max},\ \max(r_{\min},\ v\,\tau)\big)$$

**Vision.** The LiDAR map is clustered into discrete objects; each object's 3D box is projected into the camera image and that crop is classified, with scores that accumulate and decay across frames so a name has to be seen repeatedly. People and animals are detected, matched to tracks, and given a distance from the depth map inside their box and a velocity from a least-squares fit, which is how Echo knows someone is walking *toward* you rather than you toward them. The floor patch at a hazard is classified as step, object, or flat (a rug is not a step). Signs are read and remembered with a world position.

**Audio.** Beeps are synthesised in code and mixed to stereo per beep with a constant-power pan, a 0.45 ms interaural delay and a head-shadow low-pass on the far ear. The narrator uses the best installed voice, pre-loaded at launch, and keys every line by what it is about so nothing repeats while it stays true.

## Challenges we ran into

- **Deciding what deserves a sound.** A room has walls, floors, furniture, people and a thousand small surfaces. Our first versions beeped at everything and were unusable. The answer was not better detection but a stricter definition of "in your way": in the walking line, closing in, about to be reached.
- **Directional audio.** We tried Apple's HRTF renderer twice and hard panning once before landing on a gentle constant-power pan with a small time delay. The real breakthrough was a bug: the walking heading was mixing in the phone's roll, so every bearing we handed the audio was already wrong by 10–20°.
- **Phantom geometry.** Glossy floors reflect LiDAR and paint points *below* the floor, which produced false "step down" warnings and even dragged the ground estimate down until the real floor registered as an obstacle. We had to corroborate drops with the depth camera and bound the ground estimate.
- **Stale mesh.** ARKit keeps a ghost of a person for seconds after they leave. The depth z-buffer veto fixed it, and then over-fixed it: windows and screens return little depth, so the camera appeared to "see past" real walls and the map wiped itself. The veto now needs several confident returns and only applies up close.
- **Swift 6 concurrency.** The audio render callback was inferred as main-actor code and the runtime trapped the moment CoreAudio called it from its real-time thread. One `@Sendable`, found through a crash report pulled off the phone.
- **Launch load.** Mesh flooding in, shaders compiling and the premium voice loading all at once starved the audio and made speech crackle. A warm-up window, a pre-loaded voice and a larger I/O buffer fixed it.

## Accomplishments that we're proud of

- A complete, working pipeline from LiDAR and camera to beeps, speech and a map, running at 20 Hz on a phone with no server.
- The beeps mean something: silence is the normal state, and a beep is a thing you are about to walk into.
- Echo names what it warns about. "Chair ahead" is more useful than "something ahead", and it comes from fusing LiDAR clusters with the camera, not from a cloud API.
- The interface was designed from Apple's Human Interface Guidelines with low vision as the primary user, not an afterthought.

## What we learned

Collecting data is the easy half. Everything hard was deciding what matters and when to say it: time-to-reach instead of distance, corroboration between sensors instead of trusting one, and a voice that says each thing once. We also learned that two sensors that are each wrong in different ways (mesh that lags, depth that only sees ahead) can cover for each other if you are explicit about which one to trust where. And we learned to read crash reports.

## What's next for Echo

- **"Find the door."** Echo already knows where doorways and named objects are in 3D. The next step is letting the user ask for one and guiding them to it with the same directional audio.
- **Outdoors.** Crosswalks, traffic lights and curbs with the same camera-plus-depth corroboration we use indoors.
- **Thin things.** Saliency-based proposals for poles, railings and glass that the mesh misses.
- **Testing with blind users.** Echo has been tuned by sighted testing on one phone. The timing, the voice, and what is worth saying need to be shaped by the people it is for.
