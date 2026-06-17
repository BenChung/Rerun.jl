# String/bytes marshalling between Julia and rerun_c's non-owning views.
#
# `rr_string`/`rr_bytes` are (pointer, length) views that do NOT own their data;
# rerun only reads them for the duration of the call. So the backing Julia
# object must stay alive (rooted) across the ccall.
#
# For arguments declared as `rr_string` in the generated ccall wrappers, the
# cconvert/unsafe_convert pair lets ccall handle rooting automatically: just
# pass a Julia string. For `rr_string`s embedded in structs we build by hand
# (e.g. rr_store_info), use `_rrstr` and keep the backing string alive with
# `GC.@preserve` yourself.

# ccall-argument path: `ccall(..., (rr_string,), s::AbstractString)` just works.
Base.cconvert(::Type{LibRerunC.rr_string}, s::AbstractString) = String(s)
Base.cconvert(::Type{LibRerunC.rr_string}, s::String) = s
Base.unsafe_convert(::Type{LibRerunC.rr_string}, s::String) =
    LibRerunC.rr_string(pointer(s), UInt32(ncodeunits(s)))

# Manual struct-field path. Caller MUST keep `s` rooted across the C call.
_rrstr(s::String) = LibRerunC.rr_string(pointer(s), UInt32(ncodeunits(s)))
_rrstr(::Nothing) = LibRerunC.rr_string(Ptr{Cchar}(C_NULL), UInt32(0))

# ccall-argument path for `rr_bytes`: pass a byte vector directly.
Base.cconvert(::Type{LibRerunC.rr_bytes}, v::AbstractVector{UInt8}) = v isa Vector{UInt8} ? v : Vector{UInt8}(v)
Base.unsafe_convert(::Type{LibRerunC.rr_bytes}, v::Vector{UInt8}) =
    LibRerunC.rr_bytes(pointer(v), UInt32(length(v)))

# Heap-allocated NUL-terminated C string (caller/owner frees with `Libc.free`).
function _cstr(s::AbstractString)
    n = ncodeunits(s)
    p = Ptr{UInt8}(Libc.malloc(n + 1))
    GC.@preserve s unsafe_copyto!(p, pointer(s), n)
    unsafe_store!(p, 0x00, n + 1)
    return Ptr{Cchar}(p)
end
