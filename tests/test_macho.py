import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from macho import add_presence, inspect

def fixture(padding=512, cryptid=0):
    segment = bytearray(152)
    struct.pack_into('<II', segment, 0, 0x19, 152)
    segment[8:14] = b'__TEXT'
    struct.pack_into('<QQ', segment, 40, 0, 4096)
    struct.pack_into('<I', segment, 64, 1)
    section_offset = 32 + 152 + 24 + padding
    struct.pack_into('<I', segment, 72+48, section_offset)
    encryption = struct.pack('<6I', 0x2C, 24, section_offset, 4, cryptid, 0)
    header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 2, 176, 0, 0)
    return header + segment + encryption + b'\0'*padding + b'CODE'+b'\0'*1024

class MachoTest(unittest.TestCase):
    def test_preserves_sections_and_is_idempotent(self):
        original = fixture()
        patched = add_presence(original)
        self.assertEqual(len(original), len(patched))
        self.assertEqual(original[720:], patched[720:])
        self.assertIn('@rpath/YTMusicPresence.dylib', inspect(patched)['dylibs'])
        self.assertIn('@executable_path/Frameworks', inspect(patched)['rpaths'])
        self.assertEqual(patched, add_presence(patched))
    def test_rejects_encrypted(self):
        with self.assertRaisesRegex(ValueError, 'Encrypted'): add_presence(fixture(cryptid=1))
    def test_rejects_insufficient_padding(self):
        with self.assertRaisesRegex(ValueError, 'padding'): add_presence(fixture(padding=8))
    def test_rejects_nonzero_padding(self):
        data = bytearray(fixture()); data[210] = 1
        with self.assertRaisesRegex(ValueError, 'padding'): add_presence(data)
    def test_rejects_truncated_and_wrong_arch(self):
        with self.assertRaises(ValueError): inspect(b'\0'*31)
        data = bytearray(fixture()); struct.pack_into('<I',data,4,7)
        with self.assertRaises(ValueError): inspect(data)
    def test_rejects_malformed_command(self):
        data = bytearray(fixture()); struct.pack_into('<I',data,36,0)
        with self.assertRaises(ValueError): inspect(data)

if __name__ == '__main__': unittest.main()
