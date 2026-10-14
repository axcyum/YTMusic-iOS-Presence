import json
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from macho import _make_string, LOAD_DYLIB, inspect
from package_ipa import package
from test_macho import fixture

class PackageTest(unittest.TestCase):
    def test_full_package_preserves_input_and_tweaks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); fw = root/'discord_partner_sdk.framework'; fw.mkdir()
            (fw/'discord_partner_sdk').write_bytes(fixture())
            sdkload = _make_string(LOAD_DYLIB,'@rpath/discord_partner_sdk.framework/discord_partner_sdk')
            tweak = bytearray(fixture()); tweak[208:208+len(sdkload)] = sdkload
            struct.pack_into('<II',tweak,16,3,176+len(sdkload))
            tweak += b'YTMP_APPLICATION_ID=1559887091171852310\0'
            dll = root/'YTMusicPresence.dylib'; dll.write_bytes(tweak)
            ipa = root/'input.ipa'; prefix = 'Payload/YouTubeMusic.app/'
            info = {'CFBundleIdentifier':'com.google.ios.youtubemusic',
                'CFBundleExecutable':'YouTubeMusic','CFBundleURLTypes':[{'CFBundleURLSchemes':['existing']}],
                'UIBackgroundModes':['audio']}
            with zipfile.ZipFile(ipa,'w') as z:
                z.writestr(prefix+'Info.plist',plistlib.dumps(info))
                z.writestr(prefix+'YouTubeMusic',fixture())
                z.writestr(prefix+'Frameworks/YTMusicUltimate.dylib',b'unchanged-existing-tweak')
                z.writestr(prefix+'_CodeSignature/CodeResources',b'old-signature')
            original = ipa.read_bytes(); out = root/'output.ipa'
            package(ipa,dll,fw,out,{'application_id':'1559887091171852310'})
            self.assertEqual(original,ipa.read_bytes())
            with zipfile.ZipFile(out) as z:
                final = plistlib.loads(z.read(prefix+'Info.plist'))
                self.assertEqual(final['UIBackgroundModes'],['audio'])
                self.assertTrue(final['UIFileSharingEnabled'])
                self.assertTrue(final['LSSupportsOpeningDocumentsInPlace'])
                self.assertEqual(final['CFBundleURLTypes'][0]['CFBundleURLSchemes'],['existing'])
                self.assertIn('discord-1559887091171852310',final['CFBundleURLTypes'][1]['CFBundleURLSchemes'])
                self.assertEqual(z.read(prefix+'Frameworks/YTMusicUltimate.dylib'),b'unchanged-existing-tweak')
                self.assertIn('@rpath/YTMusicPresence.dylib',inspect(z.read(prefix+'YouTubeMusic'))['dylibs'])
                self.assertNotIn(prefix+'_CodeSignature/CodeResources',z.namelist())
            with self.assertRaisesRegex(ValueError,'overwrite'): package(ipa,dll,fw,out,{'application_id':'1'})

if __name__ == '__main__': unittest.main()
