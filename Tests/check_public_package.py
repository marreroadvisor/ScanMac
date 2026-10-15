"""Audit tracked files only; never inspects user Application Support data."""
import json, pathlib, re, subprocess
root=pathlib.Path(__file__).resolve().parents[1]
files=subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
for name in filter(None,files):
 p=root/name
 assert p.is_file(),name
 assert p.suffix.lower() not in {'.pdf','.sqlite','.sqlite3','.db','.pem','.key','.p12','.pt','.pth','.safetensors','.gguf','.zip'},name
 assert not any(x in p.parts for x in ('venv','.venv','__pycache__','ImportRecovery')),name
 assert p.name not in {'library.json','folders.json','trashed-folders.json','PROJECT_MEMORY.md','.env'},name
 if p.suffix in {'.swift','.py','.sh','.json','.md','.txt','.html','.yml'}:
  text=p.read_text()
  # Compose patterns so the audit does not match its own source.
  for pattern in [r'/' + 'Users/' + r'[^/]+/',r'gh[pousr]_' + r'[A-Za-z0-9]{20,}',r'sk-' + r'[A-Za-z0-9]{30,}',r'-----BEGIN ' + r'(?:RSA |EC |OPENSSH )?PRIVATE KEY-----']:
   assert not re.search(pattern,text),name
for item in json.loads((root/'Engines/models.json').read_text()):
 assert re.fullmatch(r'[a-f0-9]{64}',item['sha256']) and item['url'].startswith('https://')
assert 'MIT License' in (root/'LICENSE').read_text()
print('PASS tracked public files contain no private library, absolute user paths, credentials, model weights or binary releases')
