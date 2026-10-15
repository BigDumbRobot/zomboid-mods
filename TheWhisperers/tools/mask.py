#!/usr/bin/env python3
# Makes the face mask model from a vanilla body .x: the body's own face
# triangles (brow to chin), pushed slightly outward so they sit over the
# wearer's face, all weighted to the head bone. The UVs stay the body's, so any
# body skin texture (media/textures/Body/*.png) fits the mask.
#   python3 tools/mask.py <game models_X/Skinned/MaleBody.x> <out Whisp_FaceMask_M.x>
# In these models +z is the back of the body: the face points toward -z.
import re, sys

OFFSET = 0.004    # how far the mask stands off the face, along each vertex normal
MIN_Y = 0.83      # below this is the neck
MAX_Y = 0.947     # the brow: above it the mask would poke through the wearer's hair

src, out = sys.argv[1], sys.argv[2]
t = open(src, newline='').read()
nl = '\r\n' if '\r\n' in t else '\n'
t = t.replace('\r\n', '\n')
head = t[:t.index('Frame Dummy01 {')]
head = head[:head.index('\nMaterial ') + 1]   # keep templates only
frames = t[t.index('Frame Dummy01 {'):t.index('Frame Body {')]

m = re.search(r'Mesh Body \{\s*(\d+);(.*?);;\s*(\d+);(.*?);;', t, re.S)
nv = int(m.group(1))
verts = [tuple(map(float, l.strip().rstrip(',;').split(';')[:3])) for l in m.group(2).strip().split('\n')[:nv]]
faces = [tuple(int(x) for x in l.strip().rstrip(',;').split(';', 1)[1].rstrip(';').split(','))
         for l in m.group(4).strip().split('\n')[:int(m.group(3))]]
um = re.search(r'MeshTextureCoords c1 \{\s*(\d+);(.*?);;', t, re.S)
uvs = [tuple(map(float, l.strip().rstrip(',;').split(';')[:2])) for l in um.group(2).strip().split('\n')[:int(um.group(1))]]
nm = re.search(r'MeshNormals \{\s*(\d+);(.*?);;', t, re.S)
norms = [tuple(map(float, l.strip().rstrip(',;').split(';')[:3])) for l in nm.group(2).strip().split('\n')[:int(nm.group(1))]]
head_w = {}
offset_matrix = None
for sw in re.finditer(r'SkinWeights \{\s*"(\w+)";\s*(\d+);(.*?);(.*?);\s*([-\d.,e]+);;', t, re.S):
    if sw.group(1) != 'Bip01_Head':
        continue
    idx = [int(x) for x in sw.group(3).replace('\n', '').split(',') if x.strip()]
    w = [float(x) for x in sw.group(4).replace('\n', '').split(',') if x.strip()]
    head_w = dict(zip(idx, w))
    offset_matrix = sw.group(5)
assert offset_matrix, 'no Bip01_Head skin weights'

# Front-facing head triangles above the neck: the face.
sel = []
for fc in faces:
    if not all(head_w.get(i, 0) > 0.5 for i in fc):
        continue
    nz = sum(norms[i][2] for i in fc) / 3
    y = sum(verts[i][1] for i in fc) / 3
    top = max(verts[i][1] for i in fc)
    if nz < -0.3 and y > MIN_Y and top <= MAX_Y:
        sel.append(fc)

remap = {}
for fc in sel:
    for i in fc:
        remap.setdefault(i, len(remap))
order = sorted(remap, key=remap.get)
mv = [tuple(verts[i][k] + norms[i][k] * OFFSET for k in range(3)) for i in order]
mn = [norms[i] for i in order]
mu = [uvs[i] for i in order]
mf = [tuple(remap[i] for i in fc) for fc in sel]

f6 = lambda x: '%.6f' % x
sep = lambda i, n: ',' if i < n - 1 else ';'
L = ['Material Whisp_MaskSkin {', ' 1.000000;1.000000;1.000000;1.000000;;', ' 9.999999;',
     ' 0.000000;0.000000;0.000000;;', ' 0.000000;0.000000;0.000000;;', '',
     ' TextureFilename {', '  "MaleBody01.png";', ' }', '}', '']
M = ['Frame Whisp_FaceMask {', ' ', '', ' FrameTransformMatrix {',
     '  1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000;;',
     ' }', '', ' Mesh Whisp_FaceMask {', '  %d;' % len(mv)]
M += ['  %s;%s;%s;%s' % (f6(v[0]), f6(v[1]), f6(v[2]), sep(i, len(mv))) for i, v in enumerate(mv)]
M.append('  %d;' % len(mf))
M += ['  3;%d,%d,%d;%s' % (f[0], f[1], f[2], sep(i, len(mf))) for i, f in enumerate(mf)]
M += ['', '  MeshNormals {', '   %d;' % len(mn)]
M += ['   %s;%s;%s;%s' % (f6(v[0]), f6(v[1]), f6(v[2]), sep(i, len(mn))) for i, v in enumerate(mn)]
M.append('   %d;' % len(mf))
M += ['   3;%d,%d,%d;%s' % (f[0], f[1], f[2], sep(i, len(mf))) for i, f in enumerate(mf)]
M += ['  }', '', '  MeshMaterialList {', '   1;', '   %d;' % len(mf)]
M += ['   0%s' % sep(i, len(mf)) for i in range(len(mf))]
M += ['   { Whisp_MaskSkin }', '  }', '', '  MeshTextureCoords c1 {', '   %d;' % len(mu)]
M += ['   %s;%s;%s' % (f6(u[0]), f6(u[1]), sep(i, len(mu))) for i, u in enumerate(mu)]
M += ['  }', '', '  XSkinMeshHeader {', '   1;', '   1;', '   1;', '  }', '',
      '  SkinWeights {', '   "Bip01_Head";', '   %d;' % len(mv)]
M += ['   %d%s' % (i, sep(i, len(mv))) for i in range(len(mv))]
M += ['   1.000000%s' % sep(i, len(mv)) for i in range(len(mv))]
M += ['   %s;;' % offset_matrix, '  }', ' }', '}', '']
text = head + '\n'.join(L) + '\n' + frames + '\n'.join(M) + '\n'
open(out, 'w', newline='').write(text.replace('\n', nl))
print(out, len(mv), 'verts', len(mf), 'faces')
