"""Minimal, conservative thin arm64 Mach-O load command reader/patcher.

Never relocate sections: fail if there is insufficient zero-filled header space.
No cryptographic signing or decryption is performed.
"""
import struct

MAGIC = 0xFEEDFACF
ARM64 = 0x0100000C
LOAD_DYLIB = 0xC
RPATH = 0x8000001C

def commands(data):
    if len(data) < 32:
        raise ValueError('Truncated Mach-O header')
    magic, cpu, _, _, count, size, _, _ = struct.unpack_from('<8I', data)
    if magic != MAGIC or cpu != ARM64:
        raise ValueError('Expected thin little-endian arm64 Mach-O (fat binaries unsupported)')
    end = 32 + size
    if end > len(data):
        raise ValueError('Truncated load commands')
    pos = 32
    result = []
    for _ in range(count):
        if pos + 8 > end:
            raise ValueError('Malformed load commands')
        kind, length = struct.unpack_from('<II', data, pos)
        if length < 8 or length % 8 or pos + length > end:
            raise ValueError('Invalid load command length')
        result.append((kind, bytes(data[pos:pos+length])))
        pos += length
    if pos != end:
        raise ValueError('Load command size mismatch')
    return result

def string_command(command):
    offset = struct.unpack_from('<I', command, 8)[0]
    if offset < 12 or offset >= len(command):
        raise ValueError('Invalid string command offset')
    return command[offset:].split(b'\0', 1)[0].decode('utf-8')

def inspect(data):
    result = {'dylibs': [], 'rpaths': [], 'cryptids': []}
    for kind, command in commands(data):
        if kind in (LOAD_DYLIB, 0x80000018, 0x8000001F):
            result['dylibs'].append(string_command(command))
        elif kind == RPATH:
            result['rpaths'].append(string_command(command))
        elif kind in (0x21, 0x2C):
            result['cryptids'].append(struct.unpack_from('<I', command, 16)[0])
    return result

def _make_string(kind, value):
    offset = 24 if kind == LOAD_DYLIB else 12
    encoded = value.encode('utf-8') + b'\0'
    length = (offset + len(encoded) + 7) & ~7
    header = struct.pack('<III', kind, length, offset)
    if kind == LOAD_DYLIB:
        header += struct.pack('<III', 0, 0, 0)
    return (header + encoded).ljust(length, b'\0')

def add_presence(data):
    existing = inspect(data)
    if any(existing['cryptids']):
        raise ValueError('Encrypted executable; cannot inject into this input')
    new = []
    name = '@rpath/YTMusicPresence.dylib'
    if name not in existing['dylibs']:
        new.append(_make_string(LOAD_DYLIB, name))
    if '@executable_path/Frameworks' not in existing['rpaths']:
        new.append(_make_string(RPATH, '@executable_path/Frameworks'))
    if not new:
        return bytes(data)
    count, size = struct.unpack_from('<II', data, 16)
    end = 32 + size
    boundaries = []
    for kind, command in commands(data):
        if kind == 0x19:  # LC_SEGMENT_64
            if len(command) < 72:
                raise ValueError('Malformed segment')
            fileoff, filesize = struct.unpack_from('<QQ', command, 40)
            if fileoff and filesize:
                boundaries.append(fileoff)
            section_count = struct.unpack_from('<I', command, 64)[0]
            if 72 + 80*section_count > len(command):
                raise ValueError('Malformed section list')
            for i in range(section_count):
                sec = 72 + 80*i
                offset = struct.unpack_from('<I', command, sec+48)[0]
                flags = struct.unpack_from('<I', command, sec+64)[0]
                if offset and (flags & 0xff) not in (1, 0xC, 0x12):
                    boundaries.append(offset)
        elif kind == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', command, 8)
            if nsyms and symoff: boundaries.append(symoff)
            if strsize and stroff: boundaries.append(stroff)
        elif kind in (0x1D, 0x26, 0x29, 0x2B, 0x80000033, 0x80000034):
            offset, length = struct.unpack_from('<II', command, 8)
            if offset and length: boundaries.append(offset)
    if not boundaries or min(boundaries) < end:
        raise ValueError('Cannot determine safe Mach-O header padding')
    extra = b''.join(new)
    if end + len(extra) > min(boundaries) or any(data[end:end+len(extra)]):
        raise ValueError('Insufficient zero-filled header padding; use a relocating injector on macOS')
    patched = bytearray(data)
    patched[end:end+len(extra)] = extra
    struct.pack_into('<II', patched, 16, count+len(new), size+len(extra))
    assert name in inspect(patched)['dylibs']
    return bytes(patched)
