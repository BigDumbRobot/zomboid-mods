# World positions of the pelvis, neck and head in each mannequin pose (used to
# pick poses where the neck is over the pelvis, so the stick stands straight).
#   python3 tools/pose.py <body.x> <pose anim .x>...
import re, sys, math
def mat_from_list(v): return [v[0:4], v[4:8], v[8:12], v[12:16]]  # row-major, row vectors (DirectX)
def mul(a, b): return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]
def quat(w, x, y, z):
    return [[1-2*(y*y+z*z), 2*(x*y+w*z), 2*(x*z-w*y), 0],
            [2*(x*y-w*z), 1-2*(x*x+z*z), 2*(y*z+w*x), 0],
            [2*(x*z+w*y), 2*(y*z-w*x), 1-2*(x*x+y*y), 0],
            [0, 0, 0, 1]]
def frames(path):
    t = open(path).read().replace('\r', '')
    out = {}; stack = []
    for m in re.finditer(r'Frame (\w+) \{|FrameTransformMatrix \{\s*([-\d.,e]+);;|(\})', t):
        pass
    # simple parser tracking braces
    tok = re.finditer(r'(Frame (\w+) \{)|(FrameTransformMatrix \{\s*([-\d.,e]+);;\s*\})|(\{)|(\})', t)
    for m in tok:
        if m.group(1): stack.append(m.group(2)); out[m.group(2)] = {'parent': next((s for s in reversed(stack[:-1]) if s), None)}
        elif m.group(3): out[stack[-1]]['m'] = mat_from_list([float(x) for x in m.group(4).split(',')])
        elif m.group(5): stack.append(None)
        elif m.group(6):
            if stack: stack.pop()
    return out
def anim_local(path):
    t = open(path).read().replace('\r', '')
    res = {}
    for m in re.finditer(r'Animation \{\s*\{ (\w+) \}(.*?)\n \}', t, re.S):
        b, body = m.group(1), m.group(2)
        r = re.search(r'AnimationKey R \{\s*\d+;\s*\d+;\s*\d+;\d+;([-\d.e]+),([-\d.e]+),([-\d.e]+),([-\d.e]+);;', body)
        tr = re.search(r'AnimationKey T \{\s*\d+;\s*\d+;\s*\d+;\d+;([-\d.e]+),([-\d.e]+),([-\d.e]+);;', body)
        if r and tr:
            w, x, y, z = map(float, r.groups()); M = quat(w, -x, -y, -z)
            M[3] = [*map(float, tr.groups()), 1]
            res[b] = M
    return res
F = frames(sys.argv[1])
def world(name, local):
    m = local.get(name, F[name].get('m'))
    p = F[name]['parent']
    return mul(m, world(p, local)) if p else m
for path in [None] + sys.argv[2:]:
    loc = anim_local(path) if path else {}
    print(path.split('/')[-1] if path else 'BIND')
    for b in ['Bip01_Pelvis', 'Bip01_Neck', 'Bip01_Head', 'Bip01_L_Foot', 'Bip01_R_Foot']:
        W = world(b, loc)
        print('  %-13s pos %s' % (b, ' '.join('%6.3f' % v for v in W[3][:3])))
