" plasmaplace.vim - Clojure REPL support
" Some of this code is adapted from tpope/vim-fireplace
" So, some credit goes there
if exists("g:loaded_plasmaplace") || v:version < 800 || &compatible
  finish
endif
let g:loaded_plasmaplace = 1

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" global vars
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
if !exists("g:plasmaplace_use_vertical_split")
  let g:plasmaplace_use_vertical_split = 1
endif
if !exists("g:plasmaplace_hide_repl_after_create")
  let g:plasmaplace_hide_repl_after_create = 1
endif
if !exists("g:plasmaplace_repl_split_wincmd")
  let g:plasmaplace_repl_split_wincmd = "L"
endif
if !exists("g:plasmaplace_repl_split_cmd")
  let g:plasmaplace_repl_split_cmd = "botright vertical"
endif
if !exists("g:plasmaplace_scratch_split_cmd")
  let g:plasmaplace_scratch_split_cmd = "botright vnew"
endif

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" internal vars
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
let s:script_path = expand('<sfile>:p:h')
let s:python_dir = fnamemodify(expand("<sfile>"), ":p:h:h") . "/python"
" dict of project_key to REPL terminal jobs
let s:repl_scratch_buffers = {}
let s:repl_to_project_key = {}
let s:repl_to_scratch = {}
let s:repl_to_scratch_pending_output = {}

function! s:ClearCache() abort
  let s:file_path_to_project_key = {}
  let s:project_type_cache = {}
endfunction
call s:ClearCache()

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" python
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
if !has("python") && !has("python3")
  echom "vim-plasmaplace plugin requires +python or +python3 Vim feature"
  finish
endif
if exists("g:plasmaplace_python_version_preference")
  if g:fireplace_python_version_preference == 2:
    let s:python_version = ["2", "3"]
  elseif g:fireplace_python_version_preference == 3:
    let s:python_version = ["3", "2"]
  endif
else
  let s:python_version = ["3", "2"]
endif
for py_ver in s:python_version
  let _py = "python" . py_ver
  if has(_py)
    let s:_py = _py
    if py_ver == 2
      let s:_pyfile = "pyfile"
    elseif py_ver == 3
      let s:_pyfile = "py3file"
    endif

    " most distributions have an explicitly name Python like /usr/bin/python3
    " and /usr/bin/python2
    if executable(_py)
      let s:_pyexe = _py
    elseif executable("python")
      let s:_pyexe = "python"
    else
      let s:_pyexe = ""
    endif
    break
  endif
