"""Package an already compiled tweak plus official SDK into a new unsigned IPA."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import zipfile
from macho import add_presence, inspect

def digest(data):
    return hashlib.sha256(data).hexdigest()

def package(source, dylib, framework, output, config):
    source, dylib, framework, output = map(Path, (source, dylib, framework, output))
    if output.exists() or source.resolve() == output.resolve():
        raise ValueError('Output must be a new path; refusing to overwrite an IPA')
    if framework.name != 'discord_partner_sdk.framework':
        raise ValueError('Expected the iOS device discord_partner_sdk.framework')
    fwbin = framework / 'discord_partner_sdk'
    if not fwbin.is_file():
        raise ValueError('SDK framework binary not found')
    tweak = dylib.read_bytes()
    sdk = fwbin.read_bytes()
    inspect(tweak); inspect(sdk)  # Reject simulator/fat formats we do not support.
    sdk_loads = inspect(tweak)['dylibs']
    if not any('discord_partner_sdk.framework/discord_partner_sdk' in n for n in sdk_loads):
        raise ValueError('Tweak is not linked to the official SDK framework')
    with zipfile.ZipFile(source) as original:
        names = original.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate ZIP member names')
        infos = [n for n in names if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('/Info.plist')]
        if len(infos) != 1:
            raise ValueError('Expected exactly one main app in Payload')
        info_name = infos[0]
        root = info_name[:-len('Info.plist')]
        info = plistlib.loads(original.read(info_name))
        if info.get('CFBundleIdentifier') != 'com.google.ios.youtubemusic':
            raise ValueError('Expected original YouTube Music bundle ID')
        executable = info['CFBundleExecutable']
        if '/' in executable or '\\' in executable:
            raise ValueError('Invalid executable name')
        exe_name = root + executable
        before = original.read(exe_name)
        after = add_presence(before)
        appid = str(config['application_id'])
        if not appid.isdecimal() or not 0 < int(appid) < 2**64:
            raise ValueError('Invalid application ID')
        if ('YTMP_APPLICATION_ID='+appid+'\0').encode('ascii') not in tweak:
            raise ValueError('Compiled tweak Application ID does not match config; rebuild it')
        scheme = 'discord-' + appid
        urltypes = info.setdefault('CFBundleURLTypes', [])
        if not any(scheme in x.get('CFBundleURLSchemes', []) for x in urltypes):
            urltypes.append({'CFBundleURLName':'YTMusicPresence.oauth', 'CFBundleURLSchemes':[scheme]})
        queries = info.setdefault('LSApplicationQueriesSchemes', [])
        if 'discord' not in queries: queries.append('discord')
        info['UIFileSharingEnabled'] = True
        info['LSSupportsOpeningDocumentsInPlace'] = True
        changes = {info_name:plistlib.dumps(info, fmt=plistlib.FMT_BINARY), exe_name:after,
            root+'Frameworks/YTMusicPresence.dylib':tweak}
        prefix = root+'Frameworks/'+framework.name+'/'
        for item in sorted(framework.rglob('*')):
            if '_CodeSignature' in item.parts: continue
            name = prefix+item.relative_to(framework).as_posix()
            if item.is_symlink():
                raise ValueError('Symlink in iOS framework; normalize framework layout first')
            if item.is_file(): changes[name] = item.read_bytes()
        report = {'status':'unsigned; requires full app and nested-code re-signing',
            'application_id':appid, 'version':info.get('CFBundleShortVersionString'),
            'original_executable_sha256':digest(before), 'patched_executable_sha256':digest(after),
            'tweak_sha256':digest(tweak), 'sdk_sha256':digest(sdk),
            'load_commands':inspect(after),
            'preserved_tweaks':[n for n in names if n.endswith('.dylib') and 'YTMusicPresence' not in n]}
        output.parent.mkdir(parents=True, exist_ok=True)
        handle, temp = tempfile.mkstemp(dir=output.parent, prefix='ytmp-', suffix='.tmp')
        os.close(handle)
        try:
            with zipfile.ZipFile(temp, 'w', compression=zipfile.ZIP_DEFLATED) as target:
                for member in original.infolist():
                    if '/_CodeSignature/' in member.filename or member.filename == root+'embedded.mobileprovision': continue
                    if member.filename.startswith(prefix): continue
                    target.writestr(copy.copy(member), changes.pop(member.filename, original.read(member.filename)))
                for name, data in changes.items():
                    member = zipfile.ZipInfo(name)
                    member.compress_type = zipfile.ZIP_DEFLATED
                    executable_file = name.endswith('.dylib') or name.endswith('/discord_partner_sdk')
                    member.create_system = 3
                    member.external_attr = (stat.S_IFREG | (0o755 if executable_file else 0o644)) << 16
                    target.writestr(member, data)
            with zipfile.ZipFile(temp) as check:
                if check.testzip(): raise ValueError('ZIP CRC verification failed')
                final = inspect(check.read(exe_name))
                if '@rpath/YTMusicPresence.dylib' not in final['dylibs']: raise ValueError('Missing tweak load')
                for n in report['preserved_tweaks']:
                    if digest(check.read(n)) != digest(original.read(n)): raise ValueError('Existing tweak was changed')
            # Hard link is atomic and fails if another process created output meanwhile.
            os.link(temp, output)
        finally:
            Path(temp).unlink(missing_ok=True)
    report_path = output.with_suffix('.report.json')
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    return report

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ipa', required=True); p.add_argument('--dylib', required=True)
    p.add_argument('--framework', required=True); p.add_argument('--out', required=True)
    p.add_argument('--config', default=str(Path(__file__).resolve().parents[1]/'config.json'))
    a = p.parse_args()
    report = package(a.ipa, a.dylib, a.framework, a.out, json.loads(Path(a.config).read_text()))
    print(json.dumps(report, ensure_ascii=False, indent=2))

if __name__ == '__main__': main()
