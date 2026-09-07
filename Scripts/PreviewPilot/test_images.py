"""Exercise the real macOS decoder against valid and truncated PNG payloads."""
import binascii
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data))


@unittest.skipUnless(sys.platform == 'darwin', 'Native decoder uses Apple ImageIO')
class ImageIntegrityTests(unittest.TestCase):
    def test_decoder_rejects_empty_and_truncated_exports(self):
        header = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
        valid = header + png_chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00\xff')) + png_chunk(b'IEND', b'')
        decoder = Path(__file__).with_name('ValidatePreviewImages.swift')
        with tempfile.TemporaryDirectory() as folder:
            image = Path(folder) / 'probe.png'
            for payload, succeeds in [(None, False), (valid, True), (header, False), (valid[:-16], False)]:
                with self.subTest(payload_size=len(payload) if payload else 0):
                    if payload is not None:
                        image.write_bytes(payload)
                    result = subprocess.run(['swift', str(decoder), folder], capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
