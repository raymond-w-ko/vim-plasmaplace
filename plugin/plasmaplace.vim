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
" dict of project_key to REPL terminal jobs
let s:repl_jobs = {}
let s:repl_scratch_buffers = {}
let s:repl_to_project_key = {}
let s:repl_to_scratch = {}
let s:repl_to_scratch_pending_output = {}

function! s:ClearCache() abort
  let s:project_type_cache = {}
endfunction
call s:ClearCache()

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" utils
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

function! s:get_shadow_cljs_target(project_dir) abort
  let code = readfile(a:project_dir . "/shadow-cljs.edn")
  let code = map(code, {i, line -> trim(line)})
  let code = join(code)

  let header = ":builds"
  let idx = match(code, header)
  let code = strpart(code, idx + strlen(header))

  let target = matchlist(code, '\v:(\w+)\s*\{:target\s+:browser.*')
  echom target[1]
  return target[1]
endfunction

" gets the project path of the current buffer
function! s:get_project_type(path)
  if has_key(s:project_type_cache, a:path)
    return s:project_type_cache[a:path]
  endif

  let type = 0
  if filereadable(a:path . "/project.clj")
    let type = "normal"
  endif
  if filereadable(a:path . "/deps.edn")
    let type = "normal"
  endif
  if filereadable(a:path . "/shadow-cljs.edn")
    let type = "shadow-cljs"
  endif

  let s:project_type_cache[a:path] = type
  return type
endfunction
function! s:get_project_path() abort
  let path = expand("%:p:h")
  let prev_path = path
  while 1
    let project_type = s:get_project_type(path)
    if type(project_type) == v:t_string
      break
    endif
    let prev_path = path
    let path = fnamemodify(path, ":h")
    if path == prev_path
      throw "plasmaplace: could not determine project directory"
    endif
  endwhile
  return path
endfunction

" create a unique key based on the full path of the current buffer
let s:file_path_to_project_key = {}
function! s:get_project_key() abort
  let path = expand("%:p:h")
  if has_key(s:file_path_to_project_key, path)
    return s:file_path_to_project_key[path]
  endif

  let project_path = s:get_project_path()
  let tokens = reverse(split(project_path, '\v:|\/|\\'))
  let project_key = join(tokens, "_")
  let s:file_path_to_project_key[path] = project_key
  return project_key
endfunction

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
function! s:to_repl(repl_buf, form) abort
  call term_sendkeys(a:repl_buf, a:form)
  call term_sendkeys(a:repl_buf, "\<CR>")
endfunction

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

" load plasmaplace Clojure code
function! s:load_plasmaplace_clojure_code(repl_buf) abort
  let code = readfile(s:script_path . "/../cljc/plasmaplace.cljc")
  let code = map(code, {i, line -> trim(line)})
  let code = join(code)
  call s:to_repl(a:repl_buf, code)
endfunction

function! s:LoadCode() abort
  let repl_buf = s:create_or_get_repl()
  call s:load_plasmaplace_clojure_code(repl_buf)
endfunction

" create or get the buffer number that represents the REPL
function! s:create_or_get_repl() abort
  let project_key = s:get_project_key()

  if has_key(s:repl_jobs, project_key)
    let repl_job = s:repl_jobs[project_key]
    let status = term_getstatus(repl_job)
    for s in split(status, ",")
      if s == "running"
        return repl_job
      endif
    endfor
  endif

  let project_dir = s:get_project_path()
  let project_type = s:get_project_type(project_dir)
  let options = {
      \ "term_name": project_key,
      \ "cwd": project_dir,
      \ "term_finish": "close",
      \ "vertical": g:plasmaplace_use_vertical_split,
      \ "stoponexit": "term",
      \ "norestore": 1,
      \ }
  if project_type == "shadow-cljs"
    let target = s:get_shadow_cljs_target(project_dir)
    let cmd = printf("npx shadow-cljs cljs-repl %s", target)
    let repl_buf = term_start(cmd, options)
  else
    let repl_buf = term_start("lein repl", options)
  endif
  exe "wincmd " . g:plasmaplace_repl_split_wincmd
  let s:repl_jobs[project_key] = repl_buf

  if g:plasmaplace_hide_repl_after_create
    wincmd c
  endif

  call s:load_plasmaplace_clojure_code(repl_buf)

  let scratch = s:create_or_get_scratch(project_key)
  let s:repl_to_scratch[repl_buf] = scratch
  let s:repl_to_scratch_pending_output[repl_buf] = []
  let s:repl_to_project_key[repl_buf] = project_key
  return repl_buf
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
" callbacks
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! g:Tapi_plasmaplace_echom(bufnum, arg) abort
  echom a:arg
endfunction

let s:scratch_buf_prefix = [
    \";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;",
    \ ]

function! g:Tapi_plasmaplace_scratch(bufnum, s) abort
  let current_win = winnr()
  let scratch = s:repl_to_scratch[a:bufnum]
  let info = getbufinfo(scratch)[0]
  let windows = info["windows"]
  if len(windows) > 0
    let save = winsaveview()
    let winnr = windows[0]
    exe win_id2tabwin(winnr)[1] . "wincmd w"
    let n = line('$') + 1
  endif
  let pending_output = s:repl_to_scratch_pending_output[a:bufnum]
  let lines = s:scratch_buf_prefix + pending_output + split(a:s, "\n")
  let s:repl_to_scratch_pending_output[a:bufnum] = []
  call appendbufline(scratch, "$", lines)
  if len(windows) > 0
    exe "normal " . n . "ggzt"
    exe current_win . "wincmd w"
    call winrestview(save)
  endif
endfunction


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" main
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
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

function! s:K() abort
  let word = expand('<cword>')
  let java_candidate = matchstr(word, '^\%(\w\+\.\)*\u\l[[:alnum:]$]*\ze\%(\.\|\/\w\+\)\=$')
  if java_candidate !=# ''
    " TODO
  else
    let repl_buf = s:create_or_get_repl()
    call s:to_repl(
        \ repl_buf,
        \ printf('(plasmaplace/Doc (with-out-str (clojure.repl/doc %s)))',
        \ word))
  endif
endfunction

function! s:ShowRepl() abort
  let buf_name = s:get_project_key()
  exe g:plasmaplace_repl_split_cmd . " sbuffer " . buf_name
endfunction

nnoremap <Plug>PlasmaplaceK :call <SID>K()<CR>
nnoremap <Plug>PlasmaplaceShowRepl :call <SID>ShowRepl()<CR>

function! s:setup_commands() abort
  command! -buffer -bar -bang -nargs=? Require :exe s:Require(<bang>0, 1, <q-args>)
  command! -buffer -bar -nargs=1 Doc :exe s:Doc(<q-args>)

  command! -buffer PlasmaplaceClearCache :exe s:ClearCache()
  command! -buffer PlasmaplaceLoadCode :exe s:LoadCode()
endfunction
function! s:setup_keybinds() abort
  nmap <buffer> K <Plug>PlasmaplaceK
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
