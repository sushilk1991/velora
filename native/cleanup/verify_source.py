#!/usr/bin/env python3
"""Check exact upstream source bytes for Git checkouts or extracted tarballs."""
import hashlib,json,pathlib,sys

def tree_hash(root):
    h=hashlib.sha256()
    for path in sorted(root.rglob('*')):
        relative=path.relative_to(root)
        if '.git' in relative.parts:continue
        if path.is_symlink():kind=b'L';content=path.readlink().as_posix().encode()
        elif path.is_file():kind=b'F';content=path.read_bytes()
        else:continue
        h.update(kind+relative.as_posix().encode()+b'\0'+hashlib.sha256(content).digest())
    return h.hexdigest()

if __name__=='__main__':
    root=pathlib.Path(sys.argv[1]).resolve();pins=json.loads(pathlib.Path(sys.argv[2]).read_text())
    actual=tree_hash(root)
    if actual!=pins['source_tree_sha256']:
        raise SystemExit('llama.cpp source pin mismatch: expected '+pins['source_tree_sha256']+', got '+actual+'; use exact commit '+pins['commit'])
    print('Verified llama.cpp '+pins['commit']+' source tree '+actual)
