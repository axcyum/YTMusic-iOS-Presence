import hashlib
import io
import plistlib
from pathlib import Path
import sys
import tarfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from package_deb import make_deb, SCHEMES, tar_bytes


def read_ar(data):
    assert data[:8] == b'!<arch>\n'
    result, offset = {}, 8
    while offset < len(data):
        header = data[offset:offset + 60]
        assert header[-2:] == b'`\n'
        size = int(header[48:58])
        result[header[:16].decode().strip().rstrip('/')] = data[offset + 60:offset + 60 + size]
        offset += 60 + size + size % 2
    assert offset == len(data)
    return result


def unpack(data):
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        return {item.name.removeprefix('./'): (archive.extractfile(item).read(), item.mode)
                for item in archive if item.isfile()}


class DebTest(unittest.TestCase):
    def test_layout_permissions_filter_and_checksums(self):
        base = 'Library/MobileSubstrate/DynamicLibraries/'
        payload = {base + 'YTMusicPresence.dylib': (b'odd', 0o755),
                   base + 'YTMusicPresence.plist': (plistlib.dumps({
                       'Filter': {'Bundles': ['com.google.ios.youtubemusic']}}), 0o644),
                   base + 'YTMusicPresenceResources/discord_partner_sdk.framework/discord_partner_sdk': (b'sdk', 0o755)}
        for arch, prefix in SCHEMES.items():
            with self.subTest(arch=arch):
                members = read_ar(make_deb(arch, '0.4.1', payload))
                self.assertEqual(list(members), ['debian-binary', 'control.tar.gz', 'data.tar.gz'])
                self.assertEqual(members['debian-binary'], b'2.0\n')
                control, data = unpack(members['control.tar.gz']), unpack(members['data.tar.gz'])
                self.assertIn(f'Architecture: {arch}\n'.encode(), control['control'][0])
                self.assertEqual(data, {prefix + name: value for name, value in payload.items()})
                for line in control['md5sums'][0].decode().splitlines():
                    digest, name = line.split('  ')
                    self.assertEqual(hashlib.md5(data[name][0]).hexdigest(), digest)
                parsed = plistlib.loads(data[prefix + base + 'YTMusicPresence.plist'][0])
                self.assertEqual(parsed['Filter']['Bundles'], ['com.google.ios.youtubemusic'])

    def test_reject_unsafe_metadata_and_paths(self):
        with self.assertRaises(ValueError):
            make_deb('iphoneos-arm', '1\nDepends: bad', {})
        with self.assertRaises(ValueError):
            tar_bytes({'../escape': (b'', 0o644)})


if __name__ == '__main__':
    unittest.main()
