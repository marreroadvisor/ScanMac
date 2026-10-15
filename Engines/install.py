"""Run with Python3.12 on macOS. Installs only into ScanMac Application Support.
Downloads dependencies/weights; never uploads user documents or configures services.
"""
import sys, subprocess, venv, json, urllib.request, hashlib, os
from pathlib import Path
if sys.version_info[:2] != (3,12): raise SystemExit('Usa Python3.12 para este entorno reproducible.')
source=Path(__file__).resolve().parent
root=Path.home()/'Library/Application Support/ScanMac/Engines'
root.mkdir(parents=True,exist_ok=True)
venv.EnvBuilder(with_pip=True).create(root/'venv')
subprocess.run([str(root/'venv/bin/python3'),'-m','pip','install','--disable-pip-version-check','-r',str(source/'requirements.txt')],check=True)
models=root/'models';models.mkdir(exist_ok=True)
for model in json.loads((source/'models.json').read_text()):
 dst=models/model['name']
 if not dst.exists() or hashlib.sha256(dst.read_bytes()).hexdigest()!=model['sha256']:
  part=dst.with_suffix(dst.suffix+'.part')
  with urllib.request.urlopen(model['url'],timeout=90) as response,part.open('wb') as out:
   while chunk:=response.read(1024*1024):out.write(chunk)
  if hashlib.sha256(part.read_bytes()).hexdigest()!=model['sha256']:raise SystemExit('Integridad incorrecta: '+model['name'])
  os.replace(part,dst)
 print('VERIFICADO',model['name'])
(root/'installed.json').write_text(json.dumps({'version':1,'python':sys.version,'models':json.loads((source/'models.json').read_text())},indent=2))
print('Motores instalados localmente. No se inicia ningún servidor.')
