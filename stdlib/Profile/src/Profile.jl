# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Profiling support, main entry point is the [`@profile`](@ref) macro.
"""
module Profile

import Base.StackTraces: lookupat, UNKNOWN, show_spec_linfo, StackFrame

# deprecated functions: use `getdict` instead
lookup(ip::UInt) = lookupat(convert(Ptr{Cvoid}, ip) - 1)
lookup(ip::Ptr{Cvoid}) = lookupat(ip - 1)

export @profile

"""
    @profile

`@profile <expression>` runs your expression while taking periodic backtraces. These are
appended to an internal buffer of backtraces.
"""
macro profile(ex)
    return quote
        try
            status = start_timer()
            if status < 0
                error(error_codes[status])
            end
            $(esc(ex))
        finally
            stop_timer()
        end
    end
end

####
#### User-level functions
####

"""
    init(; n::Integer, delay::Real))

Configure the `delay` between backtraces (measured in seconds), and the number `n` of
instruction pointers that may be stored. Each instruction pointer corresponds to a single
line of code; backtraces generally consist of a long list of instruction pointers. Default
settings can be obtained by calling this function with no arguments, and each can be set
independently using keywords or in the order `(n, delay)`.
"""
function init(; n::Union{Nothing,Integer} = nothing, delay::Union{Nothing,Real} = nothing)
    n_cur = ccall(:jl_profile_maxlen_data, Csize_t, ())
    delay_cur = ccall(:jl_profile_delay_nsec, UInt64, ())/10^9
    if n === nothing && delay === nothing
        return Int(n_cur), delay_cur
    end
    nnew = (n === nothing) ? n_cur : n
    delaynew = (delay === nothing) ? delay_cur : delay
    init(nnew, delaynew)
end

function init(n::Integer, delay::Real)
    status = ccall(:jl_profile_init, Cint, (Csize_t, UInt64), n, round(UInt64,10^9*delay))
    if status == -1
        error("could not allocate space for ", n, " instruction pointers")
    end
end

# init with default values
# Use a max size of 1M profile samples, and fire timer every 1ms
if Sys.iswindows()
    __init__() = init(1_000_000, 0.01)
else
    __init__() = init(1_000_000, 0.001)
end

"""
    clear()

Clear any existing backtraces from the internal buffer.
"""
clear() = ccall(:jl_profile_clear_data, Cvoid, ())

const LineInfoDict = Dict{UInt64, Vector{StackFrame}}
const LineInfoFlatDict = Dict{UInt64, StackFrame}

struct ProfileFormat
    maxdepth::Int
    mincount::Int
    noisefloor::Float64
    sortedby::Symbol
    combine::Bool
    C::Bool
    recur::Symbol
    function ProfileFormat(;
        C = false,
        combine = true,
        maxdepth::Int = typemax(Int),
        mincount::Int = 0,
        noisefloor = 0,
        sortedby::Symbol = :filefuncline,
        recur::Symbol = :off)
        return new(maxdepth, mincount, noisefloor, sortedby, combine, C, recur)
    end
end

"""
    print([io::IO = stdout,] [data::Vector]; kwargs...)

Prints profiling results to `io` (by default, `stdout`). If you do not
supply a `data` vector, the internal buffer of accumulated backtraces
will be used.

The keyword arguments can be any combination of:

 - `format` -- Determines whether backtraces are printed with (default, `:tree`) or without (`:flat`)
   indentation indicating tree structure.

 - `C` -- If `true`, backtraces from C and Fortran code are shown (normally they are excluded).

 - `combine` -- If `true` (default), instruction pointers are merged that correspond to the same line of code.

 - `maxdepth` -- Limits the depth higher than `maxdepth` in the `:tree` format.

 - `sortedby` -- Controls the order in `:flat` format. `:filefuncline` (default) sorts by the source
    line, whereas `:count` sorts in order of number of collected samples.

 - `noisefloor` -- Limits frames that exceed the heuristic noise floor of the sample (only applies to format `:tree`).
    A suggested value to try for this is 2.0 (the default is 0). This parameter hides samples for which `n <= noisefloor * √N`,
    where `n` is the number of samples on this line, and `N` is the number of samples for the callee.

 - `mincount` -- Limits the printout to only those lines with at least `mincount` occurrences.

 - `recur` -- Controls the recursion handling in `:tree` format. `off` (default) prints the tree as normal. `flat` instead
    compresses any recursion (by ip), showing the approximate effect of converting any self-recursion into an iterator.
    `flatc` does the same but also includes collapsing of C frames (may do odd things around `jl_apply`).
