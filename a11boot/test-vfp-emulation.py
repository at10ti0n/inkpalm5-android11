"""Run the actual old/new ARM callbacks, including mcount and stack frames.

Models a dying CPU running its idle thread while its VFP hardware still belongs
to a different task. This is the ownership case the upstream fix repairs.
"""
from pathlib import Path
import struct
import sys
import importlib.util
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM
from unicorn.arm_const import *

p = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('patch_vfp',p/'patch-vfp.py')
module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
backup = Path(sys.argv[1]).read_bytes()
fixed,_ = module.patch_boot(backup)
original = backup[2048:2048+18169856]
patched = fixed[2048:2048+18169856]
table = 0xc115c064
callback = 0xc0102cd4
stack = 0xd0001ff0
stop = 0xd1000000
regs = [UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3,
        UC_ARM_REG_R4,UC_ARM_REG_R5,UC_ARM_REG_R6,UC_ARM_REG_R7,
        UC_ARM_REG_R8,UC_ARM_REG_R9,UC_ARM_REG_R10,UC_ARM_REG_R11,
        UC_ARM_REG_R12]
for name, image in [('original',original),('patched',patched)]:
    for cpu in range(4):
        u = Uc(UC_ARCH_ARM, UC_MODE_ARM)
        u.mem_map(0xc0000000, 0x2000000)
        u.mem_map(0xd0000000, 0x10000)
        u.mem_map(stop, 0x1000)
        u.mem_write(0xc0008000, image)
        owners = [0xd2000000 + i*0x1000 for i in range(4)]
        u.mem_write(table, struct.pack('<4I',*owners))
        # current_thread_info() rounds SP down to 8 KiB; idle has no VFP owner.
        u.mem_write(0xd0000000+0x208, struct.pack('<I',4))
        for i,r in enumerate(regs): u.reg_write(r,0xaabb0000+i)
        saved = [u.reg_read(r) for r in regs[4:12]]
        u.reg_write(UC_ARM_REG_R0,cpu)
        u.reg_write(UC_ARM_REG_SP,stack)
        u.reg_write(UC_ARM_REG_LR,stop)
        u.emu_start(callback,stop,count=1000)
        assert u.reg_read(UC_ARM_REG_PC) == stop
        assert u.reg_read(UC_ARM_REG_SP) == stack
        assert u.reg_read(UC_ARM_REG_R0) == 0
        assert [u.reg_read(r) for r in regs[4:12]] == saved
        actual = list(struct.unpack('<4I',u.mem_read(table,16)))
        expected = owners.copy()
        if name == 'patched': expected[cpu] = 0
        assert actual == expected, (name,cpu,actual,expected)
        print(name,'cpu',cpu,'owner_after',hex(actual[cpu]),'ABI preserved')
print('PASS: old callback retains stale owners on all 4 CPUs; patched clears only dying CPU')
