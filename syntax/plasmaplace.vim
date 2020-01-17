hi link plasmaplace_hr Comment
syn match plasmaplace_hr /\v^;;;+/ containedin=ALL

hi link plasmaplace_error Error
syn match plasmaplace_error /\v^;; ERR/ containedin=ALL
syn match plasmaplace_error /\v^;; EX/ containedin=ALL
syn match plasmaplace_error /\v^;; STACKTRACE/ containedin=ALL
syn match plasmaplace_error /\v^;; UNKNOWN/ containedin=ALL

hi link plasmaplace_out Keyword
syn match plasmaplace_out /\v^;; OUT/ containedin=ALL
syn match plasmaplace_out /\v^;; VALUE/ containedin=ALL
