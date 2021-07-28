#!/usr/bin/env python3
from pprint import pprint  # noqa
import sys
import os
import socket
import json
import select
import threading
import atexit
import time
import queue
import traceback

from plasmaplace_utils import bencode, bdecode, get_shadow_primary_target
from plasmaplace_io import (
    _debug,
    EXIT_SIGNAL_QUEUE,
    TO_NREPL,
    to_vim,
    read_nrepl_msg,
    connect_to_nrepl_socket,
    start_keepalive_loop
)
import plasmaplace_repl_eval
from plasmaplace_repl_eval import ReplEval
import plasmaplace_commands

PROJECT_PATH = None
PROJECT_TYPE = None
TIMEOUT_MS = 4096

EXISTING_SESSIONS = None
ROOT_SESSION = None


def init(port_file_path, project_type, timeout_ms):
    global PROJECT_TYPE
    global TIMEOUT_MS
    PROJECT_TYPE = project_type
    TIMEOUT_MS = int(timeout_ms)
    connect_to_nrepl_socket(port_file_path)


def get_existing_sessions(out):
    global EXISTING_SESSIONS

    cmd = {"op": "ls-sessions"}
    TO_NREPL.put(cmd)
    msg = read_nrepl_msg()
    EXISTING_SESSIONS = msg["sessions"]
    # _debug(EXISTING_SESSIONS)
    out += [";; existing sessions: " + str(EXISTING_SESSIONS)]


def acquire_root_session(out):
    global ROOT_SESSION

    if ROOT_SESSION is not None:
        return
    cmd = {"op": "clone"}
    TO_NREPL.put(cmd)
    msg = read_nrepl_msg()
    ROOT_SESSION = msg["new-session"]
    out += [";; current session: " + ROOT_SESSION]


def setup_repl(out):
    global PROJECT_TYPE
    global PROJECT_PATH
    f = plasmaplace_commands.dispatcher["eval"]

    _debug("setup REPL: " + str(PROJECT_TYPE))
    if PROJECT_TYPE == "shadow-cljs":
        shadow_primary_target = get_shadow_primary_target(PROJECT_PATH)
        if shadow_primary_target:
            code = "(shadow/nrepl-select %s)" % (shadow_primary_target)
            f(None, code)
            out += [";; (shadow/nrepl-select %s)" % (shadow_primary_target,)]
        else:
            out += [";; UNABLE TO SELECT NREPL primary TARGET"]
            out += [";; DEFAULTING to (shadow/node-repl)"]
            code = "(shadow/node-repl)"
            f(None, code)
    else:
        code = "(in-ns user)"
        out += [code]
        f(None, code)


def process_command_from_vim(obj):
    LAST_COMMAND = ""
    LAST_COMMAND_SUCCESSFUL = True

    msg_id, msg = obj
    verb = msg[0]
    args = msg[1:]

    if verb == "init":
        out = [";; connected to nREPL"]
        get_existing_sessions(out)
        acquire_root_session(out)
        ReplEval.set_root_session(ROOT_SESSION)
        plasmaplace_repl_eval.start_repl_read_dispatch_loop()
        setup_repl(out)
        to_vim(msg_id, {"lines": out})
        start_keepalive_loop()
    elif verb == "delete_other_nrepl_sessions":
        for session_id in EXISTING_SESSIONS:
            TO_NREPL.put({"op": "close", "session": session_id})
        to_vim(msg_id, {"lines": []})
    elif verb == "exit":
        return False
    else:
        start_time = time.time()

        f = plasmaplace_commands.dispatcher[verb]
        ret = f(*args)
        if isinstance(ret, dict):
            if (
                LAST_COMMAND == "require"
                and LAST_COMMAND_SUCCESSFUL
                and verb == "require"
                and not ret["ex_happened"]
            ):
                ret["skip_center"] = True
            else:
                ret["skip_center"] = False

            LAST_COMMAND_SUCCESSFUL = not ret["ex_happened"]
        else:
            LAST_COMMAND_SUCCESSFUL = False
        LAST_COMMAND = verb

        end_time = time.time()
        duration = end_time - start_time
        duration = int(duration * 1000)
        do_async = False
        if duration > TIMEOUT_MS:
            do_async = True
        to_vim(msg_id, ret, do_async)
    return True


################################################################################


def main(port_file_path, project_type, timeout_ms):
    global PROJECT_PATH
    if project_type == "shadow-cljs":
        p = os.path.dirname(port_file_path)
        p = os.path.join(p, "..")
        p = os.path.normpath(p)
        _debug(p)
        PROJECT_PATH = p
    else:
        PROJECT_PATH = os.getcwd()
    init(port_file_path, project_type, timeout_ms)

    for line in sys.stdin:
        obj = json.loads(line)
        _debug(obj)
        should_continue = process_command_from_vim(obj)
        if not should_continue:
            break

    TO_NREPL.put({"op": "close", "session": ROOT_SESSION})
    TO_NREPL.put("exit")
    EXIT_SIGNAL_QUEUE.get(block=True)
    EXIT_SIGNAL_QUEUE.get(block=True)
    sys.exit(0)


if __name__ == "__main__":
    _debug("started")
    _debug(sys.argv)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
