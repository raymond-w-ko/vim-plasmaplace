#!/usr/bin/env python3
try:
    import vim  # noqa
except:  # noqa
    pass
from pprint import pprint # noqa
import re
import os
import sys
import socket
import ast

# import select
import threading

if sys.version_info[0] >= 3:
    from queue import Queue, Empty
else:
    from Queue import Queue, Empty


class FatalError:
    def __init__(self):
        pass


class Exiting:
    def __init__(self):
        pass


FATAL_ERROR = FatalError()
EXITING = Exiting()
REPLS = {}


def spawn_thread(f):
    t = threading.Thread(target=f)
    t.daemon = True
    t.start()


###############################################################################


def get_current_buf_path():
    vim.command('let current_buf_path = expand("%:p:h")')
    return vim.eval("current_buf_path")


def get_current_bufnr():
    vim.command('let current_bufnr = bufnr("%")')
    return vim.eval("current_bufnr")


###############################################################################


# def vim_encode(data):
#     if isinstance(data, list):
#         return "[" + ",".join([vim_encode(x) for x in data]) + "]"
#     elif isinstance(data, dict):
#         return (
#             "{"
#             + ",".join([vim_encode(x) + ":" + vim_encode(y) for x, y in data.items()])
#             + "}"
#         )
#     elif isinstance(data, str):
#         str_list = []
#         for c in data:
#             if (0 <= ord(c) and ord(c) <= 31) or c == '"' or c == "\\":
#                 str_list.append("\\%03o" % ord(c))
#             else:
#                 str_list.append(c)
#         return '"' + "".join(str_list) + '"'
#     elif isinstance(data, int):
#         return str(data)
#     else:
#         raise TypeError("can't encode a " + type(data).__name__)


def bencode(value):
    if isinstance(value, int):
        return "i" + value + "e"
    elif isinstance(value, str):
        return str(len(value.encode("utf-8"))) + ":" + value
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
    if char == b"l":
        _list = []
        while True:
            char = f.read(1)
            if char == b"e":
                return _list
            _list.append(bdecode(f, char))
    elif char == b"d":
        d = {}
        while True:
            char = f.read(1)
            if char == b"e":
                return d
            key = bdecode(f, char)
            d[key] = bdecode(f)
    elif char == b"i":
        i = b""
        while True:
            char = f.read(1)
            if char == b"e":
                return int(i.decode("utf-8"))
            i += char
    elif char.isdigit():
        i = int(char)
        while True:
            char = f.read(1)
            if char == b":":
                return f.read(i).decode("utf-8")
            i = 10 * i + int(char)
    elif char == "":
        raise EOFError("unexpected end of bdecode data")
    else:
        raise TypeError("unexpected type " + char + "in bdecode data")


def get_shadow_browser_target(project_path):
    path = os.path.join(project_path, "shadow-cljs.edn")
    with open(path, "r") as f:
        code = f.read()
    code = code.replace("\n", " ")
    idx = code.index(":builds")
    code = code[idx:]
    m = re.search(r"\s*(\:\w+)\s*\{\:target\s+\:browser.*", code)
    return m.group(1)


