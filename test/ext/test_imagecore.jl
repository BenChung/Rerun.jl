# Exercises the RerunImageCoreExt package extension. Runs in an env that has
# ImageCore + ColorTypes (+ FixedPointNumbers) as test dependencies, which
# triggers the extension to load.
#
# The load-bearing gotcha pinned here is IMAGE ORIENTATION: Julia matrices are
# column-major and indexed `img[row, col]`; Rerun image blobs are ROW-major,
# interleaved-pixel HWC. A transpose bug would put pixel (h=1,w=2) at the wrong
# byte offset. We use a NON-SQUARE 2x3 image with distinct pixels and assert the
# exact bytes for several (row,col) positions so any transpose / width-vs-height
# swap is caught.

using Rerun
using Rerun.Components: ImageBuffer
using Rerun.Archetypes: Image, DepthImage, SegmentationImage
using ImageCore
using ColorTypes
using ColorTypes.FixedPointNumbers: N0f8
using Test

@testset "RerunImageCoreExt" begin
    ext = Base.get_extension(Rerun, :RerunImageCoreExt)
    @test ext !== nothing

    @testset "channel datatype mapping" begin
        @test ext._channel_datatype(N0f8)    == ext.CHANNEL_U8   # Normed{UInt8} -> U8
        @test ext._channel_datatype(UInt8)   == ext.CHANNEL_U8
        @test ext._channel_datatype(UInt16)  == ext.CHANNEL_U16
        @test ext._channel_datatype(Int32)   == ext.CHANNEL_I32
        @test ext._channel_datatype(Float16) == ext.CHANNEL_F16
        @test ext._channel_datatype(Float32) == ext.CHANNEL_F32
        @test ext._channel_datatype(Float64) == ext.CHANNEL_F64
    end

    @testset "color Image orientation (HWC row-major, NON-SQUARE 2x3) — GOTCHA PIN" begin
        # height = 2 rows, width = 3 cols. Distinct, non-symmetric pixels:
        #   row 1: pure red, pure green, pure blue
        #   row 2: gray 0.2, gray 0.4, gray 0.6
        img = [RGB{N0f8}(1.0, 0.0, 0.0)  RGB{N0f8}(0.0, 1.0, 0.0)  RGB{N0f8}(0.0, 0.0, 1.0);
               RGB{N0f8}(0.2, 0.2, 0.2)  RGB{N0f8}(0.4, 0.4, 0.4)  RGB{N0f8}(0.6, 0.6, 0.6)]
        height, width = size(img)
        @test (height, width) == (2, 3)

        cv  = channelview(img)
        @test size(cv) == (3, height, width)        # channelview is (C, H, W)
        raw = ext._to_blob_bytes(ext._hwc_vec(cv))

        @test length(raw) == height * width * 3      # HWC, 3 channels, 1 byte each

        # Byte offset of pixel (h,w) channel c (0-based) is (h*W + w)*C + c.
        pix(h, w) = Int.(raw[((h * width + w) * 3) .+ (1:3)])
        # Pure red at (row0,col0).
        @test pix(0, 0) == [255, 0, 0]
        # GREEN at (row0,col1): if width and height were swapped (transpose), this
        # slot would instead hold the (row1,col0) gray pixel. Pins the transpose.
        @test pix(0, 1) == [0, 255, 0]
        # Pure blue at (row0,col2).
        @test pix(0, 2) == [0, 0, 255]
        # Gray 0.2 -> N0f8 byte round(0.2*255)=51 at (row1,col0).
        @test pix(1, 0) == [51, 51, 51]
        @test pix(1, 2) == [round(Int, 0.6 * 255), round(Int, 0.6 * 255), round(Int, 0.6 * 255)]

        # End-to-end: builds the Image archetype (ImageBuffer + ImageFormat) and logs.
        rec = RecordingStream("rerun_jl_imagecore_color")
        out = tempname() * ".rrd"
        Rerun.save(rec, out)
        Rerun.set_time(rec, "frame", 0)
        Rerun.log(rec, "rgb", img)
        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end

    @testset "RGBA Image (4 channels, RGBA color model)" begin
        rgba = [RGBA{N0f8}(1.0, 0.0, 0.0, 0.5)  RGBA{N0f8}(0.0, 1.0, 0.0, 1.0)]  # 1x2
        height, width = size(rgba)
        cv  = channelview(rgba)
        @test size(cv, 1) == 4
        raw = ext._to_blob_bytes(ext._hwc_vec(cv))
        @test length(raw) == height * width * 4
        # First pixel: red, alpha 0.5 -> round(0.5*255)=128 (channelview yields R,G,B,A).
        @test Int.(raw[1:4]) == [255, 0, 0, round(Int, 0.5 * 255)]

        rec = RecordingStream("rerun_jl_imagecore_rgba")
        out = tempname() * ".rrd"; Rerun.save(rec, out); Rerun.set_time(rec, "frame", 0)
        Rerun.log(rec, "rgba", rgba); flush(rec)
        @test filesize(out) > 0
    end

    @testset "Gray Matrix -> DepthImage (single channel, no color model)" begin
        g = Gray{N0f8}.([0.1 0.2 0.3; 0.4 0.5 0.6])  # 2x3
        height, width = size(g)
        cv  = channelview(g)
        @test size(cv) == (height, width)             # Gray drops the channel dim
        raw = ext._to_blob_bytes(ext._hwc_vec(cv))
        @test length(raw) == height * width           # 1 byte/pixel
        # Row-major: (h=0,w=0)=0.1, (h=0,w=1)=0.2, ... pins width-fastest ordering.
        @test raw[1] == round(UInt8, 0.1 * 255)
        @test raw[2] == round(UInt8, 0.2 * 255)
        @test raw[width + 1] == round(UInt8, 0.4 * 255)   # (h=1,w=0)

        rec = RecordingStream("rerun_jl_imagecore_gray")
        out = tempname() * ".rrd"; Rerun.save(rec, out); Rerun.set_time(rec, "frame", 0)
        Rerun.log(rec, "gray", g); flush(rec)
        @test filesize(out) > 0
    end

    @testset "Float Matrix -> DepthImage (F32, single channel)" begin
        depth = Float32[0.1 0.2 0.3; 0.4 0.5 0.6]     # 2x3
        height, width = size(depth)
        cv  = channelview(depth)
        @test eltype(cv) === Float32
        raw = ext._to_blob_bytes(ext._hwc_vec(cv))
        @test length(raw) == height * width * sizeof(Float32)
        # Reinterpret back to Float32 in row-major order; (h=0,w=1) must be 0.2.
        f = reinterpret(Float32, raw)
        @test f[1] == 0.1f0
        @test f[2] == 0.2f0                            # width-fastest, not 0.4 (col 0 row 1)
        @test f[width + 1] == 0.4f0                    # (h=1,w=0)

        rec = RecordingStream("rerun_jl_imagecore_depth")
        out = tempname() * ".rrd"; Rerun.save(rec, out); Rerun.set_time(rec, "frame", 0)
        Rerun.log(rec, "depth", depth); flush(rec)
        @test filesize(out) > 0
    end

    @testset "Integer Matrix -> SegmentationImage" begin
        seg = Int32[1 2 3; 4 5 6]                      # 2x3
        height, width = size(seg)
        cv  = channelview(seg)
        @test eltype(cv) === Int32
        raw = ext._to_blob_bytes(ext._hwc_vec(cv))
        @test length(raw) == height * width * sizeof(Int32)
        ids = reinterpret(Int32, raw)
        @test ids[1] == 1
        @test ids[2] == 2                              # (h=0,w=1) width-fastest
        @test ids[width + 1] == 4                      # (h=1,w=0)

        rec = RecordingStream("rerun_jl_imagecore_seg")
        out = tempname() * ".rrd"; Rerun.save(rec, out); Rerun.set_time(rec, "frame", 0)
        Rerun.log(rec, "seg", seg); flush(rec)
        @test filesize(out) > 0
    end
end
