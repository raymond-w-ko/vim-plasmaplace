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

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" utils
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" gets the project path of the current buffer
function! s:get_project_path() abort
  let path = expand("%:p:h")
  let prev_path = path
  while 1
    if filereadable(path."/project.clj") || filereadable(path."./deps.edn")
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
  let s:repl_scratch_buffers[a:project_key] = bnum
  return bnum
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
  let options = {
      \ "term_name": project_key,
      \ "cwd": project_dir,
      \ "term_finish": "close",
      \ "vertical": g:plasmaplace_use_vertical_split,
      \ "stoponexit": "term",
      \ "norestore": 1,
      \ }
  let repl_buf = term_start("lein repl", options)
  exe "wincmd " . g:plasmaplace_repl_split_wincmd
  let s:repl_jobs[project_key] = repl_buf

  if g:plasmaplace_hide_repl_after_create
    wincmd c
  endif

  let clj_path = resolve(s:script_path . "/../clj/plasmaplace.clj")
  call s:to_repl(repl_buf, '(load-file "' . clj_path . '")')

  let scratch = s:create_or_get_scratch(project_key)
  let s:repl_to_scratch[repl_buf] = scratch
  let s:repl_to_project_key[repl_buf] = project_key
  return repl_buf
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" callbacks
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! g:Tapi_plasmaplace_echom(bufnum, arg) abort
  echom a:arg
endfunction

function! g:Tapi_plasmaplace_scratch(bufnum, s) abort
  let current_win = winnr()
  let scratch = s:repl_to_scratch[a:bufnum]
  let info = getbufinfo(scratch)[0]
  let windows = info["windows"] 
  if len(windows) > 0
    let winnr = windows[0]
    exe win_id2tabwin(winnr)[1] . "wincmd w"
    let n = line('$') + 1
  endif
  call appendbufline(scratch, "$", split(a:s, "\n"))
  if len(windows) > 0
    exe "normal " . n . "ggzt"
    exe current_win . "wincmd w"
  endif
endfunction


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" main
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:Require(bang, echo, ns) abort
  if &autowrite || &autowriteall
    silent! wall
  endif

  let ext = expand('%:e')
  let ns = a:ns

  let repl_buf = s:create_or_get_repl()
  if ext ==# 'cljs'
  else
    if ns ==# ""
      let ns = plasmaplace#ns()
    endif
    let ns = s:qsym(ns)
    let reload_level = ":reload"
    if a:bang
      let reload_level .= "-all"
    endif
    let cmd = printf("(plasmaplace/Require %s %s)", ns, reload_level)
    call s:to_repl(repl_buf, cmd)
  endif
  if a:echo
    echo cmd
  endif
  return ""
endfunction

function! s:setup_commands() abort
  command! -buffer -bar -bang -nargs=? Require :exe s:Require(<bang>0, 1, <q-args>)
endfunction


""""""""""""""""""""""""""""""""""""""""

function! s:K() abort
  let repl_buf = s:create_or_get_repl()
  call s:to_repl(
      \ repl_buf, 
      \ printf('(plasmaplace/Doc %s)', "ns"))
  return 'echom ' . string(repl_buf)
endfunction

function! s:ShowRepl() abort
  let buf_name = s:get_project_key()
  exe g:plasmaplace_repl_split_cmd . " sbuffer " . buf_name
endfunction

nnoremap <Plug>PlasmaplaceK :call <SID>K()<CR>
nnoremap <Plug>PlasmaplaceShowRepl :call <SID>ShowRepl()<CR>

function! s:setup_keybinds() abort
  nmap <buffer> K <Plug>PlasmaplaceK
  nmap <buffer> cqp <Plug>PlasmaplaceShowRepl
  nmap <buffer> cqc <Plug>PlasmaplaceShowRepl
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

augroup plasmaplace
  autocmd!
  autocmd FileType clojure call s:setup_keybinds()
  autocmd FileType clojure call s:setup_commands()
augroup END
