# Measures a body .x: vertex bounds per bone (used to size the stake stick).
#   python3 tools/bounds.py <game models_X/Skinned/MaleBody.x>
import re,sys
t=open(sys.argv[1]).read()
m=re.search(r'Mesh \w+ \{\s*(\d+);(.*?);;',t,re.S)
n=int(m.group(1)); vs=[tuple(map(float,l.strip().rstrip(',;').split(';')[:3])) for l in m.group(2).strip().split('\n')[:n]]
print('verts',n,'y',min(v[1] for v in vs),max(v[1] for v in vs))
for sw in re.finditer(r'SkinWeights \{\s*"(\w+)";\s*(\d+);(.*?);(.*?);(.*?);;',t,re.S):
    b=sw.group(1)
    if b not in('Bip01_Head','Bip01_Neck','Bip01_Pelvis','Bip01_Spine1','Bip01_L_Foot','Bip01_R_Foot'):continue
    idx=[int(x) for x in sw.group(3).replace('\n','').split(',') if x.strip()]
    w=[float(x) for x in sw.group(4).replace('\n','').split(',') if x.strip()]
    pts=[vs[i] for i,ww in zip(idx,w) if ww>0.5]
    if not pts: continue
    xs,ys,zs=zip(*pts)
    print(b,len(pts),'y %.3f..%.3f'%(min(ys),max(ys)),'x %.3f..%.3f'%(min(xs),max(xs)),'z %.3f..%.3f'%(min(zs),max(zs)))
