import zlib, struct
def read(path):
    d=open(path,'rb').read(); assert d[:8]==b'\x89PNG\r\n\x1a\n'
    p=8; idat=b''; plte=None; trns=None
    while p<len(d):
        l,=struct.unpack('>I',d[p:p+4]); t=d[p+4:p+8]; c=d[p+8:p+8+l]; p+=12+l
        if t==b'IHDR': w,h,bd,ct,_,_,il=struct.unpack('>IIBBBBB',c)
        elif t==b'IDAT': idat+=c
        elif t==b'PLTE': plte=c
        elif t==b'tRNS': trns=c
    assert bd==8 and il==0, (bd,il)
    ch={0:1,2:3,3:1,4:2,6:4}[ct]; raw=zlib.decompress(idat); stride=w*ch
    rows=[]; prev=bytearray(stride); i=0
    for y in range(h):
        f=raw[i]; line=bytearray(raw[i+1:i+1+stride]); i+=1+stride
        for x in range(stride):
            a=line[x-ch] if x>=ch else 0; b=prev[x]; c=prev[x-ch] if x>=ch else 0
            if f==1: line[x]=(line[x]+a)&255
            elif f==2: line[x]=(line[x]+b)&255
            elif f==3: line[x]=(line[x]+(a+b)//2)&255
            elif f==4:
                pa=abs(b-c); pb=abs(a-c); pc=abs(a+b-2*c)
                pr=a if pa<=pb and pa<=pc else (b if pb<=pc else c)
                line[x]=(line[x]+pr)&255
        rows.append(line); prev=line
    px=[]
    for line in rows:
        r=[]
        for x in range(w):
            s=line[x*ch:(x+1)*ch]
            if ct==6: r.append(tuple(s))
            elif ct==2: r.append((s[0],s[1],s[2],255))
            elif ct==3:
                k=s[0]; a=trns[k] if trns and k<len(trns) else 255
                r.append((plte[k*3],plte[k*3+1],plte[k*3+2],a))
            elif ct==0: r.append((s[0],s[0],s[0],255))
            elif ct==4: r.append((s[0],s[0],s[0],s[1]))
        px.append(r)
    return w,h,px
def write(path,w,h,px):
    raw=b''.join(b'\x00'+bytes(v for p in row for v in p) for row in px)
    def chunk(t,c): return struct.pack('>I',len(c))+t+c+struct.pack('>I',zlib.crc32(t+c)&0xffffffff)
    open(path,'wb').write(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b''))
