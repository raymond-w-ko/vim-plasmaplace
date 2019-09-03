#!/usr/bin/env python3
from pprint import pprint  # noqa
import sys
import os
import socket
import json
import select
import threading
import atexit
from queue import Queue

from plasmaplace_utils import bencode, bdecode, get_shadow_browser_target
import plasmaplace_commands

PROJECT_PATH = os.getcwd()
PROJECT_TYPE = None
SOCKET = None
SOCKET_FILE = None

TO_REPL = Queue()
TO_VIM = Queue()

EXISTING_SESSIONS = None
ROOT_SESSION = None


###############################################################################

def _debug(obj):
    s = str(obj)
    print(s, file=sys.stderr)
    sys.stderr.flush()


def _write_to_nrepl_loop():
    global TO_REPL
    global SOCKET

    while True:
        payload = TO_REPL.get(block=True)
        # _debug(payload)
        payload = bencode(payload)
        SOCKET.sendall(bytes(payload, "UTF-8"))


def _write_to_vim_loop():
    global TO_VIM

    while True:
        payload = TO_VIM.get(block=True)
        sys.stdout.write(json.dumps(payload))
        sys.stdout.write("\n")
        sys.stdout.flush()


###############################################################################

def _read():
    global SOCKET_FILE
    return bdecode(SOCKET_FILE)


def to_vim(msg_id: int, msg):
    global TO_VIM
    TO_VIM.put([msg_id, msg])


###############################################################################

def init(port_file_path, project_type):
    global PROJECT_TYPE
    global SOCKET
    global SOCKET_FILE

    PROJECT_TYPE = project_type

    with open(port_file_path, "r") as f:
        port = int(f.read().strip())
    SOCKET = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    SOCKET.connect(("localhost", port))
    SOCKET.setblocking(1)
    SOCKET_FILE = SOCKET.makefile(encoding=None, mode="rb")

    t1 = threading.Thread(target=_write_to_nrepl_loop, daemon=True)
    t1.daemon = True
    t1.start()

    t2 = threading.Thread(target=_write_to_vim_loop, daemon=True)
    t2.daemon = True
    t2.start()


def get_existing_sessions(out):
    global EXISTING_SESSIONS

    cmd = {"op": "ls-sessions"}
    TO_REPL.put(cmd)
    msg = _read()
    EXISTING_SESSIONS = msg["sessions"]
    out += [";; existing sessions: " + str(EXISTING_SESSIONS)]


def cleanup_root_session():
    global ROOT_SESSION
    global SOCKET
    payload = {"op": "close", "session": ROOT_SESSION}
    payload = bencode(payload)
    SOCKET.sendall(bytes(payload, "UTF-8"))


def acquire_root_session(out):
    global ROOT_SESSION

    if ROOT_SESSION is not None:
        return
    cmd = {"op": "clone"}
    TO_REPL.put(cmd)
    msg = _read()
    ROOT_SESSION = msg["new-session"]
    atexit.register(cleanup_root_session)
    out += [";; current session: " + ROOT_SESSION]


def switch_to_clojurescript_repl(out):
    global PROJECT_TYPE
    global PROJECT_PATH

    if PROJECT_TYPE == "shadow-cljs":
        shadow_browser_target = get_shadow_browser_target(PROJECT_PATH)
        f = plasmaplace_commands.dispatcher["eval"]
        code = "(shadow/nrepl-select %s)" % (shadow_browser_target)
        f(None, code)
        out += [";; switched to shadow-cljs nREPL"]


def loop():
    global SOCKET_FILE
    input_rlist = [sys.stdin]
    while True:
        rlist, _, _ = select.select(input_rlist, [], [])
        for obj in rlist:
            if obj == sys.stdin:
                line = sys.stdin.readline()
                obj = json.loads(line)
                process_command_from_vim(obj)
            elif obj == SOCKET_FILE:
                pass


def process_command_from_vim(obj):
    msg_id, msg = obj
    verb = msg[0]
    args = msg[1:]

    if verb == "init":
        out = [";; connected to nREPL"]
        get_existing_sessions(out)
        acquire_root_session(out)
        plasmaplace_commands.set_globals(TO_REPL, ROOT_SESSION, _read)
        plasmaplace_commands.start_repl_read_dispatch_loop()
        switch_to_clojurescript_repl(out)
        to_vim(msg_id, {"lines": out})
    elif verb == "delete_other_nrepl_sessions":
        for session_id in EXISTING_SESSIONS:
            TO_REPL.put({"op": "close", "session": session_id})
        to_vim(msg_id, {"lines": []})
    elif verb == "exit":
        sys.exit(0)
    else:
        f = plasmaplace_commands.dispatcher[verb]
        ret = f(*args)
        to_vim(msg_id, ret)


################################################################################


def main(port_file_path, project_type):
    init(port_file_path, project_type)
    try:
        loop()
    except: # noqa
        cleanup_root_session()


if __name__ == "__main__":
    _, port_file_path, project_type = sys.argv
    main(port_file_path, project_type)
