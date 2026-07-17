# Error handling: turn the C `rr_error*` out-parameter protocol into Julia exceptions.

"""
    RerunError <: Exception

Raised when a fallible rerun call fails: `code` is the rerun_c `rr_error` code
for C-reported failures, `nothing` for errors raised on the Julia side (e.g.
librerun_query failures and query validation).
"""
struct RerunError <: Exception
    code::Union{UInt32,Nothing}
    message::String
end
RerunError(message::AbstractString) = RerunError(nothing, String(message))

function Base.showerror(io::IO, e::RerunError)
    print(io, "RerunError")
    e.code === nothing || print(io, "(", _error_code_name(e.code), ")")
    print(io, ": ", e.message)
end

# Decode the fixed 2048-byte description buffer (NUL-terminated UTF-8).
function _error_message(e::LibRerunC.rr_error)
    bytes = UInt8[]
    for c in e.description
        c == 0 && break
        push!(bytes, c % UInt8)
    end
    return String(bytes)
end

"""
    checked(f) -> ret

Run a fallible rerun_c call. `f` receives a `Ptr{rr_error}` to pass as the
call's trailing error argument and returns the call's result. Throws
[`RerunError`](@ref) if the call sets a non-OK code; otherwise returns `ret`.
"""
function checked(f)
    err = Ref{LibRerunC.rr_error}()
    GC.@preserve err begin
        p = Base.unsafe_convert(Ptr{LibRerunC.rr_error}, err)
        unsafe_store!(Ptr{UInt32}(p), UInt32(0))          # code = RR_ERROR_CODE_OK
        ret = f(p)
        code = unsafe_load(Ptr{UInt32}(p))
        if code != 0
            throw(RerunError(code, _error_message(unsafe_load(p))))
        end
        return ret
    end
end

# Non-throwing `checked` for void calls: returns the `RerunError` (or `nothing`)
# instead of throwing, so callers can run cleanup on the cold path without a
# `catch` handler — a handler inside a `GC.@preserve` region blocks allocation
# elision of the preserved `Ref`s, heap-allocating the hot path.
function _checked_err(f)::Union{Nothing,RerunError}
    err = Ref{LibRerunC.rr_error}()
    GC.@preserve err begin
        p = Base.unsafe_convert(Ptr{LibRerunC.rr_error}, err)
        unsafe_store!(Ptr{UInt32}(p), UInt32(0))          # code = RR_ERROR_CODE_OK
        f(p)
        code = unsafe_load(Ptr{UInt32}(p))
        code == 0 && return nothing
        return RerunError(code, _error_message(unsafe_load(p)))
    end
end

function _error_code_name(code::Integer)
    for n in names(LibRerunC; all=true)
        s = string(n)
        startswith(s, "RR_ERROR_CODE_") || continue
        getproperty(LibRerunC, n) == code && return s
    end
    return "code=$code"
end
