# Makes Whisp_FacelessOverlay.png: vanilla SkeletonMuscle flesh over the face,
# feathered, transparent elsewhere. Worn by faceless stakes as a body overlay.
#   python3 tools/faceless.py <game media/textures/Body/> <out.png> [preview dir]
import png, math, sys
B=sys.argv[1]; out=sys.argv[2]
w,h,mus=png.read(B+'SkeletonMuscle.png')
cx,cy,rx,ry=128.5,39.5,23.0,22.0
px=[]
for y in range(h):
    row=[]
    for x in range(w):
        d=math.hypot((x-cx)/rx,(y-cy)/ry)
        a=1.0 if d<0.8 else max(0.0,(1.0-d)/0.2)
        r,g,b,_=mus[y][x]
        k=0.8  # darker, wetter flesh
        row.append((int(r*k),int(g*k*0.85),int(b*k*0.85),int(255*a)))
    px.append(row)
png.write(out,w,h,px)
def comp(skin,o):
    _,_,s=png.read(B+skin+'.png'); res=[]
    for y in range(64):
        r=[]
        for x in range(w):
            a=px[y][x][3]/255; r.append(tuple(int(px[y][x][i]*a+s[y][x][i]*(1-a)) for i in range(3))+(255,))
        res.append(r)
    png.write(o,w,64,res)
if len(sys.argv) > 3:  # optional preview folder: the overlay on two skins
    comp('MaleBody01', sys.argv[3] + '/prev_m.png'); comp('F_ZedBody02_level2', sys.argv[3] + '/prev_f.png')
