import struct, sys
def parse(path):
    d = open(path, 'rb').read(); p = 0
    assert d[:4] == b'tdef'; p = 4
    ver, n = struct.unpack_from('<ii', d, p); p += 8
    def line():
        nonlocal p
        e = d.index(b'\n', p); s = d[p:e].decode('latin-1'); p = e + 1; return s
    sets = []
    for _ in range(n):
        name = line(); img = line()
        cols, rows, sid, nt = struct.unpack_from('<iiii', d, p); p += 16
        tiles = []
        for _ in range(nt):
            (np_,) = struct.unpack_from('<i', d, p); p += 4
            tiles.append([(line(), line()) for _ in range(np_)])
        sets.append(dict(name=name, img=img, cols=cols, rows=rows, id=sid, tiles=tiles))
    return ver, sets
def write(path, ver, sets):
    o = bytearray(b'tdef') + struct.pack('<ii', ver, len(sets))
    for s in sets:
        o += (s['name'] + '\n' + s['img'] + '\n').encode()
        o += struct.pack('<iiii', s['cols'], s['rows'], s['id'], len(s['tiles']))
        for t in s['tiles']:
            o += struct.pack('<i', len(t))
            for k, v in t: o += (k + '\n' + v + '\n').encode()
    open(path, 'wb').write(o)
if __name__ == '__main__':
    ver, sets = parse(sys.argv[1])
    for s in sets:
        if len(sys.argv) > 2 and s['name'] != sys.argv[2]: continue
        print(ver, s['name'], s['img'], s['cols'], s['rows'], s['id'], len(s['tiles']))
        for i, t in enumerate(s['tiles']):
            if len(sys.argv) > 3 and str(i) not in sys.argv[3].split(','): continue
            print(' ', i, t)
