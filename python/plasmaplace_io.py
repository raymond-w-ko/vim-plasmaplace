"""
All sockets, input/output queues, loops go here
"""
import sys
import json
import threading
import socket
import uuid
import time
from queue import Queue
from plasmaplace_utils import bencode, bdecode

SOCKET = None
TO_NREPL = Queue()
TO_VIM_QUEUE = Queue()


def _debug(obj):
    print(str(obj), file=sys.stderr)
    sys.stderr.flush()


################################################################################


def _write_to_nrepl_loop():
    try:
        while True:
            payload = TO_NREPL.get(block=True)
            # _debug(payload)
            payload = bencode(payload)
            SOCKET.sendall(bytes(payload, "UTF-8"))
    except:
        return


################################################################################


def _write_to_vim_loop():
    while True:
        payload = TO_VIM_QUEUE.get(block=True)
        sys.stdout.write(json.dumps(payload))
        sys.stdout.write("\n")
        sys.stdout.flush()


def to_vim(msg_id: int, msg, do_async=False):
    if do_async:
        msg_id = 0
        msg["async"] = True
    TO_VIM_QUEUE.put([msg_id, msg])


################################################################################


def _keepalive_loop():
    while True:
        payload = {
            "op": "ls-sessions",
            "id": "keepalive-" + str(uuid.uuid4()),
        }
        TO_NREPL.put(payload)
        time.sleep(1)


def start_io_loops():
    t1 = threading.Thread(target=_write_to_nrepl_loop, daemon=True)
    t1.daemon = True
    t1.start()

    t2 = threading.Thread(target=_write_to_vim_loop, daemon=True)
    t2.daemon = True
    t2.start()


def connect_to_nrepl_socket(port_file_path: str):
    global SOCKET
    with open(port_file_path, "r") as f:
        port = int(f.read().strip())
    SOCKET = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    SOCKET.connect(("localhost", port))
    SOCKET.setblocking(1)

    start_io_loops()


def start_keepalive_loop():
    t1 = threading.Thread(target=_keepalive_loop, daemon=True)
    t1.daemon = True
    t1.start()


################################################################################


def read_nrepl_msg():
    return bdecode(SOCKET)
