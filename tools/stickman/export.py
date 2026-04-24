"""Export the user's hand-baked Blender → stickman.usdz.

Source file: `posture_buddy_v3_baked.blend`. The animation has already been
baked in Blender's UI ("Bake Action" with Visual Keying + Clear Constraints),
so every pose bone has per-frame FK keyframes and nothing depends on IK /
Spline IK / drivers anymore. We also append a chair mesh (`chairoff.blend`)
into the scene, parent it to a container, and scale + position it so the
buddy ends up seated on it.
"""

import bpy, os, math

# Paths are resolved from this script's location so the pipeline works no
# matter where it's invoked from:
#   <repo-root>/tools/stickman/export.py
#   <repo-root>/assets/chairoff.blend
#   <repo-root>/Posture Buddy/stickman.usdz
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT  = os.path.abspath(os.path.join(_SCRIPT_DIR, "..", ".."))
OUT         = os.path.join(_REPO_ROOT, "Posture Buddy", "stickman.usdz")
CHAIR_BLEND = os.path.join(_REPO_ROOT, "assets", "chairoff.blend")

# Chair comes in at ~14 Blender units tall from Sketchfab; buddy is ~2 units.
# Scale the chair by ~0.08 so its seat lands near the buddy's butt height.
# The chair was modeled far from its own origin (seat center ≈ (8.03, -0.31,
# 8.16)); shift translation to cancel that offset + a little extra lift so
# the seat top meets the buddy's butt.
CHAIR_SCALE = 0.07
# Pre-scale offset from Blender origin → where we want chair to sit (in
# the container's local space, i.e. Blender Z-up at chair scale). X/Y cancel
# the chair's own model offset; Z keeps the seat at the buddy's butt height
# even after scale changes (base drops with scale, shortening leg dangle).
CHAIR_TRANSLATION = (-0.562, -0.08, 0.30)  # x centered, nudged slightly back + up
CHAIR_EULER_Z = math.radians(0)           # yaw

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

# Append the chair from chairoff.blend. Everything (meshes, empties, curve)
# stays in one container so we can scale/position as a group.
print(f"\nAppending chair from {CHAIR_BLEND}")
with bpy.data.libraries.load(CHAIR_BLEND, link=False) as (data_from, data_to):
    data_to.objects = list(data_from.objects)
chair_objs = [o for o in data_to.objects if o is not None]
for o in chair_objs:
    scene.collection.objects.link(o)

chair_container = bpy.data.objects.new("ChairContainer", None)
scene.collection.objects.link(chair_container)
chair_container.scale = (CHAIR_SCALE, CHAIR_SCALE, CHAIR_SCALE)
chair_container.location = CHAIR_TRANSLATION
chair_container.rotation_euler = (0, 0, CHAIR_EULER_Z)

# Re-parent every top-level appended object (no parent within the chair set)
# to our container so scale + translation propagate.
appended_names = {o.name for o in chair_objs}
for o in chair_objs:
    if o.parent is None or o.parent.name not in appended_names:
        o.parent = chair_container

print(f"  appended {len(chair_objs)} chair objects")

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

# Split the head off of BodyMesh into its own HeadMesh with a dedicated
# material instance, so Swift can tint the head's diffuse directly without
# any shader-modifier tricks. Vertices selected via the `Head` vertex group.
body_obj = bpy.data.objects.get('BodyMesh')
if body_obj is not None:
    head_vg = body_obj.vertex_groups.get('Head')
    if head_vg is None:
        print("WARN: Head vertex group not found; skipping head split")
    else:
        bpy.context.view_layer.objects.active = body_obj
        for o in bpy.context.view_layer.objects:
            o.select_set(False)
        body_obj.select_set(True)
        if bpy.context.object.mode != 'EDIT':
            bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='DESELECT')
        body_obj.vertex_groups.active_index = head_vg.index
        bpy.ops.object.vertex_group_select()
        bpy.ops.mesh.separate(type='SELECTED')
        bpy.ops.object.mode_set(mode='OBJECT')

        # Separation creates a new object named `BodyMesh.001`; pick it up
        # and rename to `HeadMesh`.
        head_obj = next(
            (o for o in bpy.data.objects
             if o.type == 'MESH' and o.name != 'BodyMesh'
                and o.name.startswith('BodyMesh')),
            None,
        )
        if head_obj is None:
            print("WARN: head separation didn't produce a new object")
        else:
            head_obj.name = 'HeadMesh'
            # Duplicate the material so tinting the head doesn't affect body.
            if head_obj.data.materials:
                mat_copy = head_obj.data.materials[0].copy()
                mat_copy.name = 'HeadMaterial'
                head_obj.data.materials[0] = mat_copy
            print(f"Split off HeadMesh: {len(head_obj.data.vertices)} verts, "
                  f"BodyMesh remaining {len(body_obj.data.vertices)} verts")

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
    export_mesh_colors=True,
    generate_preview_surface=True,
    root_prim_path='/root',
)
print(f"\nExported → {OUT}  size={os.path.getsize(OUT)} bytes  "
      f"(frames {scene.frame_start}-{scene.frame_end} @ {scene.render.fps} fps)")

# ---- preview render so we can eyeball pose + chair placement without
# touching the iPhone. Eevee, ~1s, side view matching the iOS camera.
PREVIEW = OUT.replace('.usdz', '_preview.png')
scene.render.engine = 'BLENDER_EEVEE'
scene.render.resolution_x = 600
scene.render.resolution_y = 1200
scene.render.resolution_percentage = 100
scene.render.filepath = PREVIEW
scene.render.image_settings.file_format = 'PNG'
scene.render.film_transparent = False
if scene.world is None:
    scene.world = bpy.data.worlds.new("PreviewWorld")
scene.world.use_nodes = False
scene.world.color = (36/255, 37/255, 43/255)  # match in-app slate

target = bpy.data.objects.new('_preview_target', None)
target.location = (0, 0, 1.0)
scene.collection.objects.link(target)

cam_data = bpy.data.cameras.new(name='_preview_cam')
cam_data.lens = 28
cam = bpy.data.objects.new('_preview_cam', cam_data)
scene.collection.objects.link(cam)
cam.location = (4.5, -0.5, 1.1)
c = cam.constraints.new('TRACK_TO')
c.target = target
c.track_axis = 'TRACK_NEGATIVE_Z'
c.up_axis = 'UP_Y'

sun_data = bpy.data.lights.new(name='_preview_sun', type='SUN')
sun_data.energy = 3.0
sun = bpy.data.objects.new('_preview_sun', sun_data)
scene.collection.objects.link(sun)
sun.location = (3, -3, 4)
sun.rotation_euler = (math.radians(30), math.radians(10), math.radians(15))

scene.camera = cam
scene.frame_set(0)
bpy.ops.render.render(write_still=True)
print(f"Preview PNG → {PREVIEW}")
