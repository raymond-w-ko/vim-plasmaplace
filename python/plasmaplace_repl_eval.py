__doc__ = """
Implements an isolated session that is responsible for sending a form to
evaluate and receiving the value, output, error, exception, and stack trace.
"""

import uuid
import ast
import threading
from queue import Queue
from plasmaplace_io import TO_NREPL, read_nrepl_msg, _debug


class StreamBuffer:
    """
    An utility class used to convert stream data to lines or a string for
    value interpretation
    """
    def __init__(self, header):
        self.header = header
        self.appended_header = False
        self.value = None
        self.buf = []

    def append(self, msg):
        self.buf.append(msg)

    def get_lines(self):
        if len(self.buf) == 0:
            return []
        ret = []
        ret.append(self.header)
        lines = "".join(self.buf).split("\n")
        ret += lines
        return ret

    def get_value(self):
        if self.value:
            return self.value
        ret = "".join(self.buf).strip()

        self.value = ret
        return self.value


def literal_eval(value):
    if value is None or value == "":
        return None
    if value == "nil":
        return None

    return ast.literal_eval(value)


class ReplEval:
    """ The main class used to perform NREPL op 'eval'. """
    root_session = ""
    instances = {}

    @staticmethod
    def dispatch_msg(msg_id, msg):
        if msg_id in ReplEval.instances:
            this = ReplEval.instances[msg_id]
            this.from_repl.put(msg)

    @staticmethod
    def set_root_session(root_session):
        ReplEval.root_session = root_session

    @staticmethod
    def is_done_msg(msg):
        if not isinstance(msg, dict):
            return False
        if "status" not in msg:
            return False
        status = msg["status"]
        if not isinstance(status, list):
            return False
        return status[0] == "done"

    def __init__(self, code, eval_value=False, echo_code=False, silent=False):
        self.id = str(uuid.uuid4())
        self.from_repl = Queue()
        ReplEval.instances[self.id] = self

        self.echo_code = echo_code
        self.eval_value = eval_value
        self.silent = silent
        self.code = code

        self.success = False
        self.ex_happened = False

        self.value_stream = StreamBuffer(";; VALUE:")
        self.out_stream = StreamBuffer(";; OUT:")
        self.err_stream = StreamBuffer(";; ERR:")
        self.ex_stream = StreamBuffer(";; EX:")
        self.st_stream = StreamBuffer(";; STACK TRACE:")
        self.unknown_stream = StreamBuffer(";; UNKNOWN REPL RESPONSE:")

        self.raw_value = None

        self._eval()
        self._fetch_stacktrace()

    def __del__(self):
        del ReplEval.instances[self.id]

    def _eval(self):
        payload = {
            "op": "eval",
            "session": ReplEval.root_session,
            "id": self.id,
            "code": self.code,
        }
        TO_NREPL.put(payload)
        self.success = True
        while True:
            msg = self.from_repl.get()
            if ReplEval.is_done_msg(msg):
                break

            if "out" in msg:
                self.out_stream.append(msg["out"])
            elif "value" in msg:
                self.value_stream.append(msg["value"])
            elif "err" in msg:
                self.err_stream.append(msg["err"])
                self.success = False
            elif "ex" in msg:
                self.success = False
                self.ex_happened = True
                self.ex_stream.append(msg["ex"])
            else:
                # ignore silent due to probably an error or unhandled case
                self.unknown_stream.append(str(msg))

        if self.eval_value:
            value = self.value_stream.get_value()
            value = literal_eval(value)
            self.raw_value = value

    def _fetch_stacktrace(self):
        if not self.ex_happened:
            return

        payload = {
            "op": "eval",
            "session": ReplEval.root_session,
            "id": self.id,
            "code": "*e",
        }
        TO_NREPL.put(payload)
        while True:
            msg = self.from_repl.get()
            if ReplEval.is_done_msg(msg):
                break

            if "value" in msg:
                value = msg["value"]
                self.st_stream.append(value)
            else:
                # ignore silent due to probably an error or unhandled case
                self.unknown_stream.append(str(msg))

    def extract_output(self):
        lines = []
        if self.echo_code:
            lines += self.code.split("\n")
        lines += self.unknown_stream.get_lines()
        if not self.silent:
            lines += self.out_stream.get_lines()
            if self.eval_value and self.raw_value is not None:
                lines += self.raw_value.split("\n")
            else:
                lines += self.value_stream.get_lines()
        lines += self.err_stream.get_lines()
        lines += self.st_stream.get_lines()
        return lines

    def to_scratch_buf(self):
        lines = self.extract_output()
        if not self.silent:
            lines.insert(
                0,
                ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;",
            )
        return {"lines": lines, "ex_happened": self.ex_happened}

    def to_popup(self):
        lines = self.extract_output()
        return {"popup": lines, "ex_happened": self.ex_happened}

    def to_value(self):
        return {"value": self.raw_value, "ex_happened": self.ex_happened}


def _repl_read_dispatch_loop():
    while True:
        msg = read_nrepl_msg()
        if not isinstance(msg, dict):
            continue
        msg_id = msg["id"]
        if msg_id.startswith("keepalive-"):
            continue
        # _debug(msg)
        ReplEval.dispatch_msg(msg_id, msg)


def start_repl_read_dispatch_loop():
    t1 = threading.Thread(target=_repl_read_dispatch_loop, daemon=True)
    t1.daemon = True
    t1.start()
