#!/usr/bin/env python3
"""Drive real menu processes in disposable Docker; no WAN measurements."""
import os
import pathlib
import pty
import select
import subprocess
import sys
import tempfile
import time

assert pathlib.Path('/.dockerenv').exists(), 'Disposable Docker required'
SCRIPT = sys.argv[1] if len(sys.argv) > 1 else '/src/vps-tune.sh'
STATE = pathlib.Path('/var/lib/singbox-tune')
CONFIG = pathlib.Path('/etc/sysctl.d/99-zz-singbox-tune.conf')
passed = 0


def ok(name):
    global passed
    passed += 1
    print('PASS', name, flush=True)


def run(inputs, args=('menu', '--container-test')):
    result = subprocess.run(['bash', SCRIPT, *args], input=inputs, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=45)
    assert result.returncode == 0, result.stdout
    assert '已退出菜单' in result.stdout, result.stdout
    return result.stdout


def assert_clean():
    assert not STATE.exists(), 'Preview/cancel created persistent state'
    assert not CONFIG.exists(), 'Preview/cancel wrote sysctl config'


if STATE.exists():
    subprocess.run(['bash', SCRIPT, 'rollback', '--container-test'], check=True)
assert_clean()

# Default entry really needs and supports a TTY; don't only test explicit menu.
master, slave = pty.openpty()
process = subprocess.Popen(['bash', SCRIPT], stdin=slave, stdout=slave, stderr=slave,
                           start_new_session=True)
os.close(slave)
raw = b''
deadline = time.monotonic() + 10
try:
    while '请选择 [0]'.encode() not in raw:
        assert time.monotonic() < deadline, raw.decode(errors='replace')
        if select.select([master], [], [], 0.2)[0]:
            raw += os.read(master, 65536)
    os.write(master, b'0\n')
    assert process.wait(timeout=10) == 0
finally:
    if process.poll() is None:
        process.kill()
    os.close(master)
assert_clean()
result = subprocess.run(['bash', SCRIPT], input='', text=True, capture_output=True)
assert result.returncode != 0 and '交互菜单需要终端' in result.stderr
ok('No-argument TTY menu; unattended empty input cannot apply')

output = run('invalid\n4\n8\n5\n0\n')
for message in ('请选择 0～8', '容器测试不发起公网测速', '容器内禁止重启宿主系统', '待生效或未验证'):
    assert message in output, output
assert_clean()
ok('Invalid selection, check returns to menu, container WAN/reboot guards')

# Full install plan then cancel; kernel APT is never started.
output = run('1\n0\n0\n')
assert 'kernel=linux-xanmod-lts-' in output and '未写入调优配置' in output, output
assert_clean()
output = run('2\n\n0\n')
assert 'kernel=skip' in output and '未写入调优配置' in output, output
assert_clean()
ok('Full/kernel-skip plan, cancel and default preview perform no configuration writes')

# Input validation followed by a valid BDP plan and preview.
output = run('3\n3\n1\n0\n150\n2\nNaN\n1000\n2\n0\n')
for message in ('请输入大于 0', 'RTT=150 ms', 'BDP=17.881393 MiB', 'wanted=48 MiB'):
    assert message in output, output
assert_clean()
ok('Smart BDP menu validates inputs and previews real RTT calculation')

with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as fixture:
    fixture.write('{"type":"result","upload":{"bandwidth":125000000},"download":{"bandwidth":250000000}}')
    fixture.flush()
    output = run(f'3\n2\n3\n{fixture.name}\n2\n0\n')
    assert 'smart/overseas-bdp' in output and 'source=ookla-json' in output, output
assert_clean()
ok('JSON menu import previews bandwidth without using Speedtest ping')

for choice, profile, rtt, wanted in (('1', 'asia-bdp', 100, 24), ('2', 'overseas-bdp', 200, 48)):
    output = run(f'3\n{choice}\n2\n1000\n2\n0\n')
    for expected in (f'smart/{profile}', f'RTT={rtt} ms', f'wanted={wanted} MiB', 'RTT-basis=region-planning-not-measured'):
        assert expected in output, output
    assert_clean()
ok('Asia/overseas menu needs no manual RTT; planning values explicitly distinguished from measurements')

# Settings persist within the menu; apply and reapply without leaving it.
output = run('7\n1\nnode@one.service\n2\n65536\n4\nv1\n5\n8\n0\n2\n1\n2\n1\n0\n')
assert 'service=node@one.service' in output and 'buffer ceiling=8MiB' in output, output
assert 'net.core.rmem_max = 8388608' in CONFIG.read_text()
dropin = pathlib.Path('/etc/systemd/system/node@one.service.d/90-singbox-tune.conf')
assert 'LimitNOFILE=65536:65536' in dropin.read_text()
ok('Settings propagate; apply/reapply generates matching service limits and buffers')

output = run('6\nn\n0\n')
assert '已取消回滚' in output and CONFIG.exists(), output
output = run('6\ny\n0\n')
assert_clean()
assert not dropin.exists()
ok('Rollback preview/cancel and confirmed restore')

# Failure in action must not kill the parent menu or be reported as completion.
output = run('2\n0\n', args=('menu',))
assert '操作未完成' in output and '已完成，返回主菜单' not in output, output
assert_clean()
for inputs in ('', '3\n1\n', '2\n'):
    run(inputs)
    assert_clean()
ok('Failed action returns to menu; EOF exits/cancels without applying')
print(f'MENU RESULT: {passed} groups passed; no WAN speed test or reboot')
