# Misc utilities: entity-path escaping and video frame-timestamp extraction.

"""
    escape_entity_path_part(part) -> String

Escape a single entity-path segment (so `/` etc. are treated literally), e.g.
`escape_entity_path_part("my object")`. Throws on invalid UTF-8 / null bytes.
"""
function escape_entity_path_part(part::AbstractString)
    cstr = LibRerunC._rr_escape_entity_path_part(part)          # rr_string arg via cconvert
    cstr == C_NULL && error("could not escape entity path part: $(repr(part))")
    s = unsafe_string(cstr)
    LibRerunC._rr_free_string(cstr)                            # the C string is owned by us
    return s
end

# Allocation callback for video timestamp extraction: rerun calls this once to
# allocate the result buffer; we back it with a Julia Vector stashed in `ctx`
# (a Ref) so it stays rooted and we can read it after the call. Synchronous, on
# the calling thread — Julia allocation here is fine.
function _alloc_timestamps(ctx::Ptr{Cvoid}, num::UInt32)::Ptr{Int64}
    ref = unsafe_pointer_to_objref(ctx)::Base.RefValue{Vector{Int64}}
    vec = Vector{Int64}(undef, Int(num))
    ref[] = vec
    return pointer(vec)
end

"""
    video_frame_timestamps_nanos(video::AbstractVector{UInt8}; media_type="") -> Vector{Int64}

Presentation timestamps (nanoseconds, monotonically increasing) of every frame
in an encoded video. `media_type` (e.g. `"video/mp4"`) is guessed if empty.
"""
function video_frame_timestamps_nanos(video::AbstractVector{UInt8}; media_type::AbstractString="")
    vbytes = video isa Vector{UInt8} ? video : Vector{UInt8}(video)
    result = Ref{Vector{Int64}}()
    alloc = @cfunction(_alloc_timestamps, Ptr{Int64}, (Ptr{Cvoid}, UInt32))
    GC.@preserve vbytes result begin
        ctx = Base.pointer_from_objref(result)
        checked(err -> LibRerunC.rr_video_asset_read_frame_timestamps_nanos(
            pointer(vbytes), UInt64(length(vbytes)), media_type, ctx, alloc, err))
    end
    return result[]
end