endfor
function! plasmaplace#py(...)
  for cmd in a:000
    execute s:_py . " " . cmd
  endfor
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" load plasmaplace python code
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
call plasmaplace#py(
    \ printf('sys.path.insert(0, "%s")', escape(s:python_dir, '\"')),
    \ "import plasmaplace",
    \ )

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" utils
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" turn in memory string to (read)-able string
function! s:str(string) abort
  return '"' . escape(a:string, '"\') . '"'
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

" send Clojure form to REPL to (eval)
function! s:create_or_get_scratch(project_key) abort
  if has_key(s:repl_scratch_buffers, a:project_key)
    return s:repl_scratch_buffers[a:project_key]
  endif

  let buf_name = "SCRATCH_".a:project_key
  execute g:plasmaplace_scratch_split_cmd . " " . buf_name
  setlocal filetype=plasmaplace
  setlocal bufhidden=
  setlocal buflisted
  setlocal buftype=nofile
  setlocal foldcolumn=0
  setlocal nofoldenable
  setlocal number
  setlocal noswapfile
  let bnum = bufnr("%")
  call setbufvar(bnum, "scrollfix_disabled", 1)
  call setbufline(bnum, 1, "Loading Clojure REPL...")
  nnoremap <buffer> q :q<CR>
  nnoremap <buffer> <CR> :call <SID>ShowRepl()<CR>
  let s:repl_scratch_buffers[a:project_key] = bnum
  wincmd p
  return bnum
endfunction

function! plasmaplace#center_scratch_buf(scratch, top_line_num) abort
  let current_win = winnr()
  let info = getbufinfo(a:scratch)[0]
  let windows = info["windows"]
  if len(windows) > 0
    let save = winsaveview()
    let winnr = windows[0]
    exe win_id2tabwin(winnr)[1] . "wincmd w"
    exe "keepjumps normal " . a:top_line_num . "Gzt"
    exe current_win . "wincmd w"
    call winrestview(save)
  endif
endfunction

" create or get the buffer number that represents the REPL
function! s:create_or_get_repl() abort
  call plasmaplace#py("plasmaplace.create_or_get_repl()")
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" operator
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
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

  let repl_buf = s:create_or_get_repl()
  let pending_output = s:repl_to_scratch_pending_output[repl_buf]
  call extend(pending_output, split(@@, "\n"))
  call add(pending_output, "")
  let cmd = printf('(try (plasmaplace/vim-call "scratch" (pr-str (with-out-str %s))) (catch #?(:clj Exception :cljs :default) e (plasmaplace/log-stack e)))', @@)
  call s:to_repl(repl_buf, cmd)

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

  let repl_buf = s:create_or_get_repl()
  let pending_output = s:repl_to_scratch_pending_output[repl_buf]
  let echoed_cmd = "(macroexpand\n'" . @@ . ")"
  call extend(pending_output, split(echoed_cmd, "\n"))
  call add(pending_output, "")
  let cmd = printf('(try (plasmaplace/vim-call "scratch" (pr-str (str (macroexpand (quote %s))))) (catch #?(:clj Exception :cljs :default) e (plasmaplace/log-stack e)))', @@)
  call s:to_repl(repl_buf, cmd)

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

  let repl_buf = s:create_or_get_repl()
  let pending_output = s:repl_to_scratch_pending_output[repl_buf]
  let echoed_cmd = "(macroexpand-1\n'" . @@ . ")"
  call extend(pending_output, split(echoed_cmd, "\n"))
  call add(pending_output, "")
  let cmd = printf('(try (plasmaplace/vim-call "scratch" (pr-str (str (macroexpand-1 (quote %s))))) (catch #?(:clj Exception :cljs :default) e (plasmaplace/log-stack e)))', @@)
  call s:to_repl(repl_buf, cmd)

  let &selection = sel_save
  let @@ = reg_save
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" main
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:SwitchToNs(...) abort
  if a:0 > 0
    let ns = a:1
  else
    let ns = plasmaplace#ns()
  endif
  let ns = s:qsym(ns)

  let repl_buf = s:create_or_get_repl()
  let cmd = printf("(in-ns %s)", ns)
  call s:to_repl(repl_buf, cmd)
endfunction

function! s:Require(bang, echo, ns) abort
  if &autowrite || &autowriteall
    silent! wall
  endif

  " used to reload plasmaplace code in case of refresh
  let project_dir = s:get_project_path()
  if s:get_project_type(project_dir) == "shadow-cljs"
    call s:LoadCode()
    return
  endif

  let ns = a:ns

  let repl_buf = s:create_or_get_repl()
  if ns ==# ""
    let ns = plasmaplace#ns()
  endif
  let reload_level = ":reload"
  if a:bang
    let reload_level .= "-all"
  endif
  let ns = s:qsym(ns)
  let cmd = printf("(plasmaplace/Require %s %s)", ns, reload_level)
  call s:to_repl(repl_buf, cmd)
  if a:echo
    echo cmd
  endif
  return ""
endfunction

""""""""""""""""""""""""""""""""""""""""

function! s:Doc(symbol) abort
  let ns = plasmaplace#ns()
  let ns = s:qsym(ns)
  call plasmaplace#py(
      \ printf('plasmaplace.Doc(%s, %s)',  s:str(ns), s:str(a:symbol)))
  return ''
endfunction

function! s:K() abort
endfunction

function! s:ShowRepl() abort
  let buf_name = s:get_project_key()
  exe g:plasmaplace_repl_split_cmd . " sbuffer " . buf_name
endfunction

nnoremap <Plug>PlasmaplaceK :<C-R>=<SID>K()<CR><CR>
nnoremap <Plug>PlasmaplaceShowRepl :call <SID>ShowRepl()<CR>

function! s:setup_commands() abort
  command! -buffer -bar -bang -nargs=? Require :exe s:Require(<bang>0, 1, <q-args>)
  command! -buffer -bar -nargs=1 Doc :exe s:Doc(<q-args>)
  setlocal keywordprg=:Doc

  command! -buffer PlasmaplaceClearCache :exe s:ClearCache()
  command! -buffer PlasmaplaceLoadCode :exe s:LoadCode()
endfunction
function! s:setup_keybinds() abort
  nmap <buffer> cqp <Plug>PlasmaplaceShowRepl
  nmap <buffer> cqc <Plug>PlasmaplaceShowRepl
  nmap <buffer><silent> cp :set opfunc=<SID>EvalMotion<CR>g@
  vmap <buffer><silent> cp :<C-U>call <SID>EvalMotion(visualmode(), 1)<CR>

  " macro expansion
  nmap <buffer><silent> cm :set opfunc=<SID>Macroexpand<CR>g@
  vmap <buffer><silent> cm :<C-U>call <SID>Macroexpand(visualmode(), 1)<CR>
  nmap <buffer><silent> c1m :set opfunc=<SID>Macroexpand1<CR>g@
  vmap <buffer><silent> c1m :<C-U>call <SID>Macroexpand1(visualmode(), 1)<CR>

  " requires vim-sexp for additional operators
  nmap <buffer> cpp cpaf
  nmap <buffer> cmm cmaf
  nmap <buffer> c1mm c1maf
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

augroup plasmaplace
  autocmd!
  autocmd FileType clojure call s:setup_commands()
  autocmd FileType clojure call s:setup_keybinds()
augroup END
