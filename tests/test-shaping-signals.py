import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

target_script = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent.parent / 'vps-tune.sh').resolve()
if not target_script.is_file():
    raise SystemExit(f'Missing script: {target_script}')

with tempfile.TemporaryDirectory() as dirname:
    d = pathlib.Path(dirname)
    fake = d / 'iperf3'
    fake.write_text('#!/bin/bash\necho $$ > "$SIGNAL_TEST_DIR/client.pid"\ntrap "exit 143" TERM\nwhile :; do sleep 30; done\n')
    fake.chmod(0o755)
    runner = d / 'runner.sh'
    runner.write_text('''#!/bin/bash
set -Eeuo pipefail
saved_path=$PATH
source "$SIGNAL_TARGET_SCRIPT"
PATH=$saved_path
trap - EXIT ERR INT TERM HUP
warn() { echo "$*" >&2; }
log() { echo "$*"; }
die() { warn "$*"; exit 1; }
shape_restore_original() { touch "$SIGNAL_TEST_DIR/restored"; }
SHAPE_LOG_DIR=$SIGNAL_TEST_DIR
SHAPE_SAMPLE_COUNT=0
SWEEP_ADDRESS=127.0.0.1
SHAPE_IFACE=test0
SHAPE_RESTORE=1
SHAPE_PERSIST_BACKUP=
SHAPE_BEFORE_SIGNATURE=test
trap 'shape_transaction_finish "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
shape_sample signal unshaped
''')
    env = dict(os.environ, PATH=f'{d}:{os.environ["PATH"]}', SIGNAL_TEST_DIR=str(d), SIGNAL_TARGET_SCRIPT=str(target_script))
    for sig in (signal.SIGTERM, signal.SIGINT):
        for path in (d / 'restored', d / 'client.pid'):
            path.unlink(missing_ok=True)
        p = subprocess.Popen(['bash', str(runner)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 5
        while not (d / 'client.pid').exists() and time.monotonic() < deadline:
            time.sleep(.03)
        assert (d / 'client.pid').exists()
        child_pid = int((d / 'client.pid').read_text())
        started = time.monotonic()
        os.kill(p.pid, sig)
        out, err = p.communicate(timeout=5)
        elapsed = time.monotonic() - started
        assert elapsed < 4, elapsed
        assert (d / 'restored').exists(), (out, err)
        assert not pathlib.Path(f'/proc/{child_pid}').exists(), child_pid
        assert p.returncode == 128 + sig, (p.returncode, err)
        print(f'{sig.name}: exit {p.returncode}, child stopped, queue restoration called, {elapsed:.3f}s')
