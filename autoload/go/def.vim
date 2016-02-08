if !exists("g:go_godef_bin")
	let g:go_godef_bin = "godef"
    let s:go_stack = []
	let s:go_stack_level = 0
endif

if go#vimproc#has_vimproc()
	let s:vim_system = get(g:, 'gocomplete#system_function', 'vimproc#system2')
else
	let s:vim_system = get(g:, 'gocomplete#system_function', 'system')
endif

fu! s:system(str, ...)
	return call(s:vim_system, [a:str] + a:000)
endf

" modified and improved version of vim-godef
function! go#def#Jump(...)
	if !len(a:000)
		" gives us the offset of the word, basically the position of the word under
		" he cursor
		let arg = s:getOffset()
	else
		let arg = a:1
	endif

	let bin_path = go#path#CheckBinPath(g:go_godef_bin)
	if empty(bin_path)
		return
	endif

	let old_gopath = $GOPATH
	let $GOPATH = go#path#Detect()

    let fname = fnamemodify(expand("%"), ':p:gs?\\?/?')
    let command = bin_path . " -f=" . shellescape(fname) . " -t -i " . shellescape(arg)

	" get output of godef
	let out=s:system(command, join(getbufline(bufnr('%'), 1, '$'), go#util#LineEnding()))

    " First line is <file>:<line>:<col>
    " Second line is <identifier><space><type>
    let godefout=split(out, go#util#LineEnding())

	" jump to it
	call s:godefJump(godefout, "")
	let $GOPATH = old_gopath
endfunction


function! go#def#JumpMode(mode)
	let arg = s:getOffset()

	let bin_path = go#path#CheckBinPath(g:go_godef_bin)
	if empty(bin_path)
		return
	endif

	let old_gopath = $GOPATH
	let $GOPATH = go#path#Detect()

	let command = bin_path . " -i " . shellescape(arg)

	" get output of godef
	let out=s:system(command, join(getbufline(bufnr('%'), 1, '$'), go#util#LineEnding()))

	call s:godefJump(out, a:mode)
	let $GOPATH = old_gopath
endfunction


function! s:getOffset()
	let pos = getpos(".")[1:2]
	if &encoding == 'utf-8'
		let offs = line2byte(pos[0]) + pos[1] - 2
	else
		let c = pos[1]
		let buf = line('.') == 1 ? "" : (join(getline(1, pos[0] - 1), go#util#LineEnding()) . go#util#LineEnding())
		let buf .= c == 1 ? "" : getline(pos[0])[:c-2]
		let offs = len(iconv(buf, &encoding, "utf-8"))
	endif

	let argOff = "-o=" . offs
	return argOff
endfunction


function! s:godefJump(out, mode)
	let old_errorformat = &errorformat
	let &errorformat = "%f:%l:%c"

    " Location is the first line of godef output. Ideally in the proper format
    " but it could also be an error
    let location = a:out[0]

    " Echo the godef error if we had one.
	if location =~ 'godef: '
		let gderr=substitute(location, go#util#LineEnding() . '$', '', '')
		echom gderr
    " Don't jump if we're in a modified buffer
    elseif getbufvar(bufnr('%'), "&mod")
        echom "Not jumping with modified buffer"
	else
		let parts = split(a:out[0], ':')
        let idents = split(a:out[1])

		" parts[0] contains filename
		let fileName = parts[0]

		" put the error format into location list so we can jump automatically to
		" it
		lgetexpr location

		" needed for restoring back user setting this is because there are two
		" modes of switchbuf which we need based on the split mode
		let old_switchbuf = &switchbuf

		if a:mode == "tab"
			let &switchbuf = "usetab"

			if bufloaded(fileName) == 0
				tab split
			endif
		else
			if a:mode  == "split"
				split
			elseif a:mode == "vsplit"
				vsplit
			endif
		endif

        if len(s:go_stack)==0
            " put the current location on the bottom of the stack
            call add(s:go_stack,
                    \{'line': line("."), 'col': col("."), 'loc': line(".").":".col("."),
                    \'file': expand('%:p'), 'ident': "<ROOT>",
                    \'type': ""})
        endif

        " push it on to the jumpstack
        call add(s:go_stack,
                \{'line': parts[1], 'col': parts[2], 'loc': parts[1].":".parts[2],
                \'file': parts[0], 'ident': idents[0],
                \'type': join(idents[1:], " ")})

        " increment the stack counter
        let s:go_stack_level = s:go_stack_level + 1

		" jump to file now
		sil ll 1
		normal zz

		let &switchbuf = old_switchbuf
	end
	let &errorformat = old_errorformat
endfunction

let s:columnmappings = [
    \{'key': 'ident', 'title': 'Ident', 'eat': 'n'},
    \{'key': 'type', 'title': 'Type', 'eat': 'r'},
    \{'key': 'file', 'title': 'File', 'eat': 'l'},
    \{'key': 'loc', 'title': 'Loc', 'eat': 'n'}]

fu! go#def#Stack()
    " first calculate the print width we have to work with, which is:
    "   screen width
    "   - a space between every column
    "   - the mark column (1)
    "   - the numbers column (2, assuming less than 99 jumps)
    let printwidth = &columns - (len(s:columnmappings) + 1) - 3

    " set the display widths. We know that column 0 is the mark column of
    " width 1, and column 1 is the tag number column of width 3. The rest
    " of these will be calculated dynamically from the widths of their titles
    " or their contents, or from some division of what's left over on the
    " screen
    let columnwidths=[]
    let flexcolumns=[]

    " now we loop through all of the column mappings. If it's a full width
    " column (eat='n'), we get its maximum width, assign that to the layout
    " width, and subtract it from the total left over. If it's a flexible
    " column, we assign it a width of its title for now, until we can come back
    " and assign it some fraction of the remaining space.
    let i = 0
    for c in s:columnmappings
        if c['eat'] ==? "n"
            " Add the title first
            call add(columnwidths, len(c['title']))
            for r in s:go_stack
                let key = c['key']
                if len(r[key]) > columnwidths[i]
                    let columnwidths[i] = len(r[key])
                endif
            endfor
            let printwidth -= columnwidths[i]
        else
            " It's a flexible column
            let key = c['key']
            call add(columnwidths, len(c['title']))
            call add(flexcolumns, i)
        endif
        let i += 1
    endfor

    " iterate over the flexible columns and divy up the remaining precious
    " columns
    let i = 0
    let dividend = printwidth / len(flexcolumns)
    for f in flexcolumns
        if i == len(flexcolumns) - 1
            " The last flex column gets the remainder.
            let columnwidths[f] = printwidth
        else
            let columnwidths[f] = dividend
            let printwidth -= dividend
        endif
    endfor

    " we have all column widths, let's get to printing
    " print the headers
    echohl Title
    echon " #  "
    let i = 0
    for h in s:columnmappings
        echon s:printpad(h['title'], columnwidths[i], 'r')
        if i < len(columnwidths) - 1
            echon " "
        endif
        let i += 1
    endfor
    echon "\n"
    " print the stack entries
    " TODO: paging. God help me
    echohl None
    let i = 0
    for s in s:go_stack
        if i == s:go_stack_level
            " If this is the current stack level, mark it
            echon ">"
        else
            echon " "
        endif
        " print the stack number
        echon printf("%-2d", i)
        " print the stack entries
        let ci = 0
        for c in s:columnmappings
            let key = c['key']
            echon " " . s:printpad(s[key], columnwidths[ci], c['eat'])
            let ci += 1
        endfor
        let i += 1
        echon "\n"
    endfor
endfunction

fu! s:printpad(str, width, eatdir)
    if len(a:str) <= a:width
        " if the string is shorter than the width, pad it with spaces to the
        " right
        return printf("%-".a:width."s", a:str)
    else
        " otherwise the string is too long, trim it
        if a:eatdir == "r"
            let trimwidth = a:width-3
            return printf("%.".trimwidth."s...", a:str)
        else
            let trimwidth = len(a:str) - a:width + 3
            return "...".substitute(a:str,'^.\{'.trimwidth.'\}', '', '')
        endif
    endif
endfunction
