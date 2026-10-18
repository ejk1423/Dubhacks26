## Inspiration

What if you could *hear* the space around you?

A white cane finds the ground. It misses the sign at head height, the person walking toward you, the door you just passed. The hardware to fix that is already in many pockets: an iPhone Pro has LiDAR, a depth camera and a neural engine, and AirPods are headphones people already wear. Echo connects them, with nothing new to buy.

## What it does

Echo is a parking sensor for walking, plus a narrator for what a beep can't say.

- **Beeps for what you'd actually hit.** Echo targets the surface closest along your walking line, within shoulder width of it. A wall you walk past is silent; the chair in your path is not. Beeps start about 1.3 s before contact at your current speed, speed up and get louder as you close in, and merge into a tone at the end. They are panned gently toward the obstacle.
- **A voice for the rest.** "Step up." "Drop-off." "Person coming toward you, on your right." "Chair ahead." "Blocked. Open on your left." "Exit sign on your right." Each line is timed by how long until you reach the thing, and said once.
- **Describe.** One button speaks what matters now: hazards, people, what is ahead and how far (by name), doorways, open sides, the width of the space, the last sign seen, the kind of place you are in.
- **A screen built for low vision.** One giant state word and distance, a map that fades into the corner, colour-coded surfaces over the camera, full VoiceOver support. Everything runs on the phone; nothing leaves it.

## How we built it

Swift, ARKit, RealityKit, Apple Vision, Metal, AVFoundation. About 6,700 lines written during the hackathon.

    LiDAR mesh + fused depth map + camera image
                  │
    MeshGeometryStore (actor, 20 Hz)       VisionObserver (4 Hz)
      ground · sonar · trip hazards          people & animals, tracked with depth
      occupancy map · doorways · objects     object naming per LiDAR cluster
                  │                          floor-patch check · scene · signs
                  └────────► SceneSnapshot ◄────────┘
                                   │
                beeps + haptics · narrator · HUD · Metal surfaces

**Geometry.** The LiDAR mesh covers every direction but lags reality by about a second; the fused depth map is instant but only sees where the camera points. The depth map is the authority inside the camera's view, and a per-frame z-buffer of it vetoes any mesh the camera can currently see *past*, so a person who walked on stops counting on the next frame. Solid points between shin and head height feed 24 sonar sectors of 15° and a walking corridor split into body and head bands. Ground comes from floor planes and floor-classified mesh, with a height-histogram fallback outdoors and a plausibility check against the phantom points LiDAR paints under glossy floors.

**Trip hazards.** A grid over the corridor ahead accumulates floor points by height relative to ground. Cells at ±10–12 cm cluster into hazards that must span the path, have nothing standing on them, and persist across frames. Each hazard carries its footprint, so a compact or tall bump (a bag, a bean bag) is "something on the floor", not a step. Drops need their lower floor confirmed by the depth camera.

**Timing.** Beeps and voice both work on time-to-reach rather than distance. With distance $d$ and closing speed $v$:

$$t = \frac{d}{v}, \qquad \text{warn when } t \le \tau \ \text{ or } \ d \le d_{\min}$$

with $\tau = 1.3$ s for beeps and $1.5$ s for "Step up". Closeness $c$, which drives cadence and loudness, is measured against the distance covered in that lead time:

$$c = \frac{r - d}{r - d_{\text{touch}}}, \qquad r = \min\!\big(r_{\max},\ \max(r_{\min},\ v\tau)\big)$$

**Vision.** The LiDAR map is clustered into discrete objects; each object's 3D box is projected into the camera image and that crop is classified, with scores that accumulate and decay across frames so a name must be seen repeatedly. People and animals are detected, tracked, given a distance from the depth inside their box and a velocity from a least-squares fit, which is how Echo knows someone is walking *toward* you. The floor patch at a hazard is classified as step, object or flat (a rug is not a step). Signs are read and remembered with a world position.

**Audio.** Beeps are synthesised in code and mixed to stereo with a constant-power pan, a 0.45 ms interaural delay and a head-shadow low-pass on the far ear. The narrator uses the best installed voice, pre-loaded at launch, and keys every line by its subject so nothing repeats while it stays true.

## Challenges we ran into

- **Deciding what deserves a sound.** Early versions beeped at everything. The fix was not better detection but a stricter definition of "in your way": in the walking line, closing in, about to be reached.
- **Directional audio.** We tried Apple's HRTF renderer twice and hard panning once before settling on a gentle constant-power pan with a small delay. The real fix was a bug: the walking heading included the phone's roll, so every bearing was already off by 10–20°.
- **Phantom geometry.** Glossy floors reflect LiDAR into points *below* the floor, causing false "step down" warnings and dragging the ground estimate down until the real floor read as an obstacle. Drops now need depth-camera confirmation and the ground estimate is bounded.
- **Stale mesh.** ARKit keeps a ghost of a person for seconds. The depth veto fixed that, then over-fixed it: windows return little depth, so the camera seemed to see past real walls and the map wiped itself. The veto now needs several confident returns and only applies up close.
- **Swift 6 concurrency.** The audio render callback was inferred as main-actor code and trapped when CoreAudio called it from its real-time thread. One `@Sendable`, found through a crash report pulled off the phone.
- **Launch load.** Mesh, shader compilation and the voice loading at once starved the audio into crackle. A warm-up window, a pre-loaded voice and a larger I/O buffer fixed it.

## Accomplishments that we're proud of

- A complete pipeline from LiDAR and camera to beeps, speech and a map, at 20 Hz on a phone, with no server.
- Silence is the normal state; a beep is a thing you are about to walk into.
- Echo names what it warns about, by fusing LiDAR clusters with the camera on-device.
- An interface designed from Apple's Human Interface Guidelines with low vision as the primary user.

## What we learned

Collecting data is the easy half. The hard part is deciding what matters and when to say it: time-to-reach instead of distance, corroboration between sensors instead of trust in one, a voice that says each thing once. Two sensors wrong in different ways (mesh that lags, depth that only looks ahead) can cover for each other if you are explicit about which to trust where. And we learned to read crash reports.

## What's next for Echo

- **"Find the door."** Echo already knows where doorways and named objects are in 3D; next is letting the user ask for one and be guided to it by the same directional audio.
- **Outdoors.** Crosswalks, traffic lights and curbs with the same camera-plus-depth corroboration.
- **Thin things.** Saliency proposals for poles, railings and glass the mesh misses.
- **Testing with blind users.** Echo was tuned by sighted testing on one phone. The timing, the voice and what is worth saying need to be shaped by the people it is for.
