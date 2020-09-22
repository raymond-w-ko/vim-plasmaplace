" plasmaplace.vim - Clojure REPL support
" Some of this code is adapted from tpope/vim-fireplace
" So, some credit goes there
if exists("g:loaded_plasmaplace") || v:version < 800 || &compatible
  finish
endif
let g:loaded_plasmaplace = 1

if !has("python3")
  echoerr "vim-plasmaplace plugin requires python3"
else
  python3 import vim
endif

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" global vars
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
if !exists("g:plasmaplace_scratch_split_cmd")
  let g:plasmaplace_scratch_split_cmd = "botright vnew"
endif
if !exists("g:plasmaplace_command_timeout_ms")
  let g:plasmaplace_command_timeout_ms = 8192
endif

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" internal vars
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
let s:script_path = expand('<sfile>:p:h')
let s:python_dir = fnamemodify(expand("<sfile>"), ":p:h:h") . "/python"
let s:daemon_path = s:python_dir . "/plasmaplace.py"
let s:repl_scratch_buffers = {}
let s:jobs = {}
let s:channels = {}
let s:channel_id_to_project_key = {}
let s:last_eval_ns = ""
let s:last_eval_form = ""

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" utils
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" turn in memory string to (read)-able string
function! s:str(string) abort
  return '"' . escape(a:string, '"\') . '"'
endfunction

" turn in memory string to python (read)-able string, newlines allowed
function! s:pystr(string) abort
  return '"""' . escape(a:string, '"\') . '"""'
endfunction

" quote a clojure symbol
function! s:qsym(symbol) abort
  if a:symbol =~# '^[[:alnum:]?*!+/=<>.:-]\+$'
    return "'".a:symbol
  else
    return '(symbol '.s:str(a:symbol).')'
  endif
endfunction

" convert path to namespace
function! s:to_ns(path) abort
  return tr(substitute(a:path, '\.\w\+$', '', ''), '\/_', '..-')
endfunction

" get the namespace symbol of the current buffer
function! plasmaplace#ns() abort
  let buffer = "%"
  let head = getbufline(buffer, 1, 50)
  let blank = '^\s*\%(;.*\)\=$'
  call filter(head, 'v:val !~# blank')
  let keyword_group = '[A-Za-z0-9_?*!+/=<>.-]'
  let lines = join(head[0:49], ' ')
  let lines = substitute(lines, '"\%(\\.\|[^"]\)*"\|\\.', '', 'g')
  let lines = substitute(lines, '\^\={[^{}]*}', '', '')
  let lines = substitute(lines, '\^:'.keyword_group.'\+', '', 'g')
  let ns = matchstr(lines, '\C^(\s*\%(in-ns\s*''\|ns\s\+\)\zs'.keyword_group.'\+\ze')
  if ns !=# ''
    return ns
  else
    if buffer ==# "%"
      let path = expand(buffer, ":p")
    endif
    throw "plasmaplace: could not deduce namespace of buffer: " . path
  endif
endfunction

" get number of lines in a buffer
function! plasmaplace#get_buffer_num_lines(buffer) abort
  let numlines = py3eval('len(vim.buffers[' . a:buffer . '])')
  return numlines
endfunction

" get channel ID number from channel object
function! s:ch_get_id(ch) abort
  let id = substitute(a:ch, '^channel \(\d\+\) \(open\|closed\)$', '\1', '')
endfunction

function! s:echo_warning(msg)
  echohl WarningMsg
  echo a:msg
  echohl None
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

function! s:get_project_type(path) abort
  if filereadable(a:path . "/shadow-cljs.edn")
    return "shadow-cljs"
  elseif filereadable(a:path . "/project.clj")
    return "default"
  elseif filereadable(a:path . "/deps.edn")
    return "default"
  endif
  return 0
endfunction

function! s:get_project_path() abort
  let path = expand("%:p:h")
  let prev_path = path
  while 1
    let project_type = s:get_project_type(path)
    if type(project_type) == v:t_string
      return path
    endif
    let prev_path = path
    let path = fnamemodify(path, ':h')
    if path == prev_path
      throw "plasmaplace: could not determine project directory"
    endif
  endwhile
endfunction

function! s:get_project_key() abort
  let project_path = s:get_project_path()
  let tokens = split(project_path, '\v\\|\/')
  let token = filter(tokens, 'strlen(v:val) > 0')
  let tokens = reverse(tokens)
  return join(tokens, "_")
endfunction

function! s:set_scratch_window_options() abort
  setlocal foldcolumn=0
  setlocal nofoldenable
  setlocal number
endfunction

" send Clojure form to REPL to (eval)
function! s:create_or_get_scratch(project_key) abort
  if has_key(s:repl_scratch_buffers, a:project_key)
    return s:repl_scratch_buffers[a:project_key]
  endif

  let buf_name = "SCRATCH_".a:project_key
  execute g:plasmaplace_scratch_split_cmd . " " . buf_name
  " setlocal filetype=clojure
  setlocal bufhidden=
  setlocal buflisted
  setlocal buftype=nofile
  setlocal noswapfile
  setlocal ft=plasmaplace
  call s:set_scratch_window_options()
  let bnum = bufnr("%")
  call setbufvar(bnum, "scrollfix_disabled", 1)
  call setbufvar(bnum, "ale_enabled", 0)
  call setbufline(bnum, 1, ";; Loading Clojure REPL...")
  nnoremap <buffer> q :q<CR>
  nnoremap <buffer> gq :q<CR>
  " nnoremap <buffer> <CR> :call <SID>ShowRepl()<CR>
  runtime! syntax/plasmaplace.vim
  let s:repl_scratch_buffers[a:project_key] = bnum
  wincmd p
  redraw
  return bnum
endfunction

function! plasmaplace#__job_callback(ch, msg) abort
  try
    let ch_id = s:ch_get_id(a:ch)
    let project_key = s:channel_id_to_project_key[ch_id]
    call s:handle_message(project_key, a:msg)
  catch /E716/
    " No-op if data isn't ready
  endtry
endfunction

function! plasmaplace#__close_callback(ch) abort
    let ch_id = s:ch_get_id(a:ch)
    let project_key = s:channel_id_to_project_key[ch_id]
    call remove(s:channel_id_to_project_key, ch_id)
    call remove(s:jobs, project_key)
    call remove(s:channels, project_key)
    call s:echo_warning(printf("plasmaplace daemon died for project: %s", project_key))
endfunction

function! s:is_invalid_response(msg) abort
  return type(a:msg) == v:t_string && a:msg ==# ""
endfunction

" a lot of the wrapper code is adapted from metakirby5/codi.vim
function! s:handle_message(project_key, msg) abort
  if s:is_invalid_response(a:msg)
    call s:echo_warning("vim-plasmaplace REPL command timed out")
  elseif has_key(a:msg, "value")
    return a:msg["value"]
  elseif has_key(a:msg, "lines")
    let skip_center = 0
    if has_key(a:msg, "skip_center")
      let skip_center = a:msg["skip_center"]
    endif
    call s:append_lines_to_scratch(a:project_key, a:msg["lines"], skip_center)
  endif
endfunction

function! s:append_lines_to_scratch(project_key, lines, skip_center) abort
  " save for later
  let ret_bufnr = bufnr('%')
  let ret_mode = mode()
  let ret_line = line('.')
  let ret_col = col('.')

  let scratch_bufnr = s:repl_scratch_buffers[a:project_key]
  let top_line_num = plasmaplace#get_buffer_num_lines(scratch_bufnr) + 1
  call appendbufline(scratch_bufnr, "$", a:lines)
  if !a:skip_center
    call plasmaplace#center_scratch_buf(scratch_bufnr, top_line_num)
  endif

  " restore mode and position
  if ret_mode =~ '[vV]'
    keepjumps normal! gv
  elseif ret_mode =~ '[sS]'
    exe "keepjumps normal! gv\<c-g>"
  endif
  keepjumps call cursor(ret_line, ret_col)
endfunction

function! s:create_or_get_job(project_key) abort
  if has_key(s:jobs, a:project_key)
    return s:jobs[a:project_key]
  endif

  let project_path = s:get_project_path()
  let project_type = s:get_project_type(project_path)

  let port_file_candidates = [".nrepl-port", ".shadow-cljs/nrepl.port"]
  let port_file_path = 0
  for filename in port_file_candidates
    let path = project_path . "/" . filename
    if filereadable(path)
      let port_file_path = path
      break
    endif
  endfor
  if type(port_file_path) != v:t_string
    throw "plasmaplace: could not determine nREPL port file"
  endif

  let options = {
      \ "mode": "json",
      \ "cwd": s:get_project_path(),
      \ "callback": "plasmaplace#__job_callback",
      \ "close_cb": "plasmaplace#__close_callback",
      \ }
  if 1
    let options["err_mode"] = "raw"
    let options["err_io"] = "file"
    let options["err_name"] = "/tmp/plasmaplace.log"
  else
    let options["err_mode"] = "raw"
    let options["err_io"] = "null"
  endif
  let job = job_start(
      \ ["python3", s:daemon_path,
      \ port_file_path, project_type, g:plasmaplace_command_timeout_ms],
      \ options)
  let s:jobs[a:project_key] = job
  let ch = job_getchannel(job)
  let s:channels[a:project_key] = ch
  let ch_id = s:ch_get_id(ch)
  let s:channel_id_to_project_key[ch_id] = a:project_key

  let options = {"timeout": g:plasmaplace_command_timeout_ms}
  let msg = ch_evalexpr(ch, ["init"], options)
  call s:handle_message(a:project_key, msg)
endfunction

function! s:repl(cmd) abort
  let project_key = s:get_project_key()
  let scratch = s:create_or_get_scratch(project_key)
  let job = s:create_or_get_job(project_key)
  let ch = s:channels[project_key]

  let options = {"timeout": g:plasmaplace_command_timeout_ms}
  if a:cmd[0] == "cljfmt"
    let options["timeout"] = 8192
  endif
  let msg = ch_evalexpr(ch, a:cmd, options)

  return s:handle_message(project_key, msg)
endfunction

function! s:window_in_tab(aliases, windows) abort
  if type(a:aliases) != v:t_list  | return 0 | endif
  if type(a:windows) != v:t_list | return 0 | endif
  for x in a:aliases
    for y in a:windows
      if x == y
        return 1
      endif
    endfor
  endfor
  return 0
endfunction

function! plasmaplace#center_scratch_buf(scratch, top_line_num) abort
  let current_win = winnr()

  let info = getbufinfo(a:scratch)[0]
  let buffer_windows = info["windows"]

  let curtab = tabpagenr()
  let visible_windows = gettabinfo(curtab)[0]
  let visible_windows = visible_windows["windows"]
  if len(buffer_windows) > 0
    if !s:window_in_tab(buffer_windows, visible_windows)
      execute g:plasmaplace_scratch_split_cmd
      execute "buffer " . a:scratch
      call s:set_scratch_window_options()
    endif
    let save = winsaveview()
    let winnr = buffer_windows[0]
    exe win_id2tabwin(winnr)[1] . "wincmd w"
    exe "keepjumps normal " . a:top_line_num . "Gzt"
    exe current_win . "wincmd w"
    call winrestview(save)
  endif
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" operator
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:EvalLastForm() abort
  call s:repl(["eval", s:last_eval_ns, s:last_eval_form])
endfunction

function! s:EvalMotion(type, ...) abort
  let sel_save = &selection
  let &selection = "inclusive"
  let reg_save = @@

  if a:0  " Invoked from Visual mode, use gv command.
    silent exe "normal! gvy"
  elseif a:type == 'line'
    silent exe "normal! '[V']y"
  else
    silent exe "normal! `[v`]y"
  endif

  let ns = s:qsym(plasmaplace#ns())
  let s:last_eval_ns = ns
  let s:last_eval_form = @@
  call s:repl(["eval", s:last_eval_ns, s:last_eval_form])

  let &selection = sel_save
  let @@ = reg_save
endfunction

function! s:Macroexpand(type, ...) abort
  let sel_save = &selection
  let &selection = "inclusive"
  let reg_save = @@

  if a:0  " Invoked from Visual mode, use gv command.
    silent exe "normal! gvy"
  elseif a:type == 'line'
    silent exe "normal! '[V']y"
  else
    silent exe "normal! `[v`]y"
  endif

  let ns = s:qsym(plasmaplace#ns())
  call s:repl(["macroexpand", ns, @@])

  let &selection = sel_save
  let @@ = reg_save
endfunction

function! s:Macroexpand1(type, ...) abort
  let sel_save = &selection
  let &selection = "inclusive"
  let reg_save = @@

  if a:0  " Invoked from Visual mode, use gv command.
    silent exe "normal! gvy"
  elseif a:type == 'line'
    silent exe "normal! '[V']y"
  else
    silent exe "normal! `[v`]y"
  endif

  let ns = s:qsym(plasmaplace#ns())
  call s:repl(["macroexpand1", ns, @@])

  let &selection = sel_save
  let @@ = reg_save
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" main
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:Require(bang, echo, ns) abort
  if expand("%:e") ==# "cljs" | return | endif
  if expand("%") ==# "project.clj" | return | endif
  if expand("%") ==# "linter.cljc" | return | endif

  let project_path = s:get_project_path()
  if s:get_project_type(project_path) == "shadow-cljs" | return | endif

  if &autowrite || &autowriteall
    silent! wall
  endif

  let reload_level = ":reload"
  if a:bang
    let reload_level .= "-all"
  endif

  let ns = a:ns
  if ns ==# ""
    let ns = plasmaplace#ns()
  endif
  let ns = s:qsym(ns)

  let cmd = printf("plasmaplace.Require(%s, %s)", ns, reload_level)
  call s:repl(["require", ns, reload_level])
  if a:echo
    echo cmd
  endif
  return ""
endfunction

""""""""""""""""""""""""""""""""""""""""

function! s:Doc(symbol) abort
  " Vim shell escapes the symbol when this is called via the 'keywordprg'
  " method. This mangles functions that end with a '?' which is common in
  " Clojure predicate functions.
  let symbol = a:symbol
  let symbol = substitute(symbol, '\\?', "?", "g")
  let symbol = substitute(symbol, '\\!', "!", "g")
  let symbol = substitute(symbol, '\\\*', "*", "g")
  let symbol = substitute(symbol, '\\<', "<", "g")
  let symbol = substitute(symbol, '\\>', ">", "g")
  let ns = plasmaplace#ns()
  let ns = s:qsym(ns)
  call s:repl(["doc", ns, symbol])
  return ''
endfunction

function! s:K() abort
  let word = expand('<cword>')
  let java_candidate = matchstr(word, '^\%(\w\+\.\)*\u\l[[:alnum:]$]*\ze\%(\.\|\/\w\+\)\=$')
  if java_candidate !=# ''
    return 'Javadoc '.java_candidate
  else
    return 'Doc '.word
  endif
endfunction

nnoremap <Plug>PlasmaplaceK :<C-R>=<SID>K()<CR><CR>

""""""""""""""""""""""""""""""""""""""""

function! s:RunTests(bang, count, ...) abort
  if &autowrite || &autowriteall
    silent! wall
  endif
  let ext = expand('%:e')
  if ext ==# "cljs"
    let test_ns = "cljs.test"
  else
    let test_ns = "clojure.test"
  endif

  if a:count < 0
    if a:0
      let expr = [
          \ printf('(%s/run-all-tests #"', test_ns)
          \ . join(a:000, '|').'")'
          \ ]
    else
      let expr = [printf('(%s/run-all-tests)', test_ns)]
    endif
  else
    if a:0 && a:000 !=# [plasmaplace#ns()]
      let args = a:000
    else
      let args = [plasmaplace#ns()]
      if a:count
        let pattern = '^\s*(def\k*\s\+\(\h\k*\)'
        let line = search(pattern, 'bcWn')
        if line
          let args[0] .= '/' . matchlist(getline(line), pattern)[1]
        endif
      endif
    endif
    let reqs = map(copy(args), '"''".v:val')
    let expr = []
    let vars = filter(copy(reqs), 'v:val =~# "/"')
    let nses = filter(copy(reqs), 'v:val !~# "/"')
    if len(vars) == 1
      call add(expr,
          \ printf('(%s/test-vars [#', test_ns) 
          \ . vars[0]
          \ . '])')
    elseif !empty(vars)
      call add(expr, join(
          \ [printf('(%s/test-vars', test_ns)]
          \ + map(vars, '"#".v:val'), ' ').')')
    endif
    if !empty(nses)
      call add(expr, join([
          \ printf('(%s/run-tests', test_ns)
          \ ] + nses, ' ').')')
    endif
  endif

  let code = join(expr, ' ')
  let code = printf("(with-out-str %s)", code)
  call s:repl(["run_tests", s:qsym("user"), code])
endfunction

""""""""""""""""""""""""""""""""""""""""

function! s:get_current_buffer_contents_as_string() abort
  let tmp = []
  for line in getline(1, '$')
    let line = substitute(line, '\', '\\\\', 'g')
    call add(tmp, line)
  endfor
  let escaped_buffer_contents = join(tmp, '\n')

  " Take care of escaping quotes
  let escaped_buffer_contents = substitute(escaped_buffer_contents, '"', '\\"', 'g')
  return '"' . escaped_buffer_contents . '"'
endfunction

function! s:replace_buffer(content) abort
  let content = type(a:content) == v:t_list ? a:content : split(a:content, "\n")
  if getline(1, '$') != content
    %del
    call setline(1, content)
  endif
endfunction

function! plasmaplace#Cljfmt() abort
  let code = s:get_current_buffer_contents_as_string()
  let formatted_code = s:repl(["cljfmt", code])

  if len(formatted_code) > 0
    " save cursor position and many other things
    let l:curw = winsaveview()
    call s:replace_buffer(formatted_code)
    " restore our cursor/windows positions
    call winrestview(l:curw)
  endif
endfunction

""""""""""""""""""""""""""""""""""""""""

function! s:Reconnect() abort
  let project_key = s:get_project_key()
  if has_key(s:jobs, project_key)
    let job = s:jobs[project_key]
    call job_stop(job)
  endif
  call s:create_or_get_job(project_key)
endfunction

function! s:DeleteOtherNreplSessions() abort
  call s:repl(["delete_other_nrepl_sessions"])
endfunction

""""""""""""""""""""""""""""""""""""""""

function! s:setup_commands() abort
  command! -buffer -bar Reconnect :exe s:Reconnect()
  command! -buffer -bar DeleteOtherNreplSessions :exe s:DeleteOtherNreplSessions()

  command! -buffer -bar -bang -nargs=? Require :exe s:Require(<bang>0, 1, <q-args>)
  command! -buffer -bar -nargs=1 Doc :exe s:Doc(<q-args>)
  setlocal keywordprg=:Doc

  command! -buffer -bar -bang -range=0 -nargs=* RunTests
        \ call s:RunTests(<bang>0, <line1> == 0 ? -1 : <count>, <f-args>)
  command! -buffer -bang -nargs=* RunAllTests
        \ call s:RunTests(<bang>0, -1, <f-args>)

  command! -buffer Cljfmt call plasmaplace#Cljfmt()
endfunction

""""""""""""""""""""""""""""""""""""""""

function! s:setup_keybinds() abort
  " nmap <buffer> cqp <Plug>PlasmaplaceShowRepl
  " nmap <buffer> cqc <Plug>PlasmaplaceShowRepl
  nmap <buffer><silent> cp :set opfunc=<SID>EvalMotion<CR>g@
  vmap <buffer><silent> cp :<C-U>call <SID>EvalMotion(visualmode(), 1)<CR>
  nmap <buffer><silent> cpl :call <SID>EvalLastForm()<CR>

  " macro expansion
  nmap <buffer><silent> cm :set opfunc=<SID>Macroexpand<CR>g@
  vmap <buffer><silent> cm :<C-U>call <SID>Macroexpand(visualmode(), 1)<CR>
  nmap <buffer><silent> c1m :set opfunc=<SID>Macroexpand1<CR>g@
  vmap <buffer><silent> c1m :<C-U>call <SID>Macroexpand1(visualmode(), 1)<CR>

  " requires vim-sexp for additional operators
  nmap <buffer> cpp cpaf
  nmap <buffer> cmm cmaf
  nmap <buffer> c1mm c1maf

  " tests
  nmap <buffer> cpr :RunTests<CR>
endfunction

function! s:cleanup_daemons() abort
  for [project_key, ch] in items(s:channels)
    let options = {"timeout": g:plasmaplace_command_timeout_ms}
    let msg = ch_evalexpr(ch, ["exit"], options)
  endfor
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

augroup plasmaplace
  autocmd!
  autocmd FileType clojure call s:setup_commands()
  autocmd FileType clojure call s:setup_keybinds()
  autocmd VimLeave * call s:cleanup_daemons()
  autocmd BufWritePost *.clj call s:Require(0, 1, "")
  autocmd BufWritePost *.cljs call s:Require(0, 1, "")
  autocmd BufWritePost *.cljc call s:Require(0, 1, "")
augroup END
