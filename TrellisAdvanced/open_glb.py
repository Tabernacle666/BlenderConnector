"""Open the generated GLB in the portable Blender GUI without editing it."""
import sys
from pathlib import Path
import bpy

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
if len(args) != 1 or not Path(args[0]).is_file() or Path(args[0]).suffix.lower() != ".glb":
    raise ValueError("Expected existing .glb file")
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(Path(args[0]).resolve()))
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
if meshes:
    from mathutils import Vector
    corners = [o.matrix_world @ Vector(p) for o in meshes for p in o.bound_box]
    mn = Vector(min(p[i] for p in corners) for i in range(3))
    mx = Vector(max(p[i] for p in corners) for i in range(3))
    center = (mn + mx) / 2
    extent = max(max(mx - mn), 0.1)
    for scr in bpy.data.screens:
        for area in scr.areas:
            if area.type == "VIEW_3D":
                area.spaces.active.region_3d.view_location = center
                area.spaces.active.region_3d.view_distance = extent * 2.5
                area.spaces.active.shading.type = "MATERIAL"
