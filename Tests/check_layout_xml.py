"""Usage: python3 check_layout_xml.py DIRECTORY_WITH_SYNTHETIC_EXPORTS"""
import pathlib
import posixpath
import sys
import xml.etree.ElementTree as E
import zipfile

root = pathlib.Path(sys.argv[1])
ns = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
      'p': 'http://schemas.openxmlformats.org/presentationml/2006/main',
      'a': 'http://schemas.openxmlformats.org/drawingml/2006/main'}
with zipfile.ZipFile(root / 'geometry.xlsx') as archive:
    sheet = E.fromstring(archive.read('xl/worksheets/sheet1.xml'))
    cells = {cell.attrib['r']: cell for cell in sheet.findall('.//s:c', ns)}
    assert cells['B2'].find('s:v', ns).text == '12.50' and 't' not in cells['B2'].attrib
    assert cells['B3'].find('s:v', ns).text == '-42'
    assert cells['A3'].attrib['t'] == 'inlineStr' and cells['A3'].find('.//s:t', ns).text == '00123'
    assert cells['A2'].find('.//s:t', ns).text == 'España & <uno>'
with zipfile.ZipFile(root / 'editable.pptx') as archive:
    slide = E.fromstring(archive.read('ppt/slides/slide1.xml'))
    shapes = slide.findall('.//p:sp', ns)
    assert len(shapes) == 6
    assert shapes[2].find('.//a:t', ns).text == 'España & <uno>'
    left, right = [shapes[i].find('.//a:off', ns).attrib for i in (0, 1)]
    assert int(right['x']) > int(left['x']) and right['y'] == left['y']
    assert slide.find('.//p:pic', ns) is not None
    for name in archive.namelist():
        if name.endswith(('.xml', '.rels')):
            E.fromstring(archive.read(name))
        if name.endswith('.rels'):
            base = '' if name == '_rels/.rels' else posixpath.dirname(posixpath.dirname(name))
            for relation in E.fromstring(archive.read(name)):
                assert posixpath.normpath(posixpath.join(base, relation.attrib['Target'])) in archive.namelist()
print('PASS editable text shapes, geometric alignment, raster background, package relationships, numeric cells and literal IDs')

with zipfile.ZipFile(root / 'positioned.docx') as archive:
    word = E.fromstring(archive.read('word/document.xml'))
    w = {'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main','v':'urn:schemas-microsoft-com:vml'}
    assert len(word.findall('.//w:txbxContent',w)) == 12
    assert len(word.findall('.//v:imagedata',w)) == 2
    assert len(word.findall('.//w:sectPr',w)) == 2
    texts = [e.text for e in word.findall('.//w:t',w)]
    assert 'España & <uno>' in texts and '00123' in texts
    for name in archive.namelist():
        if name.endswith(('.xml','.rels')): E.fromstring(archive.read(name))
with zipfile.ZipFile(root / 'geometry.xlsx') as archive:
    E.fromstring(archive.read('xl/styles.xml'))
    assert 'xl/media/page1.png' in archive.namelist()
    assert E.fromstring(archive.read('xl/worksheets/sheet1.xml')).find('s:cols',ns) is not None
print('PASS positioned Word text, backgrounds, page sections, XLSX styles/widths and original-page reference image')