"""
function print(io::IO, data::Vector{<:Unsigned} = fetch(), lidict::Union{LineInfoDict, LineInfoFlatDict} = getdict(data);
        format = :tree,
        C = false,
        combine = true,
        maxdepth::Int = typemax(Int),
        mincount::Int = 0,
        noisefloor = 0,
        sortedby::Symbol = :filefuncline,
        recur::Symbol = :off)
    print(io, data, lidict, ProfileFormat(
            C = C,
            combine = combine,
            maxdepth = maxdepth,
            mincount = mincount,
            noisefloor = noisefloor,
            sortedby = sortedby,
            recur = recur),
        format)
end

function print(io::IO, data::Vector{<:Unsigned}, lidict::Union{LineInfoDict, LineInfoFlatDict}, fmt::ProfileFormat, format::Symbol)
    cols::Int = Base.displaysize(io)[2]
    data = convert(Vector{UInt64}, data)
    fmt.recur ∈ (:off, :flat, :flatc) || throw(ArgumentError("recur value not recognized"))
    if format === :tree
        tree(io, data, lidict, cols, fmt)
    elseif format === :flat
        fmt.recur === :off || throw(ArgumentError("format flat only implements recur=:off"))
        flat(io, data, lidict, cols, fmt)
    else
        throw(ArgumentError("output format $(repr(format)) not recognized"))
    end
end

"""
    print([io::IO = stdout,] data::Vector, lidict::LineInfoDict; kwargs...)

Prints profiling results to `io`. This variant is used to examine results exported by a
previous call to [`retrieve`](@ref). Supply the vector `data` of backtraces and
a dictionary `lidict` of line information.

See `Profile.print([io], data)` for an explanation of the valid keyword arguments.
"""
print(data::Vector{<:Unsigned} = fetch(), lidict::Union{LineInfoDict, LineInfoFlatDict} = getdict(data); kwargs...) =
    print(stdout, data, lidict; kwargs...)

"""
    retrieve() -> data, lidict

"Exports" profiling results in a portable format, returning the set of all backtraces
(`data`) and a dictionary that maps the (session-specific) instruction pointers in `data` to
`LineInfo` values that store the file name, function name, and line number. This function
allows you to save profiling results for future analysis.
"""
function retrieve()
    data = fetch()
    return (data, getdict(data))
end

function getdict(data::Vector{UInt})
    dict = LineInfoDict()
    for ip in data
        get!(() -> lookupat(convert(Ptr{Cvoid}, ip)), dict, UInt64(ip))
    end
    return dict
end

"""
    flatten(btdata::Vector, lidict::LineInfoDict) -> (newdata::Vector{UInt64}, newdict::LineInfoFlatDict)

Produces "flattened" backtrace data. Individual instruction pointers
sometimes correspond to a multi-frame backtrace due to inlining; in
such cases, this function inserts fake instruction pointers for the
inlined calls, and returns a dictionary that is a 1-to-1 mapping
between instruction pointers and a single StackFrame.
"""
function flatten(data::Vector, lidict::LineInfoDict)
    # Makes fake instruction pointers, counting down from typemax(UInt)
    newip = typemax(UInt64) - 1
    taken = Set(keys(lidict))  # make sure we don't pick one that's already used
    newdict = Dict{UInt64,StackFrame}()
    newmap  = Dict{UInt64,Vector{UInt64}}()
    for (ip, trace) in lidict
        if length(trace) == 1
            newdict[ip] = trace[1]
        else
            newm = UInt64[]
            for sf in trace
                while newip ∈ taken && newip > 0
                    newip -= 1
                end
                newip == 0 && error("all possible instruction pointers used")
                push!(newm, newip)
                newdict[newip] = sf
                newip -= 1
            end
            newmap[ip] = newm
        end
    end
    newdata = UInt64[]
    for ip::UInt64 in data
        if haskey(newmap, ip)
            append!(newdata, newmap[ip])
        else
            push!(newdata, ip)
        end
    end
    return (newdata, newdict)
end

"""
    callers(funcname, [data, lidict], [filename=<filename>], [linerange=<start:stop>]) -> Vector{Tuple{count, lineinfo}}

