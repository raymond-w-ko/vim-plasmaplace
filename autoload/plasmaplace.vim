"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" clojure util functions
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
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

" turn in memory string to (read)-able string
function! plasmaplace#pr_str(string) abort
  return '"' . escape(a:string, '"\') . '"'
endfunction

" turn in memory string to python (read)-able string, newlines allowed
function! plasmaplace#py_pr_str(string) abort
  return '"""' . escape(a:string, '"\') . '"""'
endfunction

" quote a clojure symbol
function! plasmaplace#quote(symbol) abort
  if a:symbol =~# '^[[:alnum:]?*!+/=<>.:-]\+$'
    return "'".a:symbol
  else
    return '(symbol '.s:str(a:symbol).')'
  endif
endfunction

" convert path to namespace
function! plasmaplace#to_ns(path) abort
  return tr(substitute(a:path, '\.\w\+$', '', ''), '\/_', '..-')
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" channel util functions
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" get channel ID number from channel object
function! plasmaplace#ch_get_id(ch) abort
  let info = ch_info(a:ch)
  return info["id"]
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" vim buffer and window util functions
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! plasmaplace#get_buffer_num_lines(buffer) abort
  let numlines = py3eval('len(vim.buffers[' . a:buffer . '])')
  return numlines
endfunction

function! plasmaplace#get_win_pos(winnr)
  return py3eval(printf('(lambda win: [win.col, win.row])(vim.windows[%s - 1])', a:winnr))
endfunction

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" project util functions
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
let s:project_type_cache = {}
function! plasmaplace#get_project_type(path) abort
  if has_key(s:project_type_cache, a:path)
    return s:project_type_cache[a:path]
  endif

  let project_type = 0
  if filereadable(a:path . "/shadow-cljs.edn")
    let project_type = "shadow-cljs"
  elseif filereadable(a:path . "/project.clj")
    let project_type = "default"
  elseif filereadable(a:path . "/deps.edn")
    let project_type = "default"
  endif
  let s:project_type_cache[a:path] = project_type
  return project_type
endfunction

let s:project_path_cache = {}
function! plasmaplace#get_project_path() abort
  let path = expand("%:p:h")
  let starting_path = path
  if has_key(s:project_path_cache, starting_path)
    return s:project_path_cache[starting_path]
  endif

  let prev_path = path
  while 1
    let project_type = plasmaplace#get_project_type(path)
    if type(project_type) == v:t_string
      let s:project_path_cache[starting_path] = path
      return path
    endif
    let prev_path = path
    let path = fnamemodify(path, ':h')
    if path == prev_path
      throw "plasmaplace: could not determine project directory"
    endif
  endwhile
endfunction

let s:project_key_cache = {}
function! plasmaplace#get_project_key() abort
  let project_path = plasmaplace#get_project_path()
  if has_key(s:project_key_cache, project_path)
    return s:project_key_cache[project_path]
  endif

  let tokens = split(project_path, '\v\\|\/')
  let token = filter(tokens, 'strlen(v:val) > 0')
  let tokens = reverse(tokens)
  let project_key = join(tokens, "_")
  let s:project_key_cache[project_path] = project_key
  return project_key
endfunction


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" init and reset functions
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! plasmaplace#reset_caches() abort
  let s:project_type_cache = {}
  let s:project_path_cache = {}
  let s:project_key_cache = {}
endfunction
