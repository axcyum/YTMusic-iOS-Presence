"""Build on macOS with Xcode and an official iOS Social SDK xcframework."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import sys

def run(args):
    subprocess.run(args, check=True)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sdk', required=True, help='Path to discord_partner_sdk.xcframework')
    p.add_argument('--ipa', help='Optional input IPA to package after compilation')
    p.add_argument('--out', help='New unsigned IPA path (required with --ipa)')
    a = p.parse_args()
    if platform.system() != 'Darwin': p.error('Compilation requires macOS with Xcode; Windows cannot run this build')
    if bool(a.ipa) != bool(a.out): p.error('--ipa and --out must be supplied together')
    root = Path(__file__).resolve().parents[1]
    config = json.loads((root/'config.json').read_text())
    appid = str(config['application_id'])
    if not appid.isdecimal() or not 0 < int(appid) < 2**64: p.error('Invalid Application ID')
    sdk = Path(a.sdk).resolve()
    metadata = plistlib.loads((sdk/'Info.plist').read_bytes())
    slices = [x for x in metadata['AvailableLibraries'] if x.get('SupportedPlatform') == 'ios'
        and not x.get('SupportedPlatformVariant') and 'arm64' in x.get('SupportedArchitectures', [])]
    if len(slices) != 1: p.error('Expected one iOS device arm64 SDK slice')
    fw = sdk/slices[0]['LibraryIdentifier']/slices[0]['LibraryPath']
    if fw.name != 'discord_partner_sdk.framework': p.error('Unexpected SDK framework name')
    build = root/'build'; build.mkdir(exist_ok=True)
    # JSON strings are valid C string literals for these ASCII settings.
    asset = str(config['asset_key'])
    if not asset.isascii(): p.error('Asset key must be ASCII')
    (build/'Config.h').write_text(f'#define YTMP_APPLICATION_ID {appid}ULL\n'
        f'#define YTMP_APPLICATION_ID_STRING {json.dumps(appid)}\n'
        f'#define YTMP_ASSET_KEY {json.dumps(asset)}\n')
    with (build/'Config.h').open('a') as header:
        header.write(f'#define YTMP_USE_ASSETS {1 if config.get("use_assets",False) else 0}\n')
    sysroot = subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'], text=True).strip()
    dylib = build/'YTMusicPresence.dylib'
    run(['xcrun','--sdk','iphoneos','clang++','-dynamiclib','-std=c++20','-fobjc-arc','-arch','arm64',
        '-isysroot',sysroot,'-miphoneos-version-min='+config['minimum_ios'],
        '-I'+str(build),'-F'+str(fw.parent),'-framework','discord_partner_sdk',
        '-framework','Foundation','-framework','UIKit','-framework','CoreGraphics','-framework','MediaPlayer','-framework','Security',
        '-Wl,-install_name,@rpath/YTMusicPresence.dylib','-Wl,-rpath,@loader_path',
        str(root/'src'/'Presence.mm'),str(root/'src'/'Logger.mm'),'-o',str(dylib)])
    run(['otool','-L',str(dylib)])
    if a.ipa:
        run([sys.executable,str(root/'tools'/'package_ipa.py'),'--ipa',a.ipa,
            '--dylib',str(dylib),'--framework',str(fw),'--out',a.out])
    else: print('Built:', dylib)

if __name__ == '__main__': main()
