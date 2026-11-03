# Executed ONLY after local/settings.json explicitly permits repository scripts.
# The dispatcher imports the GLB before executing this file.
# Available locals: bpy, meshes (list), job (dict), asset_dir (Path), root (Path).
# This example renames meshes, without modifying topology.
for i, obj in enumerate(meshes):
    obj.name = "AssetPart_%03d" % (i + 1)
