
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
        self.report_exception()

        self.repl.append_to_scratch(self.lines)
        self.repl.close_session(self.session)
        self.repl.unregister_job(self)
        self.wait_queue.put("done")


###############################################################################


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
        self.wait_for_output(eval_value=True, debug=False, silent=True)

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


