import sys
from queue import Queue

EXIT_CODE_QUEUE = Queue()


def _debug(obj):
    s = str(obj)
    print(s, file=sys.stderr)
    sys.stderr.flush()


def exit_plasmaplace(code=1):
    _debug("exit_plasmaplace")
    EXIT_CODE_QUEUE.put(code)
