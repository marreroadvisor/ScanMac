"""Validate shipped catalogs; no network/model dependency at runtime or in tests."""
import json,pathlib,re,sys,collections,unicodedata
root=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'Resources/Languages')
keys=json.loads((root/'keys.json').read_text());languages=json.loads((root/'languages.json').read_text())
assert len(languages)==63 and len({r[0] for r in languages})==63
expected=set(keys)
english=json.loads((root/"en.json").read_text())
def numbers(text):
    text=re.sub(r"\{\d+\}","",text)
    text="".join(str(unicodedata.digit(c)) if c.isdigit() else c for c in text)
    return collections.Counter(re.findall(r"\d+",text))
placeholder=lambda x: sorted(re.findall(r'\{\d+\}',x))
for code,native,name in languages:
 p=root/(code+'.json');d=json.loads(p.read_text())
 assert set(d)==expected,(code,'missing',expected-set(d),'extra',set(d)-expected)
 for k,v in d.items():
  assert isinstance(v,str) and v.strip(),(code,k,'empty')
  assert placeholder(k)==placeholder(v),(code,k,'placeholder',v)
  assert '⁇' not in v and '<unk>' not in v,(code,k,'unknown model symbol')
  assert not (numbers(english[k])-numbers(v)),(code,k,'literal numeric value changed')
  words=v.split();groups=collections.Counter(tuple(words[i:i+5]) for i in range(max(0,len(words)-4)))
  assert not groups or max(groups.values())<=4,(code,k,'repetition')
  assert not any(0xD800<=ord(c)<=0xDFFF for c in v),(code,k,'invalid Unicode')
 for brand in ['SM','ScanMac']:
  assert d[brand]==brand,(code,brand,'brand changed')
source_directory=root.parent.parent/'Source'
if source_directory.exists():
 for source in source_directory.glob('*.swift'):
  for match in re.finditer(r'\btr\(\s*("(?:[^"\\]|\\.)*")',source.read_text()):
   key=json.loads(match[1])
   assert key in expected,(source.name,'undeclared UI key',key)
print(f'PASS catalog validation: {len(languages)} languages × {len(keys)} keys; complete coverage, Unicode, placeholders, numeric values, no unknown model symbols/repetition, brand preservation')
