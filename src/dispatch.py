"""Blender background process. Only invoked by the Windows watcher, not a standalone Python runtime."""
import json
import math
import os
import sys
import traceback
from collections import Counter
from pathlib import Path


def is_within(child, parent):
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def resolve_safe(base, requested, suffix):
    if not isinstance(requested, str) or not requested or '\x00' in requested:
        raise ValueError('Chemin manquant/invalide')
    if Path(requested).is_absolute() or ':' in requested:
        raise ValueError('Les chemins absolus sont interdits')
    dest = (base / requested).resolve()
    if not is_within(dest, base) or dest.suffix.lower() != suffix:
        raise ValueError('Chemin en dehors du dossier autorise ou extension invalide')
    if not dest.is_file():
        raise FileNotFoundError(str(dest))
    return dest


def write_report(path, data):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False, default=str), encoding='utf-8')
    tmp.replace(path)


def components_for_mesh(obj):
    """Count vertex connectivity islands, not semantically independent mechanical parts."""
    mesh = obj.data
    n = len(mesh.vertices)
    parent = list(range(n))
    rank = [0] * n

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        a = find(a)
        b = find(b)
        if a == b:
            return
        if rank[a] < rank[b]:
            a, b = b, a
        parent[b] = a
        if rank[a] == rank[b]:
            rank[a] += 1

    for poly in mesh.polygons:
        verts = poly.vertices
        if verts:
            anchor = verts[0]
            for v in verts[1:]:
                union(anchor, v)
    sizes = Counter(find(i) for i in range(n))
    return len(sizes), sorted(sizes.values(), reverse=True)[:10]


def mesh_metadata(meshes):
    result = []
    for obj in meshes:
        island_count, largest = components_for_mesh(obj)
        uv_names = [layer.name for layer in obj.data.uv_layers]
        mats = []
        for slot in obj.material_slots:
            mat = slot.material
            if not mat:
                continue
            textures = []
            if mat.use_nodes:
                for node in mat.node_tree.nodes:
                    if node.type == 'TEX_IMAGE' and node.image:
                        textures.append({'name': node.image.name,
                                         'resolution': list(node.image.size),
                                         'packed': bool(node.image.packed_file)})
            mats.append({'name': mat.name, 'textures': textures})
        result.append({
            'name': obj.name,
            'vertices': len(obj.data.vertices),
            'faces': len(obj.data.polygons),
            'triangles': sum(max(0, len(p.vertices) - 2) for p in obj.data.polygons),
            'loose_islands': island_count,
            'largest_islands_vertices': largest,
            'uv_layers': uv_names,
            'materials': mats,
        })
    return result


def bounds_world(meshes):
    from mathutils import Vector
    vertices = [obj.matrix_world @ Vector(corner) for obj in meshes for corner in obj.bound_box]
    if not vertices:
        raise ValueError('Aucun sommet visible')
    mn = Vector([min(v[i] for v in vertices) for i in range(3)])
    mx = Vector([max(v[i] for v in vertices) for i in range(3)])
    return mn, mx


