"""Real local SOCKS5 forwarding and FD-limit smoke test; not a WAN benchmark."""
import concurrent.futures
import hashlib
import http.server
import json
import os
from pathlib import Path
import resource
import shlex
import socket
import struct
import subprocess
import tempfile
import threading
import time

assert Path('/.dockerenv').exists(), 'Disposable Docker container required'
payload = bytes(range(256)) * 4096  # 1 MiB per request
expected = hashlib.sha256(payload).digest()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def exact(sock, length):
    data = b''
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise RuntimeError('Unexpected EOF')
        data += part
    return data


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.request_queue_size = 128
threading.Thread(target=server.serve_forever, daemon=True).start()
with socket.socket() as free_port:
    free_port.bind(('127.0.0.1', 0))
    proxy_port = free_port.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='singbox-proxy-smoke-') as directory:
    root = Path(directory)
    root.chmod(0o755)
    config = root / 'config.json'
    config.write_text(json.dumps({
        'log': {'level': 'error'},
        'inbounds': [{'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': proxy_port}],
        'outbounds': [{'type': 'direct'}],
    }))
    config.chmod(0o644)
    subprocess.run(['sing-box', 'check', '-c', str(config)], check=True)
    old_soft, old_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (1024, old_hard))
    with (root / 'proxy.log').open('w+') as logfile:
        proxy = subprocess.Popen(
            ['su', '-s', '/bin/sh', 'nobody', '-c',
             'exec sing-box run -c ' + shlex.quote(str(config))],
            stdout=logfile, stderr=logfile,
        )
        try:
            for _ in range(100):
                assert proxy.poll() is None, 'sing-box exited at startup'
                try:
                    with socket.create_connection(('127.0.0.1', proxy_port), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise RuntimeError('sing-box listener not ready')

            real_pid = None
            for proc in Path('/proc').glob('[0-9]*'):
                try:
                    cmd = (proc / 'cmdline').read_bytes()
                    comm = (proc / 'comm').read_text().strip()
                    if comm == 'sing-box' and str(config).encode() in cmd:
                        real_pid = int(proc.name)
                        break
                except (OSError, ProcessLookupError):
                    pass
            assert real_pid, 'Could not inspect real sing-box process'
            fd_line = next(line for line in Path(f'/proc/{real_pid}/limits').read_text().splitlines()
                           if line.startswith('Max open files'))
            assert fd_line.split()[3:5] == ['1048576', '1048576'], fd_line
            print('PASS real sing-box PAM process:', fd_line, flush=True)

            def request(_index):
                with socket.create_connection(('127.0.0.1', proxy_port), timeout=15) as sock:
                    sock.sendall(b'\x05\x01\x00')
                    assert exact(sock, 2) == b'\x05\x00'
                    sock.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1')
                                 + struct.pack('!H', server.server_port))
                    head = exact(sock, 4)
                    assert head[:3] == b'\x05\x00\x00', head
                    if head[3] == 1:
                        exact(sock, 4)
                    elif head[3] == 4:
                        exact(sock, 16)
                    elif head[3] == 3:
                        exact(sock, exact(sock, 1)[0])
                    else:
                        raise RuntimeError('Unexpected SOCKS address type')
                    exact(sock, 2)
                    sock.sendall(b'GET /data HTTP/1.0\r\nHost: localhost\r\n\r\n')
                    pieces = []
                    while True:
                        block = sock.recv(65536)
                        if not block:
                            break
                        pieces.append(block)
                header, body = b''.join(pieces).split(b'\r\n\r\n', 1)
                assert b' 200 ' in header.split(b'\r\n')[0]
                assert len(body) == len(payload) and hashlib.sha256(body).digest() == expected
                return len(body)

            start = time.monotonic()
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
                total = sum(pool.map(request, range(64)))
            elapsed = time.monotonic() - start
            print(f'PASS SOCKS5: 64/64 requests, concurrency=16, bytes={total}, '
                  f'SHA256 matched, elapsed={elapsed:.3f}s', flush=True)
            print('Loopback functionality only; no claim of XanMod boot or throughput gain.', flush=True)
        finally:
            resource.setrlimit(resource.RLIMIT_NOFILE, (old_soft, old_hard))
            proxy.terminate()
            try:
                proxy.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proxy.kill()
                proxy.wait()
            server.shutdown()
            logfile.seek(0)
            logs = logfile.read()
            if logs:
                print(logs[-3000:])
