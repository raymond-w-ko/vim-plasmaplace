
# vim-plasmaplace

A neovim/vim8 + python3 plugin for working with Clojure that is heavily inspired
by [tpope/vim-fireplace](https://github.com/tpope/vim-fireplace).

One of my main gripes with `vim-plasmaplace` is that connections are one-shot
and not session based. That has historically lead to hangs either due to missing
terminators in messages or out of order messages. nREPL generally relies of a
persistent connection that delivers streaming messages. This now may not be
true: https://github.com/tpope/vim-fireplace/pull/323#issuecomment-488209872

So, plasmaplace attempts to fix this by having a persistent connection and
relying on having producer and consumer threads and queues in Python 3. All
operations are modeled as blocking, synchronous 'jobs' that write to a REPL
input queue, and then waits for output from nREPL by blocking while reading from
the nREPL output queue. This is not without risk however, as deadlocks can
happen when things go terribly wrong.

The other unique feature in the design of plasmaplace is the concept of a
persistent 'scratch' buffer. Almost all operations have their output written to
this temporary buffer. It is not saved and disappears when you exit Vim. This
way, you can:

* copy code snippets / forms like in any other Clojure file
* have documentation side by side while you code
* a history of code `(eval)` along with their results
