"""Export the user's hand-baked Blender → stickman.usdz.

Source file: `posture_buddy_v6_baked.blend`. The chair is now embedded in
the .blend itself (pre-scaled and positioned relative to the buddy), and the
animation is baked to 100 frames of FK keyframes — nothing depends on IK /
Spline IK / drivers anymore. So this script is mostly a pass-through to USD
with one post-import tweak: split the head off into its own mesh + material
instance so the Swift side can tint only the head.
"""

import bpy, os

# Paths are resolved from this script's location so the pipeline works no
# matter where it's invoked from:
#   <repo-root>/tools/stickman/export.py
#   <repo-root>/Posture Buddy/stickman.usdz
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT  = os.path.abspath(os.path.join(_SCRIPT_DIR, "..", ".."))
OUT         = os.path.join(_REPO_ROOT, "Posture Buddy", "stickman.usdz")

scene = bpy.context.scene
scene.frame_start = 0
scene.frame_end = 100

# NOTE: do NOT repoint BodyMesh's armature modifier here. v6 ships with the
# mesh skinned to `GameRig` (the deformation rig), with `Ctrl_Rig` acting
# only as the artist-facing control rig. Forcing the modifier at Ctrl_Rig
# leaves BodyMesh skinned to bones that don't move — the mesh visibly
# explodes into floating limbs because the rest pose doesn't match the
# baked-frame intentions. Trust the blend's modifier target.

# Promote every object into the master collection and unhide it. v6's
# GameRig in particular lives in a hidden collection and won't show up in
# the active view layer otherwise — which would make the visual-keying
# bake below fail with `RuntimeError: ViewLayer does not contain object`.
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

# Bake the visual pose of GameRig from frame 0..end. v6 keyframes the
# animation on Ctrl_Rig (the artist-facing rig); GameRig follows via 78
# pose-bone copy-transforms constraints. USD/SceneKit don't evaluate
# Blender constraints, so without this step GameRig exports in its rest
# pose (T-pose) regardless of what frame we're on, and dropping Ctrl_Rig
# below would leave the runtime mesh stuck. Visual keying captures the
# constraint-evaluated pose into GameRig's own action; clearing the
# constraints afterwards detaches it from Ctrl_Rig entirely.
ctrl = bpy.data.objects.get('Ctrl_Rig')
game = bpy.data.objects.get('GameRig')
if ctrl is not None and game is not None:
    print(f"Baking GameRig pose ({scene.frame_start}..{scene.frame_end}) from Ctrl_Rig…")
    bpy.context.view_layer.objects.active = game
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    game.select_set(True)
    bpy.ops.object.mode_set(mode='POSE')
    bpy.ops.pose.select_all(action='SELECT')
    bpy.ops.nla.bake(
        frame_start=scene.frame_start,
        frame_end=scene.frame_end,
        only_selected=True,
        visual_keying=True,
        clear_constraints=True,
        bake_types={'POSE'},
    )
    bpy.ops.object.mode_set(mode='OBJECT')
    print(f"  GameRig action keyframed; constraints cleared.")

# Drop everything that doesn't need to ship in the USDZ:
#   • CURVE objects (BezierCurve, L_*, R_*) are Spline-IK target curves left
#     over from the pre-bake rig. The animation is fully baked to FK
#     keyframes, so the curves are cosmetic.
#   • Meshes prefixed `CS_` are Blender bone-shape widgets (custom visual
#     handles on the armature's bones in the viewport only).
#   • Meshes whose origin sits > STRAY_DISTANCE from scene origin are
#     leftover test geometry (v6 ships with two stray cylinders at x≈-16
#     that otherwise render as floating rectangles next to the buddy).
#   • `Ctrl_Rig` is the artist-facing control rig. The actual deform rig
#     bound to BodyMesh is `GameRig`, and the animation is baked onto
#     GameRig's bones, so Ctrl_Rig is dead weight in the USDZ. Worse, the
#     two-armature setup confuses SceneKit's USD importer — the SCNSkinner
#     can end up referencing bones from the wrong rig and the mesh renders
#     in the wrong place / wrong orientation. Dropping it keeps the import
#     unambiguous.
STRAY_DISTANCE = 5.0
victims = []
for o in list(bpy.data.objects):
    if o.type == 'CURVE':
        victims.append(o)
    elif o.type == 'MESH' and o.name.startswith('CS_'):
        victims.append(o)
    elif o.type == 'MESH' and max(abs(o.location.x), abs(o.location.y), abs(o.location.z)) > STRAY_DISTANCE:
        victims.append(o)
    elif o.type == 'ARMATURE' and o.name == 'Ctrl_Rig':
        victims.append(o)
if victims:
    print(f"Dropping {len(victims)} object(s): {[o.name for o in victims]}")
    for o in victims:
        bpy.data.objects.remove(o, do_unlink=True)

# BodyMesh in v6 ships without any material assignment. Without a material
# the USD export emits no material binding for the prim, and SceneKit
# imports it as effectively invisible (only the chair + the Swift-tinted
# HeadMesh end up rendering). Assign a default Principled BSDF — slightly
# glossy white — so the body renders. This same material then propagates
# to HeadMesh via the head-split step below (which copies material slot 0
# off BodyMesh), keeping the head + body shading consistent.
body_obj_for_mat = bpy.data.objects.get('BodyMesh')
if body_obj_for_mat is not None and not [m for m in body_obj_for_mat.data.materials if m is not None]:
    print("BodyMesh has no material — assigning default shiny white")
    mat = bpy.data.materials.new(name='BodyMaterial')
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get('Principled BSDF')
    if bsdf is not None:
        bsdf.inputs['Base Color'].default_value = (1.0, 1.0, 1.0, 1.0)
        bsdf.inputs['Roughness'].default_value = 0.3   # mild gloss
    body_obj_for_mat.data.materials.append(mat)

# NOTE: do NOT bpy.ops.mesh.normals_make_consistent on BodyMesh here.
# Entering Edit mode disturbs the skinning bind pose (Blender re-evaluates
# the mesh from the current armature state) and the rig drifts out of the
# chair on iOS. Back-face culling is handled in Swift instead by setting
# `isDoubleSided = true` on every imported material.

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
import math
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