class REPL:
    def __init__(self, project_key, project_path, host, port):
        self.project_key = project_key
        self.project_path = project_path
        self.project_type = get_project_type(self.project_path)
        self.host = host
        self.port = int(port)

        self.pending_lines = Queue()
        self.jobs = {}

        cmd = 'let scratch_buf = s:create_or_get_scratch("%s")' % project_key
        vim.command(cmd)
        self.scratch_buf = int(vim.eval("scratch_buf"))

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect((self.host, self.port))
        s.setblocking(1)
        self.socket = s
        self.socket_file = self.socket.makefile(encoding=None, mode="rb")
        self.closed = False

        self.input_queue = Queue()
        self.output_queue = Queue()
        t1 = threading.Thread(target=self._produce_to_remote, daemon=True)
        t2 = threading.Thread(target=self._consume_from_remote, daemon=True)
        t1.daemon = True
        t1.start()
        t2.daemon = True
        t2.start()

        self._write({"op": "ls-sessions"})
        sessions = self._read()
        self.existing_sessions = sessions["sessions"]

        self.root_session = None
        self.root_session = self.acquire_session()

        if self.project_type == "shadow-cljs":
            shadow_browser_target = get_shadow_browser_target(project_path)
            self.eval(
                "switch-to-cljs-repl",
                self.root_session,
                "(shadow/nrepl-select %s)" % (shadow_browser_target),
            )

        startup_lines = ["connected to nREPL"]
        startup_lines += ["host: " + self.host]
        startup_lines += ["port: " + str(self.port)]
        startup_lines += ["existing sessions: " + str(self.existing_sessions)]
        startup_lines += ["current session: " + self.root_session]
        self.to_scratch(startup_lines)

        # NOTE: does not trigger!
        # atexit.register(self.close_session, self.root_session)

    def is_closed(self):
        return self.closed

    def close(self):
        if not self.closed:
            self.closed = True
            self.socket.close()
            # XXX: DO NOT DO THIS, THIS BLOCKS EXIT!!!
            # self.socket_file.close()
            self.socket_file = None
            self.socket = None

            self.input_queue.put(EXITING)
        else:
            return None

    def poll(self):
        pass

    def _produce_to_remote(self):
        # we are inside a new thread here
        while True:
            try:
                payload = self.input_queue.get(block=True, timeout=1.0)
                if payload == EXITING:
                    return
                if sys.version_info[0] >= 3:
                    self.socket.sendall(bytes(payload, "UTF-8"))
                else:
                    self.socket.sendall(payload)
            except Empty:
                if self.closed or self.socket is None:
                    self.input_queue = None
                    return
            except:  # noqa
                self.close()
                return

    def _consume_from_remote(self):
        # we are inside a new thread here
        while True:
            try:
                ret = bdecode(self.socket_file)
            except EOFError:
                self.close()
                self.output_queue.put(FATAL_ERROR, block=True)
                for _, job in self.jobs.items():
                    job.input_queue.put(FATAL_ERROR, block=True)
                return
            except TypeError:
                self.close()
                self.output_queue.put(FATAL_ERROR, block=True)
                for _, job in self.jobs.items():
                    job.input_queue.put(FATAL_ERROR, block=True)
                return

            if isinstance(ret, dict) and "id" in ret:
                id = ret["id"]
                if id in self.jobs:
                    job = self.jobs[id]
                    job.input_queue.put(ret, block=True)
            else:
                self.output_queue.put(ret, block=True)

    def _write(self, cmd):
        cmd = bencode(cmd)
        self.input_queue.put(cmd, block=True)

    def _read(self, block=True):
        ret = self.output_queue.get(block=block, timeout=1.0)
        if ret == FATAL_ERROR:
            raise RuntimeError("An error occurred while reading from the REPL")
        return ret

    def eval(self, id, session, code):
        payload = {"op": "eval", "session": session, "id": id, "code": code}
        self._write(payload)

    def to_scratch(self, lines):
        scratch_buf = self.scratch_buf
        b = vim.buffers[scratch_buf]
        top_line_num = len(b) + 1
        b.append(lines)
        vim.command(
            "call plasmaplace#center_scratch_buf(%d, %d)" % (scratch_buf, top_line_num)
        )

    def acquire_session(self):
        cmd = {"op": "clone"}
        if self.root_session is not None:
            cmd["session"] = self.root_session
        self._write(cmd)
        msg = self._read()
        return msg["new-session"]

    def close_session(self, session, exiting=False):
        if session == self.root_session and not exiting:
            return
        self._write({"op": "close", "session": session})
        msg = self._read()
        assert (
            "status" in msg
            and msg["status"][0] == "done"
            and msg["status"][1] == "session-closed"
        )

    def register_job(self, job):
        id = job.id
        self.jobs[id] = job

    def unregister_job(self, job):
        id = job.id
        del self.jobs[id]

    def append_to_scratch(self, lines):
        self.pending_lines.put(lines)

    def wait_for_scratch_update(self, timeout=5.0):
        try:
            lines = self.pending_lines.get(block=True, timeout=timeout)
            self.to_scratch(lines)
        except Empty:
            if timeout > 0.0:
                print("plasmaplace timed out while waiting for scratch update")

    def delete_other_nrepl_sessions(self):
        for session in self.existing_sessions:
            self.close_session(session)


