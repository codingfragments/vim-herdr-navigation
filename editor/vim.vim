" vim-herdr-navigation — Vim side
"
" Maps <C-h/j/k/l> to move between Vim splits. When there is no split
" in the requested direction (Vim is at an edge), hand off to the
" surrounding multiplexer so focus crosses into the neighbouring pane.
"
" Load it from your vimrc, e.g.:
"   source /path/to/vim-herdr-navigation/editor/vim.vim
"
" Only active inside a multiplexer pane (guards on $HERDR_PANE_ID and
" $REX_BLOCK).

if exists("g:loaded_vim_herdr_navigation")
  finish
endif
let g:loaded_vim_herdr_navigation = 1

function! s:HerdrFocus(dir) abort
  let l:herdr = empty($HERDR_BIN_PATH) ? 'herdr' : $HERDR_BIN_PATH
  " Route through the plugin's `*-edge` action (navigate --no-forward),
  " NOT `herdr pane focus` directly. That way the edge-cross gets the same
  " smart-focus target selection, cross-tab navigation, and per-tab
  " preferred-coordinate persistence as the non-Vim path. `--no-forward`
  " tells navigate to skip Vim detection (we already know we're in Vim and
  " at an edge) so it doesn't forward the chord back into Vim and loop.
  call system(shellescape(l:herdr) . ' plugin action invoke vim-herdr-navigation.' . a:dir . '-edge')
endfunction

function! s:RexFocus(dir) abort
  " From classic Vim (a CLI client) the action moves panes within the
  " tab server-side; crossing tabs needs the app's context, which a CLI
  " call doesn't have — the documented limit of this fallback path.
  let l:rex = empty($REX_BIN_DIR) ? 'rex' : $REX_BIN_DIR . '/rex'
  call system(shellescape(l:rex) . ' do -s ' . shellescape($REX_SESSION) .
        \ ' vim_nav direction=' . a:dir . ' no_forward=1')
endfunction

function! s:Navigate(wincmd, dir) abort
  let l:prev = winnr()
  execute 'wincmd ' . a:wincmd
  if winnr() == l:prev
    " No Vim window that way: cross into the multiplexer pane.
    if !empty($HERDR_PANE_ID)
      call s:HerdrFocus(a:dir)
    elseif !empty($REX_BLOCK)
      call s:RexFocus(a:dir)
    endif
  endif
endfunction

if empty($HERDR_PANE_ID) && empty($REX_BLOCK)
  finish
endif

nnoremap <silent> <C-h> :call <SID>Navigate('h', 'left')<CR>
nnoremap <silent> <C-j> :call <SID>Navigate('j', 'down')<CR>
nnoremap <silent> <C-k> :call <SID>Navigate('k', 'up')<CR>
nnoremap <silent> <C-l> :call <SID>Navigate('l', 'right')<CR>
