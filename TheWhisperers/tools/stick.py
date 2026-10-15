# Makes the stake's stick model from a vanilla body .x: same skeleton, a wood
# octagonal pole from the feet (pelvis bone) up into the neck (neck bone).
#   python3 tools/stick.py <game models_X/Skinned/MaleBody.x> <out Whisp_StakeStick_M.x>
import re, math, sys
src, out = sys.argv[1], sys.argv[2]
t = open(src, newline='').read()
nl = '\r\n' if '\r\n' in t else '\n'
t = t.replace('\r\n', '\n')
head = t[:t.index('Frame Dummy01 {')]
head = head[:head.index('\nMaterial ') + 1]   # keep templates only
frames = t[t.index('Frame Dummy01 {'):t.index('Frame Body {')]

def offset(bone):
    m = re.search(r'SkinWeights \{\s*"%s";.*?;\s*([-\d.,e]+);;' % bone, t, re.S)
    return m.group(1)

R, SEG = 0.016, 8
X0, Z0 = 0.0, 0.03
RINGS = [(-0.02, 'Bip01_Pelvis'), (0.52, 'Bip01_Pelvis'), (0.86, 'Bip01_Neck')]
U0, U1 = 0.56, 0.96
verts, norms, uvs, bones = [], [], [], []
for ri, (y, bone) in enumerate(RINGS):
    v = 1.0 - (y - RINGS[0][0]) / (RINGS[-1][0] - RINGS[0][0])
    for s in range(SEG + 1):
        a = 2 * math.pi * s / SEG
        nx, nz = math.cos(a), math.sin(a)
        verts.append((X0 + R * nx, y, Z0 + R * nz)); norms.append((nx, 0.0, nz))
        uvs.append((U0 + (U1 - U0) * s / SEG, v)); bones.append(bone)
faces = []
for ri in range(len(RINGS) - 1):
    for s in range(SEG):
        a = ri * (SEG + 1) + s; b = a + 1; c = a + SEG + 1; d = c + 1
        faces += [(a, c, b), (b, c, d)]
faces += [(f[0], f[2], f[1]) for f in faces]   # double-sided

f6 = lambda x: '%.6f' % x
L = []
L.append('Material Whisp_StakeWood {')
L.append(' 1.000000;1.000000;1.000000;1.000000;;')
L.append(' 9.999999;')
L.append(' 0.000000;0.000000;0.000000;;')
L.append(' 0.000000;0.000000;0.000000;;')
L.append('')
L.append(' TextureFilename {')
L.append('  "Shaft.png";')
L.append(' }')
L.append('}')
L.append('')
body = frames + '\n'
M = []
M.append('Frame Whisp_StakeStick {')
M.append(' ')
M.append('')
M.append(' FrameTransformMatrix {')
M.append('  1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000;;')
M.append(' }')
M.append('')
M.append(' Mesh Whisp_StakeStick {')
M.append('  %d;' % len(verts))
M += ['  %s;%s;%s;%s' % (f6(v[0]), f6(v[1]), f6(v[2]), ',' if i < len(verts) - 1 else ';') for i, v in enumerate(verts)]
M.append('  %d;' % len(faces))
M += ['  3;%d,%d,%d;%s' % (f[0], f[1], f[2], ',' if i < len(faces) - 1 else ';') for i, f in enumerate(faces)]
M.append('')
M.append('  MeshNormals {')
M.append('   %d;' % len(norms))
M += ['   %s;%s;%s;%s' % (f6(n[0]), f6(n[1]), f6(n[2]), ',' if i < len(norms) - 1 else ';') for i, n in enumerate(norms)]
M.append('   %d;' % len(faces))
M += ['   3;%d,%d,%d;%s' % (f[0], f[1], f[2], ',' if i < len(faces) - 1 else ';') for i, f in enumerate(faces)]
M.append('  }')
M.append('')
M.append('  MeshMaterialList {')
M.append('   1;')
M.append('   %d;' % len(faces))
M += ['   0%s' % (',' if i < len(faces) - 1 else ';') for i in range(len(faces))]
M.append('   { Whisp_StakeWood }')
M.append('  }')
M.append('')
M.append('  MeshTextureCoords c1 {')
M.append('   %d;' % len(uvs))
M += ['   %s;%s;%s' % (f6(u[0]), f6(u[1]), ',' if i < len(uvs) - 1 else ';') for i, u in enumerate(uvs)]
M.append('  }')
M.append('')
used = sorted(set(bones))
M.append('  XSkinMeshHeader {')
M.append('   1;')
M.append('   2;')
M.append('   %d;' % len(used))
M.append('  }')
for bone in used:
    idx = [i for i, b in enumerate(bones) if b == bone]
    M.append('')
    M.append('  SkinWeights {')
    M.append('   "%s";' % bone)
    M.append('   %d;' % len(idx))
    M += ['   %d%s' % (i, ',' if k < len(idx) - 1 else ';') for k, i in enumerate(idx)]
    M += ['   1.000000%s' % (',' if k < len(idx) - 1 else ';') for k in range(len(idx))]
    M.append('   %s;;' % offset(bone))
    M.append('  }')
M.append(' }')
M.append('}')
M.append('')
text = head + '\n'.join(L) + '\n' + body + '\n'.join(M) + '\n'
open(out, 'w', newline='').write(text.replace('\n', nl))
print(out, len(verts), 'verts', len(faces), 'faces', used)
