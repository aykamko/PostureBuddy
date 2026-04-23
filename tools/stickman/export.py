import bpy, os

OUT_DIR = os.path.abspath(os.path.dirname(bpy.data.filepath) + "/..")

KEEP_MESHES = {"Head", "Spine", "Arm_L_1", "Arm_L_2", "Arm_R_1", "Arm_R_2",
               "Leg_L_1", "Leg_L_2", "Leg_R_1", "Leg_R_2"}
KEEP = set(KEEP_MESHES) | {"Armature"}

# 1. Remove unwanted objects via direct data API (no dependency on selection / collection state)
victims = [o for o in list(bpy.data.objects) if o.name not in KEEP]
print(f"Removing {len(victims)} unwanted objects: {[o.name for o in victims]}")
for o in victims:
    bpy.data.objects.remove(o, do_unlink=True)

# 2. Re-link every keeper to the scene's master collection (unlink from any child collections)
master = bpy.context.scene.collection
for col in list(bpy.data.collections):
    for o in list(col.objects):
        col.objects.unlink(o)
for o in bpy.data.objects:
    if o.name not in [ob.name for ob in master.objects]:
        master.objects.link(o)
    o.hide_viewport = False
    o.hide_render = False
    o.hide_set(False)

# 3. Purge now-empty collections
for col in list(bpy.data.collections):
    if len(col.objects) == 0 and len(col.children) == 0:
        bpy.data.collections.remove(col)

print("\n=== Scene state after cleanup ===")
for o in bpy.data.objects:
    print(f"  {o.type:<10} {o.name!r:<20} in_master={o.name in [ob.name for ob in master.objects]}")
print(f"  (collections remaining: {[c.name for c in bpy.data.collections]})")

# 4. Select all
bpy.ops.object.select_all(action='SELECT')

# 5. Export USDZ
usdz_path = os.path.join(OUT_DIR, "stickman.usdz")
bpy.ops.wm.usd_export(
    filepath=usdz_path,
    selected_objects_only=False,
    export_animation=False,
    export_armatures=True,
    export_materials=True,
    export_meshes=True,
    export_uvmaps=True,
    export_normals=True,
    generate_preview_surface=True,
    root_prim_path="/root",
)
print(f"\nExported USDZ → {usdz_path}  size={os.path.getsize(usdz_path)} bytes")