JOB_COUNTER = 0


def fetch_job_number():
    global JOB_COUNTER
    n = JOB_COUNTER
    JOB_COUNTER += 1
    return str(n)


def extract_out_msg(msg):
    return msg["out"]


def out_to_lines(out):
    lines = [";; OUT:"]
    lines += out.split("\n")
    return lines


def ex_msg_to_lines(msg):
    lines = [";; EX:"]
    lines += msg["ex"].split("\n")
    return lines


def err_msg_to_lines(msg):
    lines = [";; ERR:"]
    lines += msg["err"].split("\n")
    return lines


def value_msg_to_lines(msg, eval_value):
    lines = [";; VALUE:"]
    value = msg["value"]
    if eval_value and value == "nil":
        return None
    else:
        if eval_value:
            value = ast.literal_eval(value)
        lines += value.split("\n")
        return lines, value


def is_done_msg(msg):
    if not isinstance(msg, dict):
        return False
    if "status" not in msg:
        return False
    status = msg["status"]
    if not isinstance(status, list):
        return False
    return status[0] == "done"


class BaseJob(threading.Thread):
    def __init__(self, repl):
        threading.Thread.__init__(self)

        self.repl = repl

        self.input_queue = Queue()
        self.wait_queue = Queue()

        self.init_output()

    def init_output(self):
        self.out = []
        self.lines = []

    def wait_for_output(self, silent=False, eval_value=False, debug=False):
        self.raw_value = None
        self.ex_happened = False
        self.err_happened = False

        while True:
            msg = self.input_queue.get(block=True)
            if debug:
                print(msg)
            if is_done_msg(msg):
                out = "".join(self.out)
                if not silent:
                    self.lines += out_to_lines(out)
                self.out_str = out
                break
            else:
                if msg == FATAL_ERROR:
                    self.lines += ["FATAL ERROR!"]
                    break
                elif "out" in msg:
                    self.out.append(extract_out_msg(msg))
                elif "ex" in msg:
                    self.ex_happened = True
                    lines = ex_msg_to_lines(msg)
                    if not silent:
                        self.lines += lines
                elif "err" in msg:
                    self.err_happened = True
                    lines = err_msg_to_lines(msg)
                    if not silent:
                        self.lines += lines
                elif "value" in msg:
                    lines, raw_value = value_msg_to_lines(msg, eval_value)
                    if not silent:
                        self.lines += lines
                    self.raw_value = raw_value
                else:
                    # ignore silent due to probably an error or unhandled case
                    self.lines += [str(msg)]

    def wait(self):
        ret = self.wait_queue.get(block=True)
        self.repl.wait_for_scratch_update()
        return ret


class DocJob(BaseJob):
    def __init__(self, repl, ns, symbol):
        BaseJob.__init__(self, repl)
        self.daemon = True

        self.ns = ns
        self.symbol = symbol
        self.id = "doc-job-" + fetch_job_number()
        self.session = self.repl.acquire_session()

        self.repl.register_job(self)

    def run(self):
        code = "(in-ns %s)" % (self.ns)
        self.lines += [code]
        self.repl.eval(self.id, self.session, code)
        self.wait_for_output(silent=True)

        code = "(with-out-str (clojure.repl/doc %s))" % (self.symbol)
        self.lines += [code]
        self.repl.eval(self.id, self.session, code)
        self.wait_for_output(eval_value=True)

        self.repl.append_to_scratch(self.lines)
        self.repl.close_session(self.session)
        self.repl.unregister_job(self)
        self.wait_queue.put("done")


