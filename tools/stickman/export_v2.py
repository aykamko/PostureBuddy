"""Export the user's hand-baked Blender → stickman.usdz.

Source file: `posture_buddy_v3_baked.blend`. The animation has already been
baked in Blender's UI ("Bake Action" with Visual Keying + Clear Constraints),
so every pose bone has per-frame FK keyframes and nothing depends on IK /
Spline IK / drivers anymore. Our job is just to clean up leftover widgets
and export.
"""

import bpy, os

OUT = "/Users/aleks/projects/Posture Buddy/Posture Buddy/stickman.usdz"

scene = bpy.context.scene
scene.frame_start = 0
scene.frame_end = 50

# Idempotent: ensure BodyMesh's armature modifier points at Ctrl_Rig.
if 'BodyMesh' in bpy.data.objects and 'Ctrl_Rig' in bpy.data.objects:
    mesh = bpy.data.objects['BodyMesh']
    ctrl = bpy.data.objects['Ctrl_Rig']
    for m in mesh.modifiers:
        if m.type == 'ARMATURE' and m.object is not ctrl:
            print(f"Repointing BodyMesh.{m.name!r} -> {ctrl.name!r}")
            m.object = ctrl

# Drop anything that isn't the skinned mesh or the rig.
KEEP = {'BodyMesh', 'Ctrl_Rig'}
victims = [o for o in list(bpy.data.objects) if o.name not in KEEP]
print(f"Removing {len(victims)}: {[o.name for o in victims]}")
for o in victims:
    bpy.data.objects.remove(o, do_unlink=True)

# Collapse kept objects into the scene master collection + unhide.
master = scene.collection
for col in list(bpy.data.collections):
    for o in list(col.objects):
        col.objects.unlink(o)
for o in bpy.data.objects:
    if o.name not in [ob.name for ob in master.objects]:
        master.objects.link(o)
    o.hide_viewport = False
    o.hide_render = False
    o.hide_set(False)
for col in list(bpy.data.collections):
    if not col.objects and not col.children:
        bpy.data.collections.remove(col)

print("\n=== scene before export ===")
for o in bpy.data.objects:
    print(f"  {o.type:<10} {o.name!r}")

bpy.ops.object.select_all(action='SELECT')
bpy.ops.wm.usd_export(
    filepath=OUT,
    selected_objects_only=False,
    export_animation=True,
    export_armatures=True,
    export_materials=True,
    export_meshes=True,
    export_uvmaps=True,
    export_normals=True,
    generate_preview_surface=True,
    root_prim_path='/root',
)
print(f"\nExported → {OUT}  size={os.path.getsize(OUT)} bytes  "
      f"(frames {scene.frame_start}-{scene.frame_end} @ {scene.render.fps} fps)")
