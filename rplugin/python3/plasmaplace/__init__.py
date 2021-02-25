import sys
import json
import select
import subprocess
from subprocess import Popen, PIPE, STDOUT
import pynvim


@pynvim.plugin
class Plasmaplace():
    def __init__(self, nvim):
        self.nvim = nvim
        self.job_id = 0
        self.msg_id = 1
        self.job_to_process = {}
        self.job_to_cmd = {}

    @pynvim.autocmd("BufEnter", pattern="*", eval='expand("<afile>")', sync=True)
    def nop(self, filename):
        pass

    @pynvim.function("Plasmaplace_nvim_start_job", sync=True)
    def start_job(self, args):
        cmd = args[0]
        cmd = list(map(str, cmd))
        job_id = self.job_id
        self.job_id += 1
        p = Popen(cmd, stdout=PIPE, stdin=PIPE, stderr=PIPE, bufsize=1)
        self.job_to_process[job_id] = p
        return job_id

    def restart_job(self, job_id):
        cmd = self.job_to_cmd[job_id]
        p = Popen(cmd, stdout=PIPE, stdin=PIPE, stderr=PIPE, bufsize=1)
        self.job_to_process[job_id] = p


    @pynvim.function("Plasmaplace_nvim_stop_job", sync=True)
    def stop_job(self, args):
        job_id = args[0]
        if job_id in self.job_to_process:
            p = self.job_to_process[job_id]
            p.kill()
            del self.job_to_process[job_id]

    @pynvim.function("Plasmaplace_nvim_send_cmd", sync=True)
    def send_cmd(self, args):
        job_id, cmd, timeout = args
        p = self.job_to_process[job_id]
        is_running = p.poll() is None
        if not is_running:
            return {"dead": True}
        msg_id = self.msg_id
        self.msg_id += 1

        while True:
            msg = json.dumps([msg_id, cmd])
            p.stdin.write(msg.encode("utf-8"))
            p.stdin.write("\n".encode("utf-8"))
            p.stdin.flush()

            ready, _, _ = select.select([p.stdout], [], [], timeout)
            if len(ready) == 0:
                return {"timeout": True}
            ret = p.stdout.readline()

            if ret is None:
                return {}
            ret = ret.decode("utf-8")
            if not ret:
                return {}
            ret_msg_id, ret = json.loads(ret)
            if ret_msg_id != msg_id:
                continue
            return ret