def make_preview(bpy, meshes, output_dir, views, resolution):
    from mathutils import Vector
    mn, mx = bounds_world(meshes)
    center = (mn + mx) * 0.5
    dims = mx - mn
    extent = max(max(dims), 0.1)
    scene = bpy.context.scene
    # EEVEE produces realistic PBR textures faster than full Cycles in most cases.
    engine_used = None
    for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE', 'CYCLES'):
        try:
            scene.render.engine = engine
            engine_used = engine
            break
        except Exception:
            continue
    if not engine_used:
        raise RuntimeError('Aucun moteur de rendu disponible')
    if engine_used == 'CYCLES':
        scene.cycles.samples = 12
        scene.cycles.device = 'CPU'
    scene.render.resolution_x = resolution
    scene.render.resolution_y = resolution
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'JPEG'
    scene.render.image_settings.quality = 72
    scene.render.film_transparent = False
    scene.render.filepath = ''
    world = bpy.data.worlds.new('QA_world')
    world.use_nodes = True
    world.node_tree.nodes.get('Background').inputs['Color'].default_value = (0.35, 0.35, 0.35, 1)
    world.node_tree.nodes.get('Background').inputs['Strength'].default_value = 0.8
    scene.world = world
    # Render-only ground for visual context; original geometry and export remain unchanged.
    bpy.ops.mesh.primitive_plane_add(size=2.0, location=(center.x, center.y, mn.z - extent * 0.015))
    ground = bpy.context.object
    ground.name = 'QA_ground_not_exported'
    ground.scale = (extent * 2.0, extent * 2.0, 1)
    grey = bpy.data.materials.new('QA_floor')
    grey.diffuse_color = (0.33, 0.35, 0.37, 1)
    ground.data.materials.append(grey)
    lights = [((1.5, -1.6, 2.5), 1000), ((-2.0, 0.6, 1.3), 700), ((0.1, 1.8, 2.7), 900)]
    for idx, (relative, power) in enumerate(lights):
        data = bpy.data.lights.new('QA_light_%d' % idx, 'AREA')
        data.energy = power * max(extent, 0.5) ** 2
        data.shape = 'DISK'
        data.size = max(extent * 2.5, 0.5)
        obj = bpy.data.objects.new(data.name, data)
        scene.collection.objects.link(obj)
        obj.location = center + Vector(relative) * extent
        obj.rotation_euler = (center - obj.location).to_track_quat('-Z','Y').to_euler()
    cam_data = bpy.data.cameras.new('QA_camera')
    cam = bpy.data.objects.new('QA_camera', cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam_data.type = 'ORTHO'
    cam_data.ortho_scale = extent * 1.8
    directions = {
        'front': Vector((0.0, -1.0, 0.28)),
        'side': Vector((1.0, 0.0, 0.28)),
        'back': Vector((0.0, 1.0, 0.28)),
        'three_quarters': Vector((1.0, -1.4, 0.8)),
        'top': Vector((1.0, -0.8, 2.5)),
    }
    outputs = []
    for name in views:
        if name not in directions:
            continue
        cam.location = center + directions[name].normalized() * extent * 3.5
        cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
        target = output_dir / ('view_%s.jpg' % name)
        scene.render.filepath = str(target)
        print('RENDER', name, flush=True)
        bpy.ops.render.render(write_still=True)
        outputs.append(target.name)
    # Remove test-only objects before saving Blender project or GLB.
    to_remove = [ground,cam] + [o for o in bpy.data.objects if o.name.startswith('QA_light_')]
    for obj in to_remove:
        bpy.data.objects.remove(obj, do_unlink=True)
    return outputs, engine_used



def fan_candidate_region(bounds_min, bounds_max):
    """Approximate blade envelope only: non-destructive diagnostic, NOT a part extraction."""
    mn, mx = bounds_min, bounds_max
    width, height, depth = mx.x - mn.x, mx.z - mn.z, mx.y - mn.y
    if min(width, height, depth) <= 0:
        raise ValueError('Dimensions fan non valides')
    return {
        'axis': 'Y',
        'center_x': (mn.x + mx.x) / 2,
        'center_z': mn.z + 0.635 * height,
        'radius_m': 0.365 * width,
        'min_y': mn.y + 0.10 * depth,
        'max_y': mn.y + 0.44 * depth,
    }


def fan_candidate_face(center, region):
    """Pure geometry mask. It can include cage bars: preview only."""
    r2 = ((center.x - region['center_x']) ** 2 +
          (center.z - region['center_z']) ** 2)
    return (r2 <= region['radius_m'] ** 2 and
            region['min_y'] <= center.y <= region['max_y'])


def make_fan_candidate_preview(bpy, meshes):
    """Color a copy of the triangles; source geometry, UVs and materials stay unchanged."""
    from mathutils import Vector
    mn, mx = bounds_world(meshes)
    region = fan_candidate_region(mn, mx)
    mats = []
    for name, rgba in (
        ('QA_Fan_Unselected', (0.11, 0.17, 0.21, 1)),
        ('QA_Fan_Rotor_Candidate', (1.0, 0.12, 0.03, 1)),
    ):
        material = bpy.data.materials.new(name)
        material.diffuse_color = rgba
        material.use_nodes = True
        nodes = material.node_tree.nodes
        nodes.clear()
        output = nodes.new('ShaderNodeOutputMaterial')
        emission = nodes.new('ShaderNodeEmission')
        emission.inputs['Color'].default_value = rgba
        emission.inputs['Strength'].default_value = 1.0
        material.node_tree.links.new(emission.outputs['Emission'], output.inputs['Surface'])
        mats.append(material)
    total = 0
    candidate = 0
    for obj in meshes:
        copied = obj.data.copy()
        copied.name = 'QA_Colored_' + obj.data.name
        copied.materials.clear()
        for mat in mats:
            copied.materials.append(mat)
        world = obj.matrix_world.copy()
        coords = [world @ v.co for v in obj.data.vertices]
        for face in copied.polygons:
            midpoint = sum((coords[idx] for idx in face.vertices), Vector()) / len(face.vertices)
            matched = fan_candidate_face(midpoint, region)
            face.material_index = 1 if matched else 0
            candidate += int(matched)
            total += 1
        qa = bpy.data.objects.new('QA_Fan_Segmentation_' + obj.name, copied)
        bpy.context.scene.collection.objects.link(qa)
        qa.matrix_world = obj.matrix_world.copy()
        obj.hide_render = True
        obj.hide_set(True)
    if candidate == 0:
        raise ValueError('Region candidate vide; impossible de produire un apercu utile')
    return {
        'candidate_faces': candidate,
        'total_faces': total,
        'candidate_fraction': round(candidate / total, 5),
        'region_blender_xyz_m': {k: round(v, 6) if isinstance(v, float) else v for k, v in region.items()},
        'preview_only': True,
        'rotor_extracted': False,
        'glb_exported': False,
        'warning': 'Le rouge peut comprendre des fragments de grille et moteur; aucune piece n a ete decoupee.'
    }


def run_job(job_path, output_dir, root, local_settings):
    import bpy
    output_dir.mkdir(parents=True, exist_ok=True)
    job = json.loads(job_path.read_text(encoding='utf-8-sig'))
    settings = json.loads(local_settings.read_text(encoding='utf-8-sig'))
    if not isinstance(job, dict) or job.get('schema') != 1:
        raise ValueError('schema JSON invalide')
    if job.get('id') != job_path.stem:
        raise ValueError('id JSON != nom du fichier')
    op = job.get('operation')
    if op not in ('inspect_glb','preview_glb','normalize_glb','repository_script','segment_fan_preview'):
        raise ValueError('operation interdite: %s' % op)
    model_path = resolve_safe(root / 'input', job.get('input'), '.glb')
    print('IMPORT', model_path, flush=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(model_path))
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    if not meshes:
        raise ValueError('GLB sans maillages')
    before_min, before_max = bounds_world(meshes)
    report = {
        'schema':1,
        'id': job['id'],
        'status':'ok',
        'operation':op,
        'blender_version': bpy.app.version_string,
        'input': model_path.name,
        'mesh_count':len(meshes),
        'materials_count':len(bpy.data.materials),
        'dimensions_m_assuming_gltf_units':[round(x,6) for x in (before_max-before_min)],
        'mesh_details': mesh_metadata(meshes),
        'warning':'Connectivity islands do not identify rotor or blades semantically.'
    }
    if op == 'segment_fan_preview':
        print('FAN SEGMENTATION PREVIEW (no geometry changes)', flush=True)
        report['fan_segmentation'] = make_fan_candidate_preview(bpy, meshes)
    if op == 'normalize_glb':
        desired = job.get('target_longest_m')
        if not isinstance(desired,(int,float)) or not (0.05 <= desired <= 50):
            raise ValueError('target_longest_m doit etre entre 0.05 et 50')
        longest = max(before_max-before_min)
        if longest <= 0:
            raise ValueError('Dimensions nulles')
        scale = float(desired) / longest
        from mathutils import Matrix, Vector
        # Shift scene to put bottom at Z=0 and center X,Y around world origin.
        offset = Vector((-(before_min.x+before_max.x)*0.5, -(before_min.y+before_max.y)*0.5, -before_min.z))
        transform = Matrix.Diagonal((scale,scale,scale,1)) @ Matrix.Translation(offset)
        for obj in bpy.context.scene.objects:
            if obj.parent is None:
                obj.matrix_world = transform @ obj.matrix_world
        target_glb = output_dir / ('%s_normalized.glb' % model_path.stem)
        # GLTF export only selected meshes to avoid helper content.
        bpy.ops.object.select_all(action='DESELECT')
        for o in meshes:
            o.select_set(True)
        bpy.context.view_layer.objects.active = meshes[0]
        bpy.ops.export_scene.gltf(filepath=str(target_glb), export_format='GLB', use_selection=True)
        report['export_glb'] = str(target_glb)
        report['target_longest_m'] = desired
        report['scale_applied'] = scale
    if op == 'repository_script':
        if not settings.get('allow_repository_scripts', False):
            raise PermissionError('repository_script refuse: activer allow_repository_scripts dans local/settings.json')
        script_path = resolve_safe(root / 'operations', job.get('script'), '.py')
        print('CUSTOM SCRIPT (TRUSTED)', script_path, flush=True)
        variables = {'bpy':bpy, 'meshes':meshes, 'job':job,'asset_dir':output_dir,'root':root}
        exec(compile(script_path.read_text(encoding='utf-8-sig'),str(script_path),'exec'),variables)
        report['custom_script'] = script_path.name
    image_size = job.get('image_size', 720)
    if not isinstance(image_size,int) or not 320 <= image_size <= 1200:
        raise ValueError('image_size hors limites [320, 1200]')
    views = job.get('views', ['three_quarters'])
    if not isinstance(views,list) or len(views) > 5 or any(not isinstance(v,str) for v in views):
        raise ValueError('views invalide')
    for view in views:
        if view not in ('front','side','back','three_quarters','top'):
            raise ValueError('Vue non supportee: %s' % view)
    # Keep the saved .blend centered and easy to inspect on first opening.
    display_min, display_max = bounds_world(meshes)
    display_center = (display_min + display_max) * 0.5
    display_extent = max(max(display_max - display_min), 0.1)
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == 'VIEW_3D':
                area.spaces.active.region_3d.view_location = display_center
                area.spaces.active.region_3d.view_distance = display_extent * 2.7
    print('SAVE .BLEND',flush=True)
    blend_file = output_dir / ('%s.blend' % job['id'])
    bpy.ops.wm.save_as_mainfile(filepath=str(blend_file),compress=True)
    report['project_blend'] = str(blend_file)
    if views:
        jpg,engine = make_preview(bpy,meshes,output_dir,views,image_size)
        report['images_jpg'] = jpg
        report['render_engine'] = engine
    report['status'] = 'ok'
    write_report(output_dir/'report.json',report)
    return report


def main():
    args = sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    if len(args) != 4:
        print('Usage: blender --background --python dispatch.py -- job.json output_dir root settings.json')
        return 2
    job_path, output_dir, root, settings = map(lambda a:Path(a).resolve(),args)
    try:
        result = run_job(job_path,output_dir,root,settings)
        print('SUCCESS:',result['id'],flush=True)
        return 0
    except Exception as exc:
        print('ERROR:',repr(exc),flush=True)
        traceback.print_exc()
        output_dir.mkdir(parents=True, exist_ok=True)
        write_report(output_dir/'report.json',{
            'schema':1, 'id':job_path.stem, 'status':'error',
            'error_type':type(exc).__name__, 'message':str(exc)
        })
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
