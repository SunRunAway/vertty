#!/usr/bin/env python3
"""Manual macOS lid test; changes REAL power settings. Run in Terminal.

Quit Vhostty and Amphetamine first. The script enables protection, gives you
20 seconds to close the lid, sets disablesleep to 0, then attempts to set it
back to 1 after 5 seconds. Open the lid at least 45 seconds after closing it.
If the Mac sleeps, the script resumes when you open the lid. It restores the
original setting and saves timestamps and the system sleep log in /private/tmp.
Do not run as an automated regression test.
"""
import ctypes
from datetime import datetime
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


def output(*args):
    return subprocess.check_output(args, text=True)


def closed():
    state = output('/usr/sbin/ioreg', '-r', '-k', 'AppleClamshellState', '-d', '1')
    match = re.search(r'"AppleClamshellState"\s*=\s*(Yes|No)', state)
    if not match:
        raise RuntimeError('无法读取合盖状态，停止测试。')
    return match[1] == 'Yes'


def set_sleep_disabled(value):
    subprocess.run(['/usr/bin/sudo', '-n', '/usr/bin/pmset', '-a',
                    'disablesleep', str(value)], check=True)


def main():
    if sys.platform != 'darwin':
        raise RuntimeError('只能在 macOS 上运行。')
    for name in ['Vhostty', 'vhostty-sleep', 'Amphetamine']:
        result = subprocess.run(['/usr/bin/pgrep', '-x', name], capture_output=True)
        if result.returncode == 0:
            raise RuntimeError(f'请先退出 {name}，避免它改写电源设置，再运行脚本。')
        if result.returncode != 1:
            raise RuntimeError(f'无法检查 {name} 是否正在运行。')
    settings = output('/usr/bin/pmset', '-g')
    match = re.search(r'^\s*SleepDisabled\s+([01])\s*$', settings, re.M)
    if not match:
        raise RuntimeError('无法读取原始 SleepDisabled，停止测试。')
    original = int(match[1])
    directory = Path(tempfile.mkdtemp(prefix='vhostty-lid-test-', dir='/private/tmp'))
    (directory / 'before.txt').write_text(settings + '\n' + output('/usr/bin/pmset', '-g', 'assertions'))
    print(f'记录目录：{directory}', flush=True)

    # continuous advances during system sleep; absolute does not.
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    class Timebase(ctypes.Structure):
        _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
    base = Timebase()
    lib.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    if lib.mach_timebase_info(ctypes.byref(base)) != 0 or base.denom == 0:
        raise RuntimeError('无法读取系统时钟比例。')
    for name in ['mach_absolute_time', 'mach_continuous_time']:
        getattr(lib, name).restype = ctypes.c_uint64
        getattr(lib, name).argtypes = []
    ratio = base.numer / base.denom / 1_000_000_000

    with (directory / 'timeline.txt').open('w', buffering=1) as log:
        def record(label):
            absolute = lib.mach_absolute_time() * ratio
            continuous = lib.mach_continuous_time() * ratio
            log.write(f'{datetime.now().astimezone().isoformat(timespec="milliseconds")} '
                      f'{label} absolute={absolute:.6f} continuous={continuous:.6f}\n')
            log.flush()
            return absolute, continuous

        def interrupted(signum, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, interrupted)
        try:
            set_sleep_disabled(1)
            record('PROTECTION_ON')
            print('现在合盖，至少 45 秒后再开盖。20 秒后撤掉保护，再等 5 秒尝试恢复。', flush=True)
            time.sleep(20)
            if not closed():
                raise RuntimeError('没有检测到合盖，未开始测量。')
            start = record('SET_0_BEGIN')
            set_sleep_disabled(0)
            record('SET_0_RETURNED')
            time.sleep(5)
            end = record('SET_1_BEGIN')
            set_sleep_disabled(1)
            record('SET_1_RETURNED')
            elapsed = end[1] - start[1]
            suspended = max(0, elapsed - (end[0] - start[0]))
            log.write(f'测量区间实际经过 {elapsed:.3f} 秒，其中系统睡眠约 {suspended:.3f} 秒。\n')
            # Keep protection until the user opens the lid to read the result.
            while closed():
                time.sleep(.5)
            record('LID_OPEN')
        finally:
            try:
                set_sleep_disabled(original)
                record(f'RESTORED_{original}')
            except Exception as error:
                print(f'恢复原值失败：{error}\n请执行 sudo pmset -a disablesleep {original}', file=sys.stderr)
            # Preserve system events: a delayed timer alone does not prove sleep.
            with (directory / 'pmset-log.txt').open('w') as events:
                subprocess.run(['/usr/bin/pmset', '-g', 'log'], stdout=events, stderr=subprocess.STDOUT)
    print((directory / 'timeline.txt').read_text(), end='')
    print(f'测试记录：{directory}\n用 pmset-log.txt 中的 Sleep/Wake 事件核对入睡时间。')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('测试已中止。', file=sys.stderr)
        sys.exit(130)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f'测试未完成：{error}\n若 sudo 提示需要密码，先运行 sudo -v，再重试。', file=sys.stderr)
        sys.exit(1)
