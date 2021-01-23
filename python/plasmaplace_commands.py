import sys
import uuid
import time
import threading
import ast
from queue import Queue
from plasmaplace_utils import StreamBuffer
from plasmaplace_io import TO_NREPL, read_nrepl_msg, _debug


ROOT_SESSION = None


def set_globals(root_session):
    global ROOT_SESSION
    ROOT_SESSION = root_session


def _repl_read_dispatch_loop():
    while True:
        msg = read_nrepl_msg()
        if not isinstance(msg, dict):
            continue
        msg_id = msg["id"]
        if msg_id.startswith("keepalive-"):
            continue
        Eval.dispatch_msg(msg_id, msg)


def start_repl_read_dispatch_loop():
    t2 = threading.Thread(target=_repl_read_dispatch_loop, daemon=True)
    t2.daemon = True
    t2.start()


def literal_eval(value):
    if value is None or value == "":
        return None
    if value == "nil":
        return None
    else:
        return ast.literal_eval(value)


class Eval:
    instances = {}

    @staticmethod
    def dispatch_msg(id, msg):
        if id in Eval.instances:
            this = Eval.instances[id]
            this.from_repl.put(msg)

    def __init__(self, code, eval_value=False, echo_code=False, silent=False):
        self.id = str(uuid.uuid4())
        self.from_repl = Queue()
        Eval.instances[self.id] = self

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
        del Eval.instances[self.id]

    def is_done_msg(self, msg):
        if not isinstance(msg, dict):
            return False
        if "status" not in msg:
            return False
        status = msg["status"]
        if not isinstance(status, list):
            return False
        return status[0] == "done"

    def _eval(self):
        payload = {
            "op": "eval",
            "session": ROOT_SESSION,
            "id": self.id,
            "code": self.code,
        }
        TO_NREPL.put(payload)
        self.success = True
        while True:
            msg = self.from_repl.get()
            if self.is_done_msg(msg):
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

        payload = {"op": "eval", "session": ROOT_SESSION, "id": self.id, "code": "*e"}
        TO_NREPL.put(payload)
        while True:
            msg = self.from_repl.get()
            if self.is_done_msg(msg):
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
                ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;"
            )
        return {"lines": lines, "ex_happened": self.ex_happened}

    def to_popup(self):
        lines = self.extract_output()
        return {"popup": lines, "ex_happened": self.ex_happened}

    def to_value(self):
        return {"value": self.raw_value, "ex_happened": self.ex_happened}


def switch_to_ns(ns):
    code = "(in-ns %s)" % ns
    ret = Eval(code)
    return ret


def doc(ns, symbol):
    ret = switch_to_ns(ns)
    if not ret.success:
        return ret.to_popup()

    code = "(with-out-str (clojure.repl/doc %s))" % (symbol,)
    ret = Eval(code, eval_value=True)
    return ret.to_popup()


def _eval(ns, code):
    if ns is not None:
        ret = switch_to_ns(ns)
        if not ret.success:
            return ret.to_scratch_buf()

    ret = Eval(code, echo_code=True)
    return ret.to_popup()


def run_tests(ns, code):
    if ns is not None:
        ret = switch_to_ns(ns)
        if not ret.success:
            return ret.to_scratch_buf()

    ret = Eval(code, echo_code=True, eval_value=True)
    return ret.to_scratch_buf()


def macroexpand(ns, code):
    if ns:
        ret = switch_to_ns(ns)
        if not ret.success:
            return ret.to_scratch_buf()

    code = "(macroexpand (quote\n%s))" % (code,)
    ret = Eval(code, eval_value=False, echo_code=True)
    return ret.to_scratch_buf()


def macroexpand1(ns, code):
    ret = switch_to_ns(ns)
    if not ret.success:
        return ret.to_scratch_buf()

    code = "(macroexpand-1 (quote\n%s))" % (code,)
    ret = Eval(code, eval_value=False, echo_code=True)
    return ret.to_scratch_buf()


def require(ns, reload_level):
    code = "(clojure.core/require %s %s)" % (ns, reload_level)
    ret = Eval(code, eval_value=False, echo_code=True, silent=True)
    return ret.to_scratch_buf()


def cljfmt(code):
    require_cljfmt_code = "(require 'cljfmt.core)"
    ret = Eval(require_cljfmt_code, eval_value=False, echo_code=True, silent=True)
    # if not ret.success:
    #     return ret.to_scratch_buf()

    template = "(with-out-str (print (cljfmt.core/reformat-string %s nil)))"
    code = template % (code,)
    ret = Eval(code, eval_value=True, echo_code=False, silent=True)
    return ret.to_value()


dispatcher = {}
dispatcher["doc"] = doc
dispatcher["eval"] = _eval
dispatcher["run_tests"] = run_tests
dispatcher["macroexpand"] = macroexpand
dispatcher["macroexpand1"] = macroexpand1
dispatcher["require"] = require
dispatcher["cljfmt"] = cljfmt
