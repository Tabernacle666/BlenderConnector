import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from dispatch import resolve_safe

class ProtocolTest(unittest.TestCase):
    def test_safe_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'fan50s.glb').write_bytes(b'fake')
            self.assertEqual(resolve_safe(root, 'fan50s.glb','.glb'), (root/'fan50s.glb').resolve())
    def test_path_traversal(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            for name in ('../outside.glb', 'C:/Windows/system32/thing.glb', '../x/../x.glb', 'name.exe'):
                with self.subTest(name=name):
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        resolve_safe(root,name,'.glb')
    def test_examples_have_valid_ids(self):
        root=Path(__file__).resolve().parents[1]
        for example in (root/'examples').glob('*.json'):
            data=json.loads(example.read_text(encoding='utf-8'))
            self.assertEqual(data['schema'],1)
            self.assertIn(data['operation'], ('inspect_glb','preview_glb','normalize_glb','repository_script'))

if __name__ == '__main__': unittest.main()
