# Stickman 3D model pipeline

Source: [Stickman Blender Rig](https://sketchfab.com/3d-models/stickman-blender-rig-3e71ebb2b9fe42d699adec8a3e64828e)
by **blenderillusion** on Sketchfab — **CC-BY-4.0**. Attribution required if we
ship. `source_rig.zip` is the original `.blend` (Blender 2.79).

## Re-exporting

Requires Blender 4+ on PATH (`brew install --cask blender`). From this directory:

```sh
unzip -o source_rig.zip -d .
blender --background "source/Final Rig.blend" --python export.py
```

Produces `stickman.usdz` one level up (next to this README). Copy into
`Posture Buddy/stickman.usdz` in the iOS target to ship the update.

## Rig

Simple custom armature (not Rigify; ~30 bones). Drive-relevant chain:

```
Root → Spine_1 → Spine_2 → Spine_3 → Spine_4 → Head
```

`Head` pivots the head mesh. `Spine_4` bows the upper torso — useful if we
ever want richer slouch articulation. Body-part meshes (Head / Spine / Arm_L_1
/ Arm_L_2 / Arm_R_1 / Arm_R_2 / Leg_L_1 / Leg_L_2 / Leg_R_1 / Leg_R_2) are
skinned to the skeleton via `SkelBindingAPI`.

Model is Z-up and ~8.9m tall in model units; scale down when loading into
SceneKit (camera / root-node transform).
