"""CPU-only post-configure mutation guard; restores the dependency in finally."""
import argparse,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--cmake',required=True);p.add_argument('--build',required=True);p.add_argument('--source',required=True);a=p.parse_args()
readme=pathlib.Path(a.source)/'README.md';original=readme.read_bytes()
try:
    readme.write_bytes(original+b'\npost-configuration pin regression probe\n')
    result=subprocess.run([a.cmake,'--build',a.build,'--target','velora-cleanup-native','-j2'],capture_output=True,text=True,timeout=60)
    assert result.returncode!=0 and 'source pin mismatch' in result.stdout+result.stderr,result.stdout+result.stderr
finally:readme.write_bytes(original)
print('post-configuration source mutation rejected at build time; source restored')
