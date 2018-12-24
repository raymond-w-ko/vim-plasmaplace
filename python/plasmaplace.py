#!/usr/bin/env python3
import vim  # noqa
import re
import os
import sys
import socket
import select
import threading

if sys.version_info[0] >= 3:
    from queue import Queue
else:
    from Queue import Queue


REPLS = {}


def get_current_buf_path():
    vim.command('let current_buf_path = expand("%:p:h")')
    return vim.eval("current_buf_path")


def get_current_bufnr():
    vim.command('let current_bufnr = bufnr("%")')
    return vim.eval("current_bufnr")


###############################################################################


def vim_encode(data):
    if isinstance(data, list):
        return "[" + ",".join([vim_encode(x) for x in data]) + "]"
    elif isinstance(data, dict):
        return (
            "{"
            + ",".join([vim_encode(x) + ":" + vim_encode(y) for x, y in data.items()])
            + "}"
        )
    elif isinstance(data, str):
        str_list = []
        for c in data:
            if (0 <= ord(c) and ord(c) <= 31) or c == '"' or c == "\\":
                str_list.append("\\%03o" % ord(c))
            else:
                str_list.append(c)
        return '"' + "".join(str_list) + '"'
    elif isinstance(data, int):
        return str(data)
    else:
        raise TypeError("can't encode a " + type(data).__name__)


def bencode(value):
    if isinstance(value, int):
        return "i" + value + "e"
    elif isinstance(value, str):
        return str(len(value)) + ":" + value
    elif isinstance(value, list):
        return "l" + "".join(map(bencode, value)) + "e"
    elif isinstance(value, dict):
        enc = ["d"]
        keys = list(value.keys())
        keys.sort()
        for k in keys:
            enc.append(bencode(k))
            enc.append(bencode(value[k]))
        enc.append("e")
        return "".join(enc)
    else:
        raise TypeError("can't bencode " + value)


def bdecode(f, char=None):
    if char is None:
        char = f.read(1)
    if char == "l":
        _list = []
        while True:
            char = f.read(1)
            if char == "e":
                return _list
            _list.append(bdecode(f, char))
    elif char == "d":
        d = {}
        while True:
            char = f.read(1)
            if char == "e":
                return d
            key = bdecode(f, char)
            d[key] = bdecode(f)
    elif char == "i":
        i = ""
        while True:
            char = f.read(1)
            if char == "e":
                return int(i)
            i += char
    elif char.isdigit():
        i = int(char)
        while True:
            char = f.read(1)
            if char == ":":
                return f.read(i)
            i = 10 * i + int(char)
    elif char == "":
        raise EOFError("unexpected end of bencode data")
    else:
        raise TypeError("unexpected type " + char + "in bencode data")


class REPL:
    def __init__(self, project_key, project_path, host, port):
        self.project_key = project_key
        self.project_path = project_path
        self.host = host
        self.port = int(port)

        cmd = 'let scratch_buf = s:create_or_get_scratch("%s")' % project_key
        vim.command(cmd)
        self.scratch_buf = int(vim.eval("scratch_buf"))

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect((self.host, self.port))
        s.setblocking(1)
        self.socket = s

        self.input_queue = Queue()
        self.output_queue = Queue()
        t1 = threading.Thread(target=self._produce)
        t2 = threading.Thread(target=self._consume)
        t1.daemon = True
        t1.start()
        t2.daemon = True
        t2.start()

        self._write({"op": "ls-sessions", "id": "foo"})
        msg = self._read()
        self.session = msg["sessions"][0]

        self.to_scratch(["connected to session: ", self.session])

    # TODO
    def is_closed():
        return False

    def close(self):
        return self.socket.close()

    def poll(self):
        pass

    def _produce(self):
        while True:
            payload = self.input_queue.get(block=True)
            if sys.version_info[0] >= 3:
                self.socket.sendall(bytes(payload, "UTF-8"))
            else:
                self.socket.sendall(payload)

    def _consume(self):
        while True:
            f = self.socket.makefile()
            while len(select.select([f], [], [], 0.1)[0]) == 0:
                self.poll()
            try:
                ret = bdecode(f)
                self.output_queue.put(ret, block=True)
            finally:
                f.close()

    def _write(self, cmd):
        cmd = bencode(cmd)
        self.input_queue.put(cmd, block=True)

    def _read(self, block=True):
        ret = self.output_queue.get(block=block, timeout=1)
        return ret

    def eval(self, id, code):
        payload = {"op": "eval", "session": self.session, "id": id, "code": code}
        self._write(payload)

    def to_scratch(self, lines):
        scratch_buf = self.scratch_buf
        b = vim.buffers[scratch_buf]
        top_line_num = len(b) + 1
        b.append(lines)
        vim.command(
            "call plasmaplace#center_scratch_buf(%d, %d)" % (scratch_buf, top_line_num)
        )


###############################################################################


def get_project_type(path):
    if os.path.exists(os.path.join(path, "project.clj")):
        return "default"
    if os.path.exists(os.path.join(path, "shadow-cljs.edn")):
        return "shadow-cljs"
    if os.path.exists(os.path.join(path, "deps.edn")):
        return "default"
    return None


def get_project_path():
    path = get_current_buf_path()
    prev_path = path
    while True:
        project_type = get_project_type(path)
        if project_type is not None:
            break
        prev_path = path
        path = os.path.dirname(path)
        if path == prev_path:
            raise Exception("plasmaplace: could not determine project directory")
    return path


def get_project_key():
    project_path = get_project_path()
    tokens = re.split(r"\\|\/", project_path)
    tokens = filter(lambda x: len(x) > 0, tokens)
    tokens = list(tokens)
    tokens.reverse()
    return "_".join(tokens)


def get_nrepl_port(project_path):
    path = os.path.join(project_path, ".nrepl-port")
    print(path)
    if os.path.exists(path):
        with open(path, "r") as f:
            return f.read().strip()
    raise Exception("plasmaplace: could not determine nREPL port number")


def create_or_get_repl():
    global REPLS
    project_key = get_project_key()
    project_path = get_project_path()
    if project_key not in REPLS:
        REPLS[project_key] = REPL(
            project_key, project_path, "localhost", get_nrepl_port(project_path)
        )


if __name__ == "__main__":
    pass
