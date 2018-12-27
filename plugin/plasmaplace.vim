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
let s:repl_scratch_buffers = {}

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

  let ns = s:qsym(plasmaplace#ns())
  let cmd = printf("plasmaplace.Eval(%s, %s)", s:pystr(ns), s:pystr(@@))
  call plasmaplace#py(cmd)

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
  let cmd = printf("plasmaplace.Macroexpand(%s, %s)", s:pystr(ns), s:pystr(@@))
  call plasmaplace#py(cmd)

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
  let cmd = printf("plasmaplace.Macroexpand1(%s, %s)", s:pystr(ns), s:pystr(@@))
  call plasmaplace#py(cmd)

  let &selection = sel_save
  let @@ = reg_save
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" main
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:Require(bang, echo, ns) abort
  if expand("%:e" ==# "cljs")
    return
  endif
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

  let cmd = printf("plasmaplace.Require(%s, %s)", s:pystr(ns), s:pystr(reload_level))
  call plasmaplace#py(cmd)
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
  if a:count < 0
    let pre = ''
    if a:0
      let expr = ['(clojure.test/run-all-tests #"'.join(a:000, '|').'")']
    else
      let expr = ['(clojure.test/run-all-tests)']
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
    let pre = '(clojure.core/require '.substitute(join(reqs, ' '), '/\k\+', '', 'g').' :reload) '
    let expr = []
    let vars = filter(copy(reqs), 'v:val =~# "/"')
    let nses = filter(copy(reqs), 'v:val !~# "/"')
    if len(vars) == 1
      call add(expr, '(clojure.test/test-vars [#' . vars[0] . '])')
    elseif !empty(vars)
      call add(expr, join(['(clojure.test/test-vars'] + map(vars, '"#".v:val'), ' ').')')
    endif
    if !empty(nses)
      call add(expr, join(['(clojure.test/run-tests'] + nses, ' ').')')
    endif
  endif
  let code = join(expr, ' ')
  call plasmaplace#py(printf("plasmaplace.RunTests(%s)", s:pystr(code)))
  echo code
endfunction

""""""""""""""""""""""""""""""""""""""""

function! s:VimEnter() abort
  call plasmaplace#py("plasmaplace.VimEnter()")
endfunction

function! s:cleanup_active_sessions() abort
  call plasmaplace#py("plasmaplace.cleanup_active_sessions()")
endfunction

function! s:DeleteOtherNreplSessions() abort
  call plasmaplace#py("plasmaplace.DeleteOtherNreplSessions()")
endfunction

function! s:FlushScratchBuffer() abort
  call plasmaplace#py("plasmaplace.FlushScratchBuffer()")
endfunction

""""""""""""""""""""""""""""""""""""""""

function! s:setup_commands() abort
  command! -buffer -bar DeleteOtherNreplSessions :exe s:DeleteOtherNreplSessions()

  command! -buffer -bar -bang -nargs=? Require :exe s:Require(<bang>0, 1, <q-args>)
  command! -buffer -bar -nargs=1 Doc :exe s:Doc(<q-args>)
  setlocal keywordprg=:Doc

  command! -buffer -bar -bang -range=0 -nargs=* RunTests
        \ call s:RunTests(<bang>0, <line1> == 0 ? -1 : <count>, <f-args>)
  command! -buffer -bang -nargs=* RunAllTests
        \ call s:RunTests(<bang>0, -1, <f-args>)
endfunction

""""""""""""""""""""""""""""""""""""""""

function! s:setup_keybinds() abort
  " nmap <buffer> cqp <Plug>PlasmaplaceShowRepl
  " nmap <buffer> cqc <Plug>PlasmaplaceShowRepl
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

  " tests
  nmap <buffer> cpr :<C-R>=expand('%:e') ==# 'cljs' ? 'Require' : 'RunTests'<CR><CR>
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

augroup plasmaplace
  autocmd!
  autocmd FileType clojure call s:setup_commands()
  autocmd FileType clojure call s:setup_keybinds()
  autocmd VimEnter * call s:VimEnter()
  autocmd VimLeave * call s:cleanup_active_sessions()
  autocmd InsertLeave,BufEnter * call s:FlushScratchBuffer()
augroup END
