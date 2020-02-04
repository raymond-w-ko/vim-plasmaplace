import sys
import traceback
from queue import Queue

EXIT_CODE_QUEUE = Queue()


def _debug(obj):
    s = str(obj)
    print(s, file=sys.stderr)
    sys.stderr.flush()


def exit_plasmaplace(code=1):
    _debug("exit_plasmaplace")
    traceback.print_exc(file=sys.stderr)
    EXIT_CODE_QUEUE.put(code)