class MacroexpandJob(BaseJob):
    def __init__(self, repl, ns, form):
        BaseJob.__init__(self, repl)
        self.daemon = True

        self.repl = repl
        self.ns = ns
        self.form = form
        self.id = "macroexpand-job-" + fetch_job_number()
        self.session = self.repl.acquire_session()

        self.repl.register_job(self)

    def run(self):
        code = "(in-ns %s)" % (self.ns)
        self.lines += [code]
        self.repl.eval(self.id, self.session, code)
        self.wait_for_output(silent=True)

        code = "(macroexpand (quote\n%s))" % (self.form)
        self.repl.eval(self.id, self.session, code)
        code = code.split("\n")
        self.lines += code
        self.wait_for_output(eval_value=False, debug=False)

        self.repl.append_to_scratch(self.lines)
        self.repl.close_session(self.session)
        self.repl.unregister_job(self)
        self.wait_queue.put("done")


class Macroexpand1Job(BaseJob):
    def __init__(self, repl, ns, form):
        BaseJob.__init__(self, repl)
        self.daemon = True

        self.repl = repl
        self.ns = ns
        self.form = form
        self.id = "macroexpand-1-job-" + fetch_job_number()
        self.session = self.repl.acquire_session()

        self.repl.register_job(self)

    def run(self):
        code = "(in-ns %s)" % (self.ns)
        self.lines += [code]
        self.repl.eval(self.id, self.session, code)
        self.wait_for_output(silent=True)

        code = "(macroexpand-1 (quote\n%s))" % (self.form)
        self.repl.eval(self.id, self.session, code)
        code = code.split("\n")
        self.lines += code
        self.wait_for_output(eval_value=False, debug=False)

        self.repl.append_to_scratch(self.lines)
        self.repl.close_session(self.session)
        self.repl.unregister_job(self)
        self.wait_queue.put("done")


class EvalJob(BaseJob):
    def __init__(self, repl, ns, form):
        BaseJob.__init__(self, repl)
        self.daemon = True

        self.repl = repl
        self.ns = ns
        self.form = form
        self.id = "eval-job-" + fetch_job_number()
        self.session = self.repl.acquire_session()

        self.repl.register_job(self)

    def run(self):
        code = "(in-ns %s)" % (self.ns)
        self.lines += [code]
        self.repl.eval(self.id, self.session, code)
        self.wait_for_output(silent=True)

        code = "%s" % (self.form)
        self.repl.eval(self.id, self.session, code)
        code = code.split("\n")
        self.lines += [";; CODE:"]
        self.lines += code
        self.wait_for_output(eval_value=False, debug=False)

        self.repl.append_to_scratch(self.lines)
        self.repl.close_session(self.session)
        self.repl.unregister_job(self)
        self.wait_queue.put("done")


class RequireJob(BaseJob):
    def __init__(self, repl, ns, reload_level):
        BaseJob.__init__(self, repl)
        self.daemon = True

        self.repl = repl
        self.ns = ns
        self.reload_level = reload_level
        self.id = "require-job-" + fetch_job_number()
        self.session = self.repl.acquire_session()

        self.repl.register_job(self)

    def run(self):
        code = "(clojure.core/require %s %s)" % (self.ns, self.reload_level)
        self.repl.eval(self.id, self.session, code)
        code = code.split("\n")
        self.lines += [";; CODE:"]
        self.lines += code
        self.wait_for_output(eval_value=False, debug=False)

        self.repl.append_to_scratch(self.lines)
        self.repl.close_session(self.session)
        self.repl.unregister_job(self)
        self.wait_queue.put("done")


