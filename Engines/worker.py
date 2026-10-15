"""Offline image engines. Input/output are private local job files, never URLs.
Community Forensics architecture/preprocessing: MIT Jeongsoo Park (see licenses).
LaMa weights: Apache-2.0, see manifest and licenses. No remote model code.
"""
import os
os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1')
import sys, json, hashlib, io, math
from pathlib import Path
import numpy as np
from PIL import Image, ImageOps
import cv2

Image.MAX_IMAGE_PIXELS = 40_000_000

def verified_model(root, name):
    expected = {'community.safetensors':'b89f36275f3bf5e2b040eee36597a8f19db051bff9a473a9cf7b2466284fb387','big-lama.pt':'344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9'}
    file = root/name
    with file.open('rb') as f:
        digest = hashlib.file_digest(f,'sha256').hexdigest()
    if digest != expected[name]: raise ValueError('Integridad del modelo incorrecta: '+name)
    return file

def read_image(path):
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert('RGB')
        if im.width * im.height > 40_000_000: raise ValueError('Imagen demasiado grande')
        return np.asarray(im).copy()

def mask_image(a, request):
    h,w = a.shape[:2]; m = np.zeros((h,w), np.uint8)
    for r in request.get('zones', []):
        if len(r) != 4 or not all(isinstance(v,(int,float)) and math.isfinite(v) for v in r): raise ValueError('Zona inválida')
        x,y,rw,rh = r
        if min(r) < 0 or x+rw > 1.001 or y+rh > 1.001: raise ValueError('Zona fuera de la imagen')
        m[int(y*h):min(h,math.ceil((y+rh)*h)), int(x*w):min(w,math.ceil((x+rw)*w))] = 255
    if request.get('color_mask'):
        hsv = cv2.cvtColor(a,cv2.COLOR_RGB2HSV)
        colored = ((hsv[:,:,1] > 75) & (hsv[:,:,2] < 250)).astype('uint8')*255
        colored = cv2.dilate(colored,np.ones((3,3),np.uint8))
        m = cv2.bitwise_or(m,colored)
    if not np.any(m): raise ValueError('No se encontraron zonas. Selecciona trazos o pide propuestas IA.')
    if np.mean(m>0) > .60: raise ValueError('La selección supera el60% de la página. Reduce las zonas para conservar contenido.')
    return m

def cleanup(a, request, root, output):
    import torch
    torch.set_num_threads(4)
    m = mask_image(a,request)
    Image.fromarray(m).save(output/'mask.png')
    h,w = a.shape[:2]; scale = min(1,1024/max(h,w))
    nh,nw = max(8,round(h*scale)),max(8,round(w*scale))
    small = cv2.resize(a,(nw,nh),interpolation=cv2.INTER_AREA)
    mask = cv2.resize(m,(nw,nh),interpolation=cv2.INTER_NEAREST)
    ph,pw = (-nh)%8,(-nw)%8
    x = np.pad(small,((0,ph),(0,pw),(0,0)),mode='reflect').astype('float32')/255
    mm = np.pad(mask,((0,ph),(0,pw)),mode='reflect').astype('float32')/255
    model = torch.jit.load(str(verified_model(root,'big-lama.pt')), map_location='cpu').eval()
    with torch.inference_mode():
        pred = model(torch.from_numpy(x.transpose(2,0,1)).unsqueeze(0), torch.from_numpy(mm).unsqueeze(0).unsqueeze(0))
    restored = np.clip(pred[0].permute(1,2,0).numpy()[:nh,:nw]*255,0,255).astype('uint8')
    restored = cv2.resize(restored,(w,h),interpolation=cv2.INTER_CUBIC)
    result = np.where(m[:,:,None]>0, restored, a)
    Image.fromarray(result).save(output/'result.png')
    return dict(report='LaMa: fondo reconstruido localmente. Revisa la vista previa; no recupera texto oculto con certeza.', image='result.png', mask='mask.png', masked_fraction=float(np.mean(m>0)))

def detect_ai(a, root):
    import torch, timm
    from safetensors.torch import load_file
    from torchvision import transforms
    torch.set_num_threads(4)
    model = timm.create_model('vit_small_patch16_384.augreg_in21k_ft_in1k',pretrained=False,num_classes=1)
    state = load_file(str(verified_model(root,'community.safetensors')),device='cpu')
    state = {k.removeprefix('vit.'):v for k,v in state.items()}
    model.load_state_dict(state,strict=True); model.eval()
    transform = transforms.Compose([transforms.Resize(440),transforms.CenterCrop(384),transforms.ToTensor(),transforms.Normalize([.485,.456,.406],[.229,.224,.225])])
    with torch.inference_mode(): score = float(torch.sigmoid(model(transform(Image.fromarray(a)).unsqueeze(0))).item())
    return dict(score=score, report=f'Community Forensics (OwensLab,384): puntuación de clase sintética {score:.4f}.\nEs una salida del clasificador, no una probabilidad calibrada ni una prueba. Recorte central384px tras redimensionar el lado corto a440px.\nPuede fallar con escaneos, capturas, compresión y generadores nuevos. Un valor bajo no demuestra autenticidad. Recomendado: imagen original, no página PDF rasterizada.', model='OwensLab/commfor-model-384', revision='6076002bf0d9dd37537f965ee2f06f826c333b61')

