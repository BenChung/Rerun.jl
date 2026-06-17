# Error handling: turn the C `rr_error*` out-parameter protocol into Julia exceptions.

"""
    RerunError <: Exception

Raised when a fallible rerun_c call reports a non-OK `rr_error`.
"""
struct RerunError <: Exception
    code::UInt32
    message::String
end

function Base.showerror(io::IO, e::RerunError)
    print(io, "RerunError(", _error_code_name(e.code), "): ", e.message)
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

function _error_code_name(code::Integer)
    for n in names(LibRerunC; all=true)
        s = string(n)
        startswith(s, "RR_ERROR_CODE_") || continue
        getproperty(LibRerunC, n) == code && return s
    end
    return "code=$code"
end
