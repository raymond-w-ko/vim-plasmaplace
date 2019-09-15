import sys
import uuid
import threading
import ast
from queue import Queue


TO_REPL = None
ROOT_SESSION = None
_read = None


def _debug(obj):
    s = str(obj)
    print(s, file=sys.stderr)
    sys.stderr.flush()


def set_globals(_to_repl, _root_session, __read):
    global TO_REPL
    global ROOT_SESSION
    global _read

    TO_REPL = _to_repl
    ROOT_SESSION = _root_session
    _read = __read


def _repl_read_dispatch_loop():
    try:
        while True:
            msg = _read()
            if not msg:
                sys.exit(1)
            if not isinstance(msg, dict):
                continue
            id = msg["id"]
            Eval.dispatch_msg(id, msg)
    except:  # noqa
        sys.exit(1)


def start_repl_read_dispatch_loop():
    t1 = threading.Thread(target=_repl_read_dispatch_loop, daemon=True)
    t1.daemon = True
    t1.start()


def literal_eval(value):
    if value == "nil":
        return None
    else:
        return ast.literal_eval(value)


class Eval:
    instances = {}

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
        self.err_happened = False

        self.errors = []
        self.out = []
        self.unknown = []
        self.value = []
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
        TO_REPL.put(payload)
        self.success = True
        while True:
            msg = self.from_repl.get()
            # _debug(msg)
            if self.is_done_msg(msg):
                break
            else:
                if "out" in msg:
                    self.out.append(msg["out"])
                elif "value" in msg:
                    value = msg["value"]
                    if self.eval_value:
                        value = literal_eval(value)
                    self.raw_value = value
                    if isinstance(value, str):
                        self.value += value.split("\n")
                elif "err" in msg:
                    self.err_happened = True
                    self.errors = [";; ERR:"]
                    self.errors += msg["err"].split("\n")
                    self.success = False
                elif "ex" in msg:
                    self.ex_happened = True
                    self.errors = [";; EX:"]
                    self.errors += msg["ex"].split("\n")
                    self.success = False
                else:
                    # ignore silent due to probably an error or unhandled case
                    self.unknown += [";; UNKNOWN REPL RESPONSE"]
                    self.unknown += [str(msg)]

    def _fetch_stacktrace(self):
        if not self.ex_happened:
            return

        payload = {"op": "eval", "session": ROOT_SESSION, "id": self.id, "code": "*e"}
        TO_REPL.put(payload)
        while True:
            msg = self.from_repl.get()
            # _debug(msg)
            if self.is_done_msg(msg):
                break
            else:
                if "value" in msg:
                    value = msg["value"]
                    self.errors = [";; STACKTRACE:"]
                    self.errors += value.split("\n")
                else:
                    # ignore silent due to probably an error or unhandled case
                    self.unknown += [";; UNKNOWN REPL RESPONSE"]
                    self.unknown += [str(msg)]

    def to_scratch_buf(self):
        lines = []
        if not self.silent:
            lines += [
                ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;"
            ]
        if self.echo_code:
            lines += self.code.split("\n")
        if not self.silent:
            if len(self.out) > 0:
                lines += [";; OUT"]
                lines += "".join(self.out).split("\n")
            if self.value:
                lines += [";; VALUE"]
                lines += self.value
            lines += self.unknown
        lines += self.errors
        return {"lines": lines, "ex_happened": self.ex_happened}

    def to_value(self):
        # _debug(self.raw_value)
        return {"value": self.raw_value, "ex_happened": self.ex_happened}


def switch_to_ns(ns):
    code = "(in-ns %s)" % ns
    ret = Eval(code)
    return ret


def doc(ns, symbol):
    ret = switch_to_ns(ns)
    if not ret.success:
        return ret.to_scratch_buf()

    code = "(with-out-str (clojure.repl/doc %s))" % (symbol,)
    ret = Eval(code, eval_value=True)
    return ret.to_scratch_buf()


def _eval(ns, code):
    if ns is not None:
        ret = switch_to_ns(ns)
        if not ret.success:
            return ret.to_scratch_buf()

    ret = Eval(code, echo_code=True)
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
    if not ret.success:
        return ret.to_scratch_buf()

    template = "(with-out-str (print (cljfmt.core/reformat-string %s nil)))"
    code = template % (code,)
    ret = Eval(code, eval_value=True, echo_code=False, silent=True)
    return ret.to_value()


dispatcher = {}
dispatcher["doc"] = doc
dispatcher["eval"] = _eval
dispatcher["macroexpand"] = macroexpand
dispatcher["macroexpand1"] = macroexpand1
dispatcher["require"] = require
dispatcher["cljfmt"] = cljfmt