def tamper(a, request, output):
    h,w = a.shape[:2]; s=min(1,1600/max(h,w)); small=cv2.resize(a,(max(1,round(w*s)),max(1,round(h*s))))
    im=Image.fromarray(small); b=io.BytesIO(); im.save(b,format='JPEG',quality=90)
    recompressed=np.asarray(Image.open(io.BytesIO(b.getvalue())).convert('RGB'))
    ela=np.abs(small.astype('float32')-recompressed.astype('float32')).mean(axis=2)
    top=max(1,float(np.percentile(ela,99))); heat=np.clip(ela/top*255,0,255).astype('uint8')
    Image.fromarray(cv2.cvtColor(cv2.applyColorMap(heat,cv2.COLORMAP_INFERNO),cv2.COLOR_BGR2RGB)).save(output/'ela.png')
    gray=cv2.cvtColor(small,cv2.COLOR_RGB2GRAY)
    keypoints,desc=cv2.SIFT_create(nfeatures=1800).detectAndCompute(gray,None)
    pairs=[]
    if desc is not None and len(desc)>3:
        matches=cv2.BFMatcher().knnMatch(desc,desc,k=3)
        for group in matches:
            if len(group)<3: continue
            first,second=group[1],group[2]
            p=np.array(keypoints[first.queryIdx].pt);q=np.array(keypoints[first.trainIdx].pt)
            if first.distance < .65*second.distance and np.linalg.norm(p-q)>40 and first.queryIdx<first.trainIdx: pairs.append((p,q))
    groups={}
    for p,q in pairs:
        d=q-p
        if d[0]<0: d=-d
        key=tuple(np.round(d/12).astype(int)); groups.setdefault(key,[]).append((p,q))
    repeated=[g for g in groups.values() if len(g)>=4]
    overlay=small.copy()
    for group in repeated:
        for p,q in group:
            cv2.circle(overlay,tuple(p.astype(int)),8,(255,40,40),2);cv2.circle(overlay,tuple(q.astype(int)),8,(255,40,40),2)
    Image.fromarray(overlay).save(output/'repeated.png')
    report=f'Análisis local de alteraciones\nELA JPEG90: error medio {float(ela.mean()):.3f}/255; percentil99 {top:.3f}.\nGrupos de puntos repetidos compatibles con desplazamiento: {len(repeated)}.\nELA destaca diferencias de recompresión; bordes, texto y texturas también producen señales. Repetición no implica copia fraudulenta. Sin señales tampoco demuestra autenticidad. No valida firmas digitales.'
    result=dict(report=report,image='ela.png',secondary='repeated.png',ela_mean=float(ela.mean()),repeated_groups=len(repeated))
    if request.get('reference'):
        ref=read_image(request['reference'])
        if ref.shape != a.shape: result['report']+='\nOriginal de comparación: dimensiones diferentes; no se alineó ni se comparó píxel a píxel.'
        else:
            diff=np.abs(a.astype('int16')-ref.astype('int16')).max(axis=2)
            changed=diff>12
            Image.fromarray((changed*255).astype('uint8')).save(output/'difference.png')
            fraction=float(changed.mean());result.update(changed_fraction=fraction,difference='difference.png')
            result['report']+=f'\nComparación de píxeles con original: {fraction*100:.2f}% supera12/255. Cambios de compresión también cuentan; requiere la misma alineación.'
    return result

def main():
    reqpath=Path(sys.argv[1]); r=json.loads(reqpath.read_text()); out=reqpath.parent
    a=read_image(r['input']); root=Path(r['models']); op=r['operation']
    if op=='cleanup': result=cleanup(a,r,root,out)
    elif op=='ai': result=detect_ai(a,root)
    elif op=='tamper':result=tamper(a,r,out)
    else: raise ValueError('Operación desconocida')
    result.update(input_sha256=hashlib.sha256(Path(r['input']).read_bytes()).hexdigest(),width=a.shape[1],height=a.shape[0])
    (out/'response.json').write_text(json.dumps(result,ensure_ascii=False))
if __name__=='__main__':
    try:main()
    except Exception as e:
        print(type(e).__name__+': '+str(e),file=sys.stderr);sys.exit(1)
