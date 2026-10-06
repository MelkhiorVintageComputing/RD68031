#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
#   serlisten.py PORT LOGFILE SECONDS [TEXT-TO-TYPE DELAY]
# Accept one TCP connection from MAME's null_modem bitbanger and log bytes to a file.
# Optional: send a string after a delay (argv[4], argv[5] seconds).
import socket, sys, time, select
port = int(sys.argv[1]); out = sys.argv[2]; dur = float(sys.argv[3])
send = sys.argv[4].encode().decode('unicode_escape').encode() if len(sys.argv) > 4 else None
when = float(sys.argv[5]) if len(sys.argv) > 5 else 0
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', port)); s.listen(1)
s.settimeout(60)
c, _ = s.accept()
t0 = time.time(); sent = False
with open(out, 'wb') as f:
    while time.time() - t0 < dur:
        r, _, _ = select.select([c], [], [], 0.5)
        if r:
            d = c.recv(4096)
            if not d: break
            f.write(d); f.flush()
        if send and not sent and time.time() - t0 > when:
            for ch in send:
                c.send(bytes([ch])); time.sleep(0.05)
            sent = True