Given a previous profiling run, determine who called a particular function. Supplying the
filename (and optionally, range of line numbers over which the function is defined) allows
you to disambiguate an overloaded method. The returned value is a vector containing a count
of the number of calls and line information about the caller. One can optionally supply
backtrace `data` obtained from [`retrieve`](@ref); otherwise, the current internal
profile buffer is used.
"""
function callers end

function callers(funcname::String, bt::Vector, lidict::LineInfoFlatDict; filename = nothing, linerange = nothing)
    if filename === nothing && linerange === nothing
        return callersf(li -> String(li.func) == funcname,
            bt, lidict)
    end
    filename === nothing && throw(ArgumentError("if supplying linerange, you must also supply the filename"))
    filename = String(filename)
    if linerange === nothing
        return callersf(li -> String(li.func) == funcname && String(li.file) == filename,
            bt, lidict)
    else
        return callersf(li -> String(li.func) == funcname && String(li.file) == filename && in(li.line, linerange),
            bt, lidict)
    end
end

callers(funcname::String, bt::Vector, lidict::LineInfoDict; kwargs...) =
    callers(funcname, flatten(bt, lidict)...; kwargs...)
callers(funcname::String; kwargs...) = callers(funcname, retrieve()...; kwargs...)
callers(func::Function, bt::Vector, lidict::LineInfoFlatDict; kwargs...) =
    callers(string(func), bt, lidict; kwargs...)
callers(func::Function; kwargs...) = callers(string(func), retrieve()...; kwargs...)

##
## For --track-allocation
##
# Reset the malloc log. Used to avoid counting memory allocated during
# compilation.

"""
    clear_malloc_data()

Clears any stored memory allocation data when running julia with `--track-allocation`.
Execute the command(s) you want to test (to force JIT-compilation), then call
[`clear_malloc_data`](@ref). Then execute your command(s) again, quit
Julia, and examine the resulting `*.mem` files.
"""
clear_malloc_data() = ccall(:jl_clear_malloc_data, Cvoid, ())

# C wrappers
start_timer() = ccall(:jl_profile_start_timer, Cint, ())

stop_timer() = ccall(:jl_profile_stop_timer, Cvoid, ())

is_running() = ccall(:jl_profile_is_running, Cint, ())!=0

get_data_pointer() = convert(Ptr{UInt}, ccall(:jl_profile_get_data, Ptr{UInt8}, ()))

len_data() = convert(Int, ccall(:jl_profile_len_data, Csize_t, ()))

maxlen_data() = convert(Int, ccall(:jl_profile_maxlen_data, Csize_t, ()))

error_codes = Dict(
    -1=>"cannot specify signal action for profiling",
    -2=>"cannot create the timer for profiling",
    -3=>"cannot start the timer for profiling",
    -4=>"cannot unblock SIGUSR1")


"""
    fetch() -> data

