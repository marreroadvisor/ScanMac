"""Synthetic image regression + optional public labeled classifier smoke benchmark.
Run with the isolated Engines venv. Public images stay outside distribution outputs.
"""
import sys, json, tempfile, subprocess, hashlib
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
source=Path(__file__).resolve().parents[1]
models=Path.home()/'Library/Application Support/ScanMac/Engines/models'
worker=source/'Engines/worker.py'
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
def run(operation,image,**extra):
 d=Path(tempfile.mkdtemp(prefix='job-',dir=out)); payload=dict(operation=operation,input=str(image.resolve()),models=str(models),**extra)
 (d/'request.json').write_text(json.dumps(payload))
 subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',sys.executable,str(worker),str(d/'request.json')],check=True,timeout=240)
 return d,json.loads((d/'response.json').read_text())
# A known smooth background with added red strokes: compare reconstruction to ground truth.
y,x=np.mgrid[:320,:256]; clean=np.stack([210+x*.1,225+y*.04,np.full_like(x,235)],axis=2).clip(0,255).astype('uint8')
im=Image.fromarray(clean); draw=ImageDraw.Draw(im);draw.line([(50,90),(130,140),(80,190),(190,230)],fill=(190,10,25),width=5)
input=out/'marked.png';im.save(input); original=np.asarray(im).copy()
d,r=run('cleanup',input,color_mask=True)
result=np.asarray(Image.open(d/'result.png')); mask=np.asarray(Image.open(d/'mask.png'))>0
assert np.array_equal(result[~mask],original[~mask]), 'Unmasked pixels changed'
before=float(np.abs(original.astype(float)-clean).mean(axis=2)[mask].mean());after=float(np.abs(result.astype(float)-clean).mean(axis=2)[mask].mean())
assert after<before, (before,after)
Image.fromarray(clean).save(out/'ground-truth.png');Image.fromarray(result).save(out/'reconstructed.png')
print('PASS LaMa: unchanged outside mask; masked MAE',round(before,3),'→',round(after,3),flush=True)
# Tampering has known pixel ground truth; report must avoid certifying authenticity.
rng=np.random.default_rng(73);base=rng.integers(20,235,(384,384,3),dtype='uint8');modified=base.copy();modified[210:310,210:310]=base[40:140,40:140]
Image.fromarray(base).save(out/'reference.png');Image.fromarray(modified).save(out/'modified.png')
d,r=run('tamper',out/'modified.png',reference=str((out/'reference.png').resolve()))
expected=float((np.abs(base.astype('int16')-modified.astype('int16')).max(axis=2)>12).mean())
assert abs(r['changed_fraction']-expected)<1e-10 and (d/'ela.png').exists() and (d/'difference.png').exists()
assert 'tampoco demuestra autenticidad' in r['report'] and r['repeated_groups']>=1
print('PASS ELA, repeated-pattern evidence and exact reference difference',flush=True)
report=dict(cleanup_masked_MAE_before=before,cleanup_masked_MAE_after=after,changed_fraction=r['changed_fraction'],repeated_groups=r['repeated_groups'],classifier=[])
if len(sys.argv)>2:
 fixtures=Path(sys.argv[2]); paths=sorted(fixtures.glob('fake-*.png'))+sorted(fixtures.glob('real-*.png'))
 for image in paths:
  d,r=run('ai',image);label=1 if image.name.startswith('fake-') else 0
  report['classifier'].append(dict(file=image.name,sha256=hashlib.sha256(image.read_bytes()).hexdigest(),label=label,score=r['score'],prediction=int(r['score']>=.5)))
  print(image.name,round(r['score'],5),flush=True)
 n=len(report['classifier']);fp=sum(r['label']==0 and r['prediction']==1 for r in report['classifier']);fn=sum(r['label']==1 and r['prediction']==0 for r in report['classifier'])
 report.update(samples=n,false_positives=fp,false_negatives=fn,threshold=.5,warning='Small nonrepresentative smoke sample; no calibration or general accuracy claim. Some examples are published by model authors and may overlap training/evaluation.')
 print('SMOKE BENCHMARK',n,'samples, FP',fp,'FN',fn,flush=True)
(out/'metrics.json').write_text(json.dumps(report,indent=2))
