# Stickman 3D model pipeline

Assets → `stickman.usdz` used by `PostureBuddy3DView`.

## Source assets

Both `.blend` files live in `assets/` at the repo root:

| File | Source | License |
|---|---|---|
| `posture_buddy_v3_baked.blend` | Game-ready rigged stickman, animated in Blender from upright (frame 0) to fully slouched (frame 50). Pose already baked to plain FK keyframes via `Object > Animation > Bake Action` with *Visual Keying* + *Clear Constraints*. | (project-owned; see Sketchfab original) |
| `chairoff.blend` | [SwivelChair](https://sketchfab.com/3d-models/swivel-chair-...) office chair by Sketchfab author. Static mesh, no rigging. | CC-BY |

Attribution required if we ship: mention both authors in the app's About / credits screen.

## Re-exporting

Requires Blender 5 (`brew install --cask blender`).

```sh
# From the repo root:
./tools/stickman/export.sh
```

That runs `tools/stickman/export.py` headless against `assets/posture_buddy_v3_baked.blend`. The Python script:

1. Repoints `BodyMesh`'s armature modifier at `Ctrl_Rig` (idempotent).
2. Strips everything except `BodyMesh` + `Ctrl_Rig`.
3. Appends `chairoff.blend`, scales + positions it under the buddy.
4. Splits the head off `BodyMesh` into its own `HeadMesh` with a dedicated material (so the Swift side can tint the head by swapping `material.diffuse.contents`).
5. Exports with `export_animation=True` to bake all 51 frames of keyframes.
6. Renders a preview PNG alongside the USDZ.

Outputs, written next to the iOS source:
- `Posture Buddy/stickman.usdz` — the asset the app loads.
- `Posture Buddy/stickman_preview.png` — a quick Eevee render at frame 0 so you can sanity-check pose/chair alignment without launching the app.

To export from a different `.blend`:

```sh
./tools/stickman/export.sh ~/path/to/other.blend
```

## Rig overview

Ctrl_Rig has 64 bones. The Swift side cares about:

```
Root → Spine → Spine_Main → Spine_T4 → Spine_T3 → Spine_T2 → Spine_T1
                                     ↓
                                    Head
                       UpperArm_L → LowerArm_L → …
                       UpperArm_R → LowerArm_R → …
                       UpperLeg_L → LowerLeg_L → …
                       UpperLeg_R → LowerLeg_R → …
```

Bendy subdivisions (`*_002..*_005`) carry the actual skin weights and animate along with their parent main bone. Since the export bakes all frames as FK keyframes, there's no runtime IK / Spline IK / driver evaluation — SceneKit just replays the baked skel animation.

Model is Z-up in Blender; `PostureBuddy3DView` wraps the imported tree in an `axisFix` node that rotates −90° around X to stand the figure upright in SceneKit's Y-up world.