Returns a copy of the buffer of profile backtraces. Note that the
values in `data` have meaning only on this machine in the current session, because it
depends on the exact memory addresses used in JIT-compiling. This function is primarily for
internal use; [`retrieve`](@ref) may be a better choice for most users.
"""
function fetch()
    maxlen = maxlen_data()
    len = len_data()
    if (len == maxlen)
        @warn """The profile data buffer is full; profiling probably terminated
                 before your program finished. To profile for longer runs, call
                 `Profile.init()` with a larger buffer and/or larger delay."""
    end
    data = Vector{UInt}(undef, len)
    GC.@preserve data unsafe_copyto!(pointer(data), get_data_pointer(), len)
    # post-process the data to convert from a return-stack to a call-stack
    first = true
    for i = 1:length(data)
        if data[i] == 0
            first = true
        elseif first
            first = false
        else
            data[i] -= 1
        end
    end
    return data
end


## Print as a flat list
# Counts the number of times each line appears, at any nesting level
# Merging multiple equivalent entries and recursive calls
function parse_flat(::Type{T}, data::Vector{UInt64}, lidict::Union{LineInfoDict, LineInfoFlatDict}, C::Bool) where {T}
    lilist = StackFrame[]
    n = Int[]
    lilist_idx = Dict{T, Int}()
    recursive = Set{T}()
    for ip in data
        if ip == 0
            empty!(recursive)
            continue
        end
        frames = lidict[ip]
        nframes = (frames isa Vector ? length(frames) : 1)
        for i = nframes:-1:1
            frame = (frames isa Vector ? frames[i] : frames)
            !C && frame.from_c && continue
            key = (T === UInt64 ? ip : frame)
            idx = get!(lilist_idx, key, length(lilist) + 1)
            if idx > length(lilist)
                push!(recursive, key)
                push!(lilist, frame)
                push!(n, 1)
            elseif !(key in recursive)
                push!(recursive, key)
                n[idx] += 1
            end
        end
    end
    @assert length(lilist) == length(n) == length(lilist_idx)
    return (lilist, n)
end

function flat(io::IO, data::Vector{UInt64}, lidict::Union{LineInfoDict, LineInfoFlatDict}, cols::Int, fmt::ProfileFormat)
    lilist, n = parse_flat(fmt.combine ? StackFrame : UInt64, data, lidict, fmt.C)
    if isempty(lilist)
        warning_empty()
        return
    end
    if false # optional: drop the "non-interpretable" ones
        keep = map(frame -> frame != UNKNOWN && frame.line != 0, lilist)
        lilist = lilist[keep]
        n = n[keep]
    end
    print_flat(io, lilist, n, m, cols, fmt)
    nothing
end

function print_flat(io::IO, lilist::Vector{StackFrame}, n::Vector{Int},
        cols::Int, fmt::ProfileFormat)
    if fmt.sortedby == :count
        p = sortperm(n)
    else
        p = liperm(lilist)
    end
    lilist = lilist[p]
    n = n[p]
    wcounts = max(6, ndigits(maximum(n)))
    maxline = 0
    maxfile = 6
    maxfunc = 10
    for li in lilist
        maxline = max(maxline, li.line)
        maxfile = max(maxfile, length(string(li.file)))
        maxfunc = max(maxfunc, length(string(li.func)))
    end
    wline = max(5, ndigits(maxline))
    ntext = max(20, cols - wcounts - wself - wline - 3)
    maxfunc += 25 # for type signatures
    if maxfile + maxfunc <= ntext
        wfile = maxfile
        wfunc = maxfunc
    else
        wfile = 2*ntext÷5
        wfunc = 3*ntext÷5
    end
    println(io, lpad("Count", wcounts, " "), " ", rpad("File", wfile, " "), " ",
        lpad("Line", wline, " "), " ", rpad("Function", wfunc, " "))
    for i = 1:length(n)
        n[i] < fmt.mincount && continue
        li = lilist[i]
        Base.print(io, lpad(string(n[i]), wcounts, " "), " ")
        if li == UNKNOWN
            if !fmt.combine && li.pointer != 0
                Base.print(io, "@0x", string(li.pointer, base=16))
            else
                Base.print(io, "[any unknown stackframes]")
            end
        else
            file = string(li.file)
            isempty(file) && (file = "[unknown file]")
            Base.print(io, rpad(rtruncto(file, wfile), wfile, " "), " ")
            Base.print(io, lpad(li.line > 0 ? string(li.line) : "?", wline, " "), " ")
            fname = string(li.func)
            if !li.from_c && li.linfo !== nothing
                fname = sprint(show_spec_linfo, li)
            end
            isempty(fname) && (fname = "[unknown function]")
            Base.print(io, rpad(ltruncto(fname, wfunc), wfunc, " "))
        end
        println(io)
    end
    nothing
end

## A tree representation
tree_format_linewidth(x::StackFrame) = ndigits(x.line) + 6

const indent_s = "  ╎  "^10
const indent_z = collect(eachindex(indent_s))
function indent(depth::Int)
    depth < 1 && return ""
    depth <= length(indent_z) && return indent_s[1:indent_z[depth]]
    div, rem = divrem(depth, length(indent_z))
    return (indent_s^div) * SubString(indent_s, 1, indent_z[rem])
end

function tree_format(lilist::Vector{StackFrame}, counts::Vector{Int}, level::Int, cols::Int)
    nindent = min(cols>>1, level)
    ndigcounts = ndigits(maximum(counts))
    ndigline = maximum([tree_format_linewidth(x) for x in lilist])
    ntext = max(20, cols - nindent - ndigcounts - ndigline - 5)
    widthfile = 2*ntext÷5
    widthfunc = 3*ntext÷5
    strs = Vector{String}(undef, length(lilist))
    showextra = false
    if level > nindent
        nextra = level - nindent
        nindent -= ndigits(nextra) + 2
        showextra = true
    end
    for i = 1:length(lilist)
        li = lilist[i]
        if li != UNKNOWN
            base = nindent == 0 ? "" : indent(nindent - 1) * " "
            if showextra
                base = string(base, "+", nextra, " ")
            end
            if li.line == li.pointer
                strs[i] = string(base,
                    rpad(string(counts[i]), ndigcounts, " "),
                    " ",
                    "unknown function (pointer: 0x",
                    string(li.pointer, base = 16, pad = 2*sizeof(Ptr{Cvoid})),
                    ")")
            else
                fname = string(li.func)
                if !li.from_c && li.linfo !== nothing
                    fname = sprint(show_spec_linfo, li)
                end
                strs[i] = string(base,
                    rpad(string(counts[i]), ndigcounts, " "),
                    " ",
                    rtruncto(string(li.file), widthfile),
                    ":",
                    li.line == -1 ? "?" : string(li.line),
                    "; ",
                    ltruncto(fname, widthfunc))
            end
        else
            strs[i] = ""
        end
    end
    return strs
end

# Construct a prefix trie of backtrace counts
mutable struct StackFrameTree{T} # where T <: Union{UInt64, StackFrame}
    # content fields:
    frame::StackFrame
    count::Int
    down::Dict{T, StackFrameTree{T}}
    # construction helpers:
    recur::Bool
    builder_key::Vector{UInt64}
    builder_value::Vector{StackFrameTree{T}}
    up::StackFrameTree{T}
    StackFrameTree{T}() where {T} = new(UNKNOWN, 0, Dict{T, StackFrameTree{T}}(), false, UInt64[], StackFrameTree{T}[])
end

# turn a list of backtraces into a tree (implicitly separated by NULL markers)
function tree!(root::StackFrameTree{T}, all::Vector{UInt64}, lidict::Union{LineInfoFlatDict, LineInfoDict}, C::Bool, recur::Symbol) where {T}
    parent = root
    tops = Vector{StackFrameTree{T}}()
    for i in length(all):-1:1
        ip = all[i]
        if ip == 0
            # sentinel value indicates the start of a new backtrace
            if recur === :off
                parent = root
            else
                # We mark all visited nodes to so we'll only count those branches
                # once for each backtrace. Reset that now for the next backtrace.
                while parent != root
                    parent.recur = false
                    parent = parent.up
                end
                for top in tops
                    while top.recur
                        top.recur = false
                        top = top.up
                    end
                end
                empty!(tops)
            end
            parent.count += 1
        else
            if recur === :flat || recur == :flatc
                # Rewind the `parent` tree back, if this ip was already present
                let this = parent
                    while this !== root && this.frame.pointer !== ip
                        this = this.up
                    end
                    if this !== root && (recur === :flatc || !this.frame.from_c)
                        push!(tops, parent)
                        parent = this
                        continue
                    end
                end
            end
            builder_key = parent.builder_key
            builder_value = parent.builder_value
            fastkey = searchsortedfirst(parent.builder_key, ip)
            if fastkey < length(builder_key) && builder_key[fastkey] === ip
                # jump forward to the end of the inlining chain
                # avoiding an extra (slow) lookup of `ip` in `lidict`
                # and an extra chain of them in `down`
                # note that we may even have this === parent (if we're ignoring this frame ip)
                this = builder_value[fastkey]
                let this = this
                    if recur === :off || !this.recur
                        while this !== parent
                            this.count += 1
                            this.recur = true
                            this = this.up
                        end
                    end
                end
                parent = this
                continue
            end
            frames = lidict[ip]
            nframes = (frames isa Vector ? length(frames) : 1)
            this = parent
            # add all the inlining frames
            for i = nframes:-1:1
                frame = (frames isa Vector ? frames[i] : frames)
                !C && frame.from_c && continue
                key = (T === UInt64 ? ip : frame)
                this = get!(StackFrameTree{T}, parent.down, key)
                if recur === :off || !this.recur
                    this.frame = frame
                    this.up = parent
                    this.count += 1
                    this.recur = true
                end
                parent = this
            end
            # record where the end of this chain is for this ip
            insert!(builder_key, fastkey, ip)
            insert!(builder_value, fastkey, this)
        end
    end
    function cleanup!(node::StackFrameTree)
        stack = [node]
        while !isempty(stack)
            node = pop!(stack)
            node.recur = false
            empty!(node.builder_key)
            empty!(node.builder_value)
            append!(stack, values(node.down))
        end
        nothing
    end
    cleanup!(root)
    return root
end

function tree_combine(root::StackFrameTree{UInt64})
    combined = StackFrameTree{StackFrame}()
    stack = [(root, combined)]
    while !isempty(stack)
        old, new = pop!(stack)
        new.frame = old.frame
        new.count += old.count
        for down in values(old.down)
            this = get!(StackFrameTree{StackFrame}, new.down, down.frame)
            this.up = new
            push!(stack, (down, this))
        end
    end
    return combined
end

# Print the stack frame tree starting at a particular root. Uses a worklist to
# avoid stack overflows.
function tree(io::IO, bt::StackFrameTree, cols::Int, fmt::ProfileFormat)
    worklist = [(bt, 0, 0, "")]
    while !isempty(worklist)
        (bt, level, noisefloor, str) = popfirst!(worklist)
        isempty(str) || println(io, str)
        level > fmt.maxdepth && continue
        isempty(bt.down) && continue
        # Order the line information
        nexts = collect(values(bt.down))
        lilist = collect(frame.frame for frame in nexts)
        counts = collect(frame.count for frame in nexts)
        # Generate the string for each line
        strs = tree_format(lilist, counts, level, cols)
        # Recurse to the next level
        for i in reverse(liperm(lilist))
            down = nexts[i]
            count = down.count
            count < fmt.mincount && continue
            count < noisefloor && continue
            str = strs[i]
            isempty(str) && (str = "$count unknown stackframe")
            noisefloor_down = fmt.noisefloor > 0 ? floor(Int, fmt.noisefloor * sqrt(count)) : 0
            pushfirst!(worklist, (down, level + 1, noisefloor_down, str))
        end
    end
end

function tree(io::IO, data::Vector{UInt64}, lidict::Union{LineInfoFlatDict, LineInfoDict}, cols::Int, fmt::ProfileFormat)
    if fmt.combine && fmt.recur === :off
        root = tree!(StackFrameTree{StackFrame}(), data, lidict, fmt.C, fmt.recur)
    else
        root = tree!(StackFrameTree{UInt64}(), data, lidict, fmt.C, fmt.recur)
    end
    if isempty(root.down)
        warning_empty()
        return
    end
    if fmt.combine && root isa StackFrameTree{UInt64}
        root = tree_combine(root)
    end
    tree(io, root, cols, fmt)
    nothing
end

function callersf(matchfunc::Function, bt::Vector, lidict::LineInfoFlatDict)
    counts = Dict{StackFrame, Int}()
    lastmatched = false
    for id in bt
        if id == 0
            lastmatched = false
            continue
        end
        li = lidict[id]
        if lastmatched
            if haskey(counts, li)
                counts[li] += 1
            else
                counts[li] = 1
            end
        end
        lastmatched = matchfunc(li)
    end
    k = collect(keys(counts))
    v = collect(values(counts))
    p = sortperm(v, rev=true)
    return [(v[i], k[i]) for i in p]
end

# Utilities
function rtruncto(str::String, w::Int)
    if length(str) <= w
        return str
    else
        return string("...", str[prevind(str, end, w-4):end])
    end
end
function ltruncto(str::String, w::Int)
    if length(str) <= w
        return str
    else
        return string(str[1:nextind(str, 1, w-4)], "...")
    end
end


truncto(str::Symbol, w::Int) = truncto(string(str), w)

# Order alphabetically (file, function) and then by line number
function liperm(lilist::Vector{StackFrame})
    function lt(a::StackFrame, b::StackFrame)
        a == UNKNOWN && return false
        b == UNKNOWN && return true
        fcmp = cmp(a.file, b.file)
        fcmp < 0 && return true
        fcmp > 0 && return false
        fcmp = cmp(a.func, b.func)
        fcmp < 0 && return true
        fcmp > 0 && return false
        fcmp = cmp(a.line, b.line)
        fcmp < 0 && return true
        return false
    end
    return sortperm(lilist, lt = lt)
end

warning_empty() = @warn """
            There were no samples collected. Run your program longer (perhaps by
            running it multiple times), or adjust the delay between samples with
            `Profile.init()`."""

end # module
