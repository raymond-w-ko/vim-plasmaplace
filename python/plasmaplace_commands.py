import sys
import uuid
import time
import ast
from queue import Queue
from plasmaplace_io import TO_NREPL, read_nrepl_msg, _debug
from plasmaplace_repl_eval import ReplEval


def switch_to_ns(ns):
    code = "(in-ns %s)" % ns
    ret = ReplEval(code)
    return ret


def doc(ns, symbol):
    ret = switch_to_ns(ns)
    if not ret.success:
        return ret.to_popup()

    code = "(with-out-str (clojure.repl/doc %s))" % (symbol,)
    ret = ReplEval(code, eval_value=True)
    return ret.to_popup()


def _eval(ns, code):
    if ns is not None:
        ret = switch_to_ns(ns)
        if not ret.success:
            return ret.to_scratch_buf()

    ret = ReplEval(code, echo_code=True)
    return ret.to_popup()


def run_tests(ns, code):
    if ns is not None:
        ret = switch_to_ns(ns)
        if not ret.success:
            return ret.to_scratch_buf()

    ret = ReplEval(code, echo_code=True, eval_value=True)
    return ret.to_scratch_buf()


def macroexpand(ns, code):
    if ns:
        ret = switch_to_ns(ns)
        if not ret.success:
            return ret.to_scratch_buf()

    code = "(macroexpand (quote\n%s))" % (code,)
    ret = ReplEval(code, eval_value=False, echo_code=True)
    return ret.to_scratch_buf()


def macroexpand1(ns, code):
    ret = switch_to_ns(ns)
    if not ret.success:
        return ret.to_scratch_buf()

    code = "(macroexpand-1 (quote\n%s))" % (code,)
    ret = ReplEval(code, eval_value=False, echo_code=True)
    return ret.to_scratch_buf()


def require(ns, reload_level):
    code = "(clojure.core/require %s %s)" % (ns, reload_level)
    ret = ReplEval(code, eval_value=False, echo_code=True, silent=True)
    return ret.to_scratch_buf()


def cljfmt(code):
    require_cljfmt_code = "(require 'cljfmt.core)"
    ret = ReplEval(require_cljfmt_code, eval_value=False, echo_code=True, silent=True)
    # if not ret.success:
    #     return ret.to_scratch_buf()

    template = "(with-out-str (print (cljfmt.core/reformat-string %s nil)))"
    code = template % (code,)
    ret = ReplEval(code, eval_value=True, echo_code=False, silent=True)
    return ret.to_value()


dispatcher = {}
dispatcher["doc"] = doc
dispatcher["eval"] = _eval
dispatcher["run_tests"] = run_tests
dispatcher["macroexpand"] = macroexpand
dispatcher["macroexpand1"] = macroexpand1
dispatcher["require"] = require
dispatcher["cljfmt"] = cljfmt
