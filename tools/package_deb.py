"""Build rootful, rootless and RootHide debs; signing/relocation requires macOS."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

from macho import inspect

PACKAGE = 'com.axcyum.ytmusicpresence'
SCHEMES = {'iphoneos-arm': '', 'iphoneos-arm64': 'var/jb/', 'iphoneos-arm64e': ''}
SDK_NAME = 'discord_partner_sdk.framework/discord_partner_sdk'
SDK_LOAD = '@loader_path/YTMusicPresenceResources/' + SDK_NAME


def tar_bytes(files):
    """files maps relative POSIX paths to (bytes, unix mode)."""
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        directories = set()
        for name in files:
            parts = name.split('/')
            if name.startswith('/') or any(p in ('', '.', '..') for p in parts):
                raise ValueError('Unsafe package path')
            directories.update('/'.join(parts[:i]) for i in range(1, len(parts)))
        for name in sorted(directories):
            item = tarfile.TarInfo('./' + name)
            item.type = tarfile.DIRTYPE
            item.mode = 0o755
            archive.addfile(item)
        for name, (data, mode) in sorted(files.items()):
            item = tarfile.TarInfo('./' + name)
            item.mode, item.size = mode, len(data)
            archive.addfile(item, io.BytesIO(data))
    return gzip.compress(output.getvalue(), mtime=0)


def ar_bytes(members):
    result = bytearray(b'!<arch>\n')
    for name, data in members:
        header = f'{name + "/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n'
        if len(header) != 60:
            raise ValueError('Invalid ar header')
        result.extend(header.encode('ascii'))
        result.extend(data)
        if len(data) % 2:
            result.extend(b'\n')
    return bytes(result)


def make_deb(arch, version, payload):
    if not re.fullmatch(r'[0-9][A-Za-z0-9.+~]*', version):
        raise ValueError('Invalid version')
    prefix = SCHEMES[arch]
    files = {prefix + name: value for name, value in payload.items()}
    size = (sum(len(data) for data, _ in files.values()) + 1023) // 1024
    control = (f'Package: {PACKAGE}\nName: YTMusicPresence\nVersion: {version}\n'
               f'Architecture: {arch}\nMaintainer: axcyum\nSection: Tweaks\n'
               'Depends: firmware (>= 16.0), mobilesubstrate\n'
               f'Installed-Size: {size}\nHomepage: https://github.com/axcyum/YTMusicPresence\n'
               'Description: Discord Rich Presence for YouTube Music\n'
               ' On-device Social SDK integration with artwork and diagnostic logs.\n')
    md5sums = ''.join(f'{hashlib.md5(data).hexdigest()}  {name}\n'
                      for name, (data, _) in sorted(files.items()))
    return ar_bytes([('debian-binary', b'2.0\n'),
                     ('control.tar.gz', tar_bytes({'control': (control.encode(), 0o644),
                                                  'md5sums': (md5sums.encode(), 0o644)})),
                     ('data.tar.gz', tar_bytes(files))])


def prepare_payload(dylib, framework, notices, root, stage):
    base = 'Library/MobileSubstrate/DynamicLibraries/'
    local = stage / 'YTMusicPresence.dylib'
    shutil.copy2(dylib, local)
    copied_fw = stage / 'YTMusicPresenceResources' / framework.name
    shutil.copytree(framework, copied_fw, ignore=shutil.ignore_patterns('Headers', 'Modules', '_CodeSignature'))
    sdk = copied_fw / 'discord_partner_sdk'
    loads = inspect(local.read_bytes())['dylibs']
    matches = [name for name in loads if name.endswith(SDK_NAME)]
    if len(matches) != 1:
        raise ValueError('Expected one SDK dependency')
    subprocess.run(['install_name_tool', '-change', matches[0], SDK_LOAD, str(local)], check=True)
    for binary in (local, sdk):
        metadata = inspect(binary.read_bytes())
        if any(metadata['cryptids']):
            raise ValueError('Encrypted binary')
        for dependency in metadata['dylibs']:
            if dependency == SDK_LOAD or dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            raise ValueError('Unbundled dependency: ' + dependency)
    # Ad-hoc signatures for jailbreak loaders, applied after load-command changes.
    for target in (copied_fw, local):
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(target)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)
    payload = {base + 'YTMusicPresence.dylib': (local.read_bytes(), 0o755),
               base + 'YTMusicPresence.plist': (plistlib.dumps({
                   'Filter': {'Bundles': ['com.google.ios.youtubemusic']}}), 0o644)}
    for item in copied_fw.rglob('*'):
        if item.is_symlink():
            raise ValueError('Unexpected framework symlink')
        if item.is_file():
            payload[base + item.relative_to(stage).as_posix()] = (
                item.read_bytes(), 0o755 if item == sdk else 0o644)
    doc = 'usr/share/doc/' + PACKAGE + '/'
    payload[doc + 'copyright'] = ((root / 'LICENSE').read_bytes(), 0o644)
    payload[doc + 'Discord-License-Notices.txt'] = (notices.read_bytes(), 0o644)
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--notices', required=True)
    parser.add_argument('--dylib', default='build/YTMusicPresence.dylib')
    parser.add_argument('--version', required=True)
    parser.add_argument('--out', default='build/debs')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    sdk = Path(args.sdk)
    metadata = plistlib.loads((sdk / 'Info.plist').read_bytes())
    slices = [s for s in metadata['AvailableLibraries'] if s.get('SupportedPlatform') == 'ios'
              and not s.get('SupportedPlatformVariant') and 'arm64' in s['SupportedArchitectures']]
    if len(slices) != 1:
        raise ValueError('Expected one iOS arm64 device SDK slice')
    framework = sdk / slices[0]['LibraryIdentifier'] / slices[0]['LibraryPath']
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        payload = prepare_payload(Path(args.dylib), framework, Path(args.notices), root, Path(temp))
        report = {}
        for arch in SCHEMES:
            filename = f'YTMusicPresence_{args.version}~{arch}.deb'
            data = make_deb(arch, args.version, payload)
            path = out / filename
            if path.exists():
                raise FileExistsError(path)
            path.write_bytes(data)
            report[filename] = hashlib.sha256(data).hexdigest()
        (out / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in report.items()))
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
