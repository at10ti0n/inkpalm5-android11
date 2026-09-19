#!/usr/bin/env python3
"""Read-only inspection of the supplied incident-one ELF; no device access."""
import hashlib
import io
import lzma
import sys
from importlib.metadata import version
from pathlib import Path
from elftools.elf.elffile import ELFFile
from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB

EXPECTED = '4bf68ec57473f69f22f6a307566efa354edccff12a57940474381996c874bf71'
raw = Path(sys.argv[1]).read_bytes()
digest = hashlib.sha256(raw).hexdigest()
if digest != EXPECTED:
    raise SystemExit('Input SHA-256 differs; fixed addresses must not be reused.')
elf = ELFFile(io.BytesIO(raw))
print('SHA-256:', digest)
print('Dependencies:', 'capstone', version('capstone'), 'pyelftools', version('pyelftools'))
for note in elf.get_section_by_name('.note.gnu.build-id').iter_notes():
    print('Build ID:', note['n_desc'])
debug = ELFFile(io.BytesIO(lzma.decompress(elf.get_section_by_name('.gnu_debugdata').data())))
for symbol in debug.get_section_by_name('.symtab').iter_symbols():
    if '__thread_proxy' in symbol.name and 'EventThreadC1' in symbol.name:
        print('Recovered symbol:', hex(symbol['st_value']), symbol['st_size'], symbol.name)

def disassemble(section_name, start, end, mode):
    section = elf.get_section_by_name(section_name)
    base = section['sh_addr']
    instructions = list(Cs(CS_ARCH_ARM, mode).disasm(section.data()[start-base:end-base], start))
    if not instructions or instructions[-1].address + instructions[-1].size != end:
        raise RuntimeError('Incomplete decode at ' + hex(start))
    return instructions

rel = elf.get_section_by_name('.rel.plt')
symbols = elf.get_section(rel['sh_link'])
targets = {r['r_offset']: symbols.get_symbol(r['r_info_sym']).name for r in rel.iter_relocations()}
print('\nSampled PLT stub (ARM):')
for ins in disassemble('.plt', 0x1505e0, 0x1505ec, CS_MODE_ARM):
    print(f'{ins.address:08x}: {ins.mnemonic:10} {ins.op_str}')
# ARM PC in the first ADD is instruction address + 8.
got = 0x1505e0 + 8 + 0x13000 + 0x348
print('Effective GOT:', hex(got), 'relocation:', targets[got])
assert targets[got] == '_ZNK7android7RefBase9decStrongEPKv'

print('\nEventThread thread proxy (Thumb); literal pools omitted:')
calls = []
# Manually established code spans for this hash. Not a generic function decoder.
for start, end in [(0x9ff98, 0xa02ee), (0xa031c, 0xa0820)]:
    for ins in disassemble('.text', start, end, CS_MODE_THUMB):
        print(f'{ins.address:08x}: {ins.mnemonic:10} {ins.op_str}')
        if ins.mnemonic == 'blx' and ins.op_str == '#0x1505e0':
            calls.append((ins.address, (ins.address + ins.size) | 1))
assert [a for a, _ in calls] == [0xa04e0, 0xa050c, 0xa0674, 0xa07be]
print('\nDirect calls to sampled stub; ELF-relative Thumb return LR:')
for call, lr in calls:
    print(f'call=0x{call:x} LR=0x{lr:x}')