class RunTestsJob(BaseJob):
    def __init__(self, repl, form):
        BaseJob.__init__(self, repl)
        self.daemon = True

        self.repl = repl
        self.form = form
        self.id = "run-tests-job-" + fetch_job_number()
        self.session = self.repl.acquire_session()

        self.repl.register_job(self)

    def run(self):
        code = "(with-out-str %s)" % (self.form)
        self.repl.eval(self.id, self.session, code)
        code = code.split("\n")
        self.lines += [";; CODE:"]
        self.lines += code
        self.wait_for_output(eval_value=True, debug=False)

        self.repl.append_to_scratch(self.lines)
        self.repl.close_session(self.session)
        self.repl.unregister_job(self)
        self.wait_queue.put("done")


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
    if os.path.exists(path):
        with open(path, "r") as f:
            return f.read().strip()
    raise Exception("plasmaplace: could not determine nREPL port number")


def create_or_get_repl():
    global REPLS
    project_key = get_project_key()
    project_path = get_project_path()
    if project_key in REPLS:
        if REPLS[project_key].closed:
            del REPLS[project_key]
    if project_key not in REPLS:
        REPLS[project_key] = REPL(
            project_key, project_path, "localhost", get_nrepl_port(project_path)
        )
    return REPLS[project_key]


def Doc(ns, symbol):
    repl = create_or_get_repl()
    job = DocJob(repl, ns, symbol)
    job.start()
    job.wait()


def Macroexpand(ns, form):
    repl = create_or_get_repl()
    job = MacroexpandJob(repl, ns, form)
    job.start()
    job.wait()


def Macroexpand1(ns, form):
    repl = create_or_get_repl()
    job = Macroexpand1Job(repl, ns, form)
    job.start()
    job.wait()


def Eval(ns, form):
    repl = create_or_get_repl()
    job = EvalJob(repl, ns, form)
    job.start()
    job.wait()


def Require(ns, reload_level):
    repl = create_or_get_repl()
    job = RequireJob(repl, ns, reload_level)
    job.start()
    job.wait()


def RunTests(form):
    repl = create_or_get_repl()
    job = RunTestsJob(repl, form)
    job.start()
    job.wait()


def DeleteOtherNreplSessions():
    repl = create_or_get_repl()
    repl.delete_other_nrepl_sessions()


_ready = False


def VimEnter():
    global _ready
    _ready = True


def FlushScratchBuffer():
    global _ready
    global REPLS
    if not _ready:
        return
    try:
        project_key = get_project_key()
    except:  # noqa
        return
    if project_key not in REPLS:
        return
    repl = create_or_get_repl()
    repl.wait_for_scratch_update(0.0)


def cleanup_active_sessions():
    global REPLS
    for project_key, repl in REPLS.items():
        repl.close_session(repl.root_session, True)
        repl.close()
    REPLS.clear()


###############################################################################


class CljfmtJob(BaseJob):
    def __init__(self, repl, code):
        BaseJob.__init__(self, repl)
        self.daemon = True

        self.repl = repl
        self.code = code
        self.id = "cljfmt-job-" + fetch_job_number()
        self.session = self.repl.acquire_session()

        self.repl.register_job(self)

    def run(self):
        code = "(require 'cljfmt.core)"
        self.repl.eval(self.id, self.session, code)
        self.lines += [";; CODE:"]
        self.lines += [code]
        self.wait_for_output(eval_value=False, debug=False, silent=True)

        template = "(with-out-str (print (cljfmt.core/reformat-string %s nil)))"
        code = template % self.code
        self.repl.eval(self.id, self.session, code)
        self.lines += [";; CODE:"]
        self.lines += [template % '"<buffer contents>"']
        self.wait_for_output(eval_value=True, debug=False, silent=False)

        self.repl.append_to_scratch(self.lines)
        self.repl.close_session(self.session)
        self.repl.unregister_job(self)
        if self.ex_happened or self.err_happened:
            self.wait_queue.put(None)
        else:
            self.wait_queue.put(self.raw_value)


def Cljfmt(code):
    repl = create_or_get_repl()
    job = CljfmtJob(repl, code)
    job.start()
    formatted_code = job.wait()
    if not formatted_code:
        pass
    else:
        vl = vim.bindeval("s:formatted_code")
        vl.extend(formatted_code.split("\n"))


###############################################################################


if __name__ == "__main__":
    pass
