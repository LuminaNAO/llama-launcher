#!/usr/bin/env python3
"""Read or rewrite the drafter fingerprint in an LSCKPT4 checkpoint sidecar.
  sidecar_hdr.py show <file.ckpt>
  sidecar_hdr.py patch <in.ckpt> <out.ckpt> <new-fingerprint>   (test helper: forge the fingerprint)"""
import struct, sys
def read_hdr(b):
    magic = b[:8]; ver, = struct.unpack_from('<I', b, 8); fl, = struct.unpack_from('<I', b, 12)
    fp = b[16:16+fl].decode(); cnt, = struct.unpack_from('<Q', b, 16+fl)
    return magic, ver, fp, cnt, 16+fl+8
cmd = sys.argv[1]
if cmd == 'show':
    b = open(sys.argv[2],'rb').read(4200)
    if b[:7] != b'LSCKPT4': print('magic:', b[:8]); sys.exit(0)
    m, v, fp, c, off = read_hdr(b); print(f'magic={m} state_ver={v} fingerprint={fp!r} count={c}')
elif cmd == 'patch':
    src, dst, newfp = sys.argv[2:5]
    with open(src,'rb') as f: head = f.read(4200)
    m, v, fp, c, off = read_hdr(head)
    nf = newfp.encode()
    with open(src,'rb') as fi, open(dst,'wb') as fo:
        fo.write(m); fo.write(struct.pack('<I', v)); fo.write(struct.pack('<I', len(nf))); fo.write(nf)
        fi.seek(16+len(fp.encode())); fo.write(fi.read())
    print(f'patched fingerprint {fp!r} -> {newfp!r}')
