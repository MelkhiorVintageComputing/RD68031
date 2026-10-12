#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
"""Drive a MAME machine's serial console (M14; doc/oracles.md, "MAME").

    drive.py [--port N] [--timeout S] [--prompt RE] --log FILE
             [--cmd TEXT]... [--cmds FILE] -- MAME [ARGS...]

Listens on 127.0.0.1:PORT, starts MAME (whose ttya must be a null_modem with
`-bitb socket.127.0.0.1:PORT`), and logs every byte the machine sends to FILE.
Each time the console output ends in a prompt, the next --cmd is typed, with a
carriage return. A prompt counts only once a line has ended since the last
command was typed, and only in what follows that line (the command's echo), so
that neither the prompt a command was typed at nor the command itself is taken
for its answer -- the rule of RD68021's sim/tme/drive.sh, made stricter. After the last command's
prompt has come back, or after TIMEOUT wall seconds, or when MAME stops by
itself, MAME is stopped. MAME's own output goes to FILE.mame.

Exit status 0 when every command was typed and its prompt came back.
Wall times (to the first prompt, and in all) are printed on stdout.
"""
import argparse, os, re, select, signal, socket, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument('--port', type=int, default=4321)
ap.add_argument('--timeout', type=float, default=600)
ap.add_argument('--prompt', default=r'> *')
ap.add_argument('--log', required=True)
ap.add_argument('--cmd', action='append', default=[])
ap.add_argument('--cmds', help='a file of commands, one a line; # starts a comment line')
ap.add_argument('mame', nargs=argparse.REMAINDER)
a = ap.parse_args()
if a.mame and a.mame[0] == '--':
    a.mame = a.mame[1:]
if not a.mame:
    sys.exit('drive.py: no MAME command line')
if a.cmds:
    for line in open(a.cmds):
        line = line.rstrip('\n')
        if not line.startswith('#'):
            a.cmd.append(line)
prompt = re.compile((r'(%s)$' % a.prompt).encode())

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', a.port))
srv.listen(1)
mout = open(a.log + '.mame', 'wb')
mame = subprocess.Popen(a.mame, stdin=subprocess.DEVNULL, stdout=mout,
                        stderr=subprocess.STDOUT, start_new_session=True)
t0 = time.time()
out = bytearray()
sent_at = 0          # length of the output when the last command was typed
todo = list(a.cmd)
first_prompt = None
done = False


def prompted():
    new = bytes(out[sent_at:]).replace(b'\0', b'').replace(b'\r', b'')
    if sent_at > 0:
        # The answer starts after the command's echo, which ends the line.
        if b'\n' not in new:
            return False
        new = new[new.index(b'\n') + 1:]
    tail = new[-40:].replace(b'\n', b' ')
    return bool(prompt.search(tail))


def stop():
    # sim/mame/control.lua (MAME's -autoboot_script) leaves cleanly when the
    # file `stop` appears; anything else is killed.
    if mame.poll() is None:
        open('stop', 'w').close()
        try:
            mame.wait(30)
        except subprocess.TimeoutExpired:
            os.killpg(mame.pid, signal.SIGKILL)
            mame.wait()
    try:
        os.remove('stop')
    except FileNotFoundError:
        pass


conn = None
srv.settimeout(1)
with open(a.log, 'wb') as f, open(a.log + '.times', 'w') as tf:
    while time.time() - t0 < a.timeout:
        if conn is None:
            if mame.poll() is not None:
                break
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
        r, _, _ = select.select([conn], [], [], 0.5)
        if r:
            d = conn.recv(4096)
            if not d:
                break
            out += d
            f.write(d)
            f.flush()
            tf.write('%9.2f %r\n' % (time.time() - t0, d))
            tf.flush()
        elif mame.poll() is not None:
            break
        if prompted():
            if first_prompt is None:
                first_prompt = time.time() - t0
            if not todo:
                done = True
                break
            # A short pause, so that the monitor is reading the line before
            # the command arrives.
            time.sleep(0.2)
            sent_at = len(out)
            c = todo.pop(0)
            conn.sendall(c.encode() + b'\r')
            tf.write('%9.2f sent %r\n' % (time.time() - t0, c))
stop()
total = time.time() - t0
print('first prompt: %s s wall; total %.1f s wall; %s' % (
    '%.1f' % first_prompt if first_prompt is not None else 'never', total,
    'all commands answered' if done else '%d command(s) not reached' % (len(todo) + (0 if done else 1))))
sys.exit(0 if done else 1)
