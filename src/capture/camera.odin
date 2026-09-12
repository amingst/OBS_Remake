package capture

import "core:log"
import "base:intrinsics"
import "core:thread"
import "core:sync"
import "base:runtime"
import "../applog"
import "core:sys/windows"
import "libs:mf"
import "core:mem"
import "vendor:directx/d3d11"

Camera_Mailbox :: struct {
	width, height: u32,
	buffer: []u8,
	has_new_frame: bool,
	mutex: sync.Mutex,
}

Camera :: struct {
    symlink:       []u16,
    stop:          b32,
    lost:          b32,
    mailbox:       Camera_Mailbox,
    thread_handle: ^thread.Thread,
    sink:          ^applog.Sink,   // was logger — the thread builds its own Log_Context
    tag_index:     u8,
}

camera_start :: proc(symlink: []u16, sink: ^applog.Sink, tag_index: u8) -> ^Camera {
    cam := new(Camera)
    cam.symlink = make([]u16, len(symlink))
    copy(cam.symlink, symlink)
    cam.sink      = sink
    cam.tag_index = tag_index

    cam.thread_handle = thread.create(camera_thread_proc)
    if cam.thread_handle == nil {
        log.error("camera: thread.create failed")
        delete(cam.symlink)
        free(cam)
        return nil
    }
    cam.thread_handle.data = cam
    thread.start(cam.thread_handle)
    return cam
}

camera_stop :: proc(cam: ^Camera) {
    intrinsics.atomic_store(&cam.stop, b32(true))
    thread.join(cam.thread_handle)
    thread.destroy(cam.thread_handle)
    delete(cam.symlink)
    free(cam)
}

@(private="file")
camera_thread_proc :: proc(t: ^thread.Thread) {
	cam := (^Camera)(t.data)
	source: ^mf.IMFMediaSource
	reader: ^mf.IMFSourceReader
	ok: bool

	defer if source != nil { source->Release() }
	defer if reader != nil { reader->Release() }
	defer if cam.mailbox.buffer != nil { delete(cam.mailbox.buffer) }

    context = runtime.default_context()

    log_ctx := applog.Log_Context{ sink = cam.sink, tag = {.Capture, cam.tag_index} }
    context.logger = applog.make_logger(&log_ctx)

    hr := windows.CoInitializeEx(nil, .MULTITHREADED)
    if hr != 0 {
        log.error("camera: CoInitializeEx failed")
        return
    }
    defer windows.CoUninitialize()

    source, reader, ok = camera_open_reader(cam)
    if !ok {
        log.error("camera: camera_open_reader failed")
        return
    }


    for !intrinsics.atomic_load(&cam.stop) {
        sample: ^mf.IMFSample
        flags:  u32
        hr = reader->ReadSample(mf.MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nil, &flags, nil, &sample)
        if hr < 0 {
            log.errorf("camera: ReadSample failed: 0x%08X", u32(hr))
            continue
        }
        if sample != nil {
            buffer: ^mf.IMFMediaBuffer
            hr = sample->GetBufferByIndex(0, &buffer)
            if hr < 0 || buffer == nil {
                log.errorf("camera: GetBufferByIndex failed: 0x%08X", u32(hr))
                sample->Release()
                break
            }

            ptr: [^]u8
            buf_len: u32
            hr = buffer->Lock(&ptr, nil, &buf_len)
            if hr < 0 {
                log.errorf("camera: Lock failed: 0x%08X", u32(hr))
                buffer->Release()
                sample->Release()
                break
            }

            n := min(int(buf_len), len(cam.mailbox.buffer))
            if int(buf_len) != len(cam.mailbox.buffer) {
                log.warnf("camera: buffer size %d != mailbox %d, clamping", buf_len, len(cam.mailbox.buffer))
            }

            sync.lock(&cam.mailbox.mutex)
            mem.copy(raw_data(cam.mailbox.buffer), ptr, n)
            cam.mailbox.has_new_frame = true
            sync.unlock(&cam.mailbox.mutex)

            buffer->Unlock()
            buffer->Release()
            sample->Release()

            log.debugf("camera: copied frame %dx%d, flags=0x%08X",
                cam.mailbox.width, cam.mailbox.height, flags)
        }
        // STREAMTICK / no frame yet — keep reading
    }
    return
}

@(private="file")
camera_open_reader :: proc(cam: ^Camera) -> (
    source: ^mf.IMFMediaSource,
    reader: ^mf.IMFSourceReader,
    ok: bool,
) {
    dev_attrs:    ^mf.IMFAttributes
    reader_attrs: ^mf.IMFAttributes
    media_type:   ^mf.IMFMediaType
    cur:          ^mf.IMFMediaType

    defer if dev_attrs    != nil { dev_attrs->Release() }
    defer if reader_attrs != nil { reader_attrs->Release() }
    defer if media_type   != nil { media_type->Release() }
    defer if cur          != nil { cur->Release() }
    defer if !ok && reader != nil { reader->Release() }
    defer if !ok && source != nil { source->Shutdown(); source->Release() }

    hr := mf.MFCreateAttributes(&dev_attrs, 2)
    if hr < 0 { log.errorf("camera: MFCreateAttributes (dev) failed: 0x%08X", u32(hr)); return }
    dev_attrs->SetGUID(&mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)
    dev_attrs->SetString(&mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, raw_data(cam.symlink))

    hr = mf.MFCreateDeviceSource(dev_attrs, &source)
    if hr < 0 { log.errorf("camera: MFCreateDeviceSource failed: 0x%08X", u32(hr)); return }

    hr = mf.MFCreateAttributes(&reader_attrs, 1)
    if hr < 0 { log.errorf("camera: MFCreateAttributes (reader) failed: 0x%08X", u32(hr)); return }
    reader_attrs->SetUINT32(&mf.MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1)

    hr = mf.MFCreateSourceReaderFromMediaSource(source, reader_attrs, &reader)
    if hr < 0 { log.errorf("camera: MFCreateSourceReader failed: 0x%08X", u32(hr)); return }

    hr = mf.MFCreateMediaType(&media_type)
    if hr < 0 { log.errorf("camera: MFCreateMediaType failed: 0x%08X", u32(hr)); return }
    media_type->SetGUID(&mf.MF_MT_MAJOR_TYPE, &mf.MFMediaType_Video)
    media_type->SetGUID(&mf.MF_MT_SUBTYPE, &mf.MFVideoFormat_RGB32)

    hr = reader->SetCurrentMediaType(mf.MF_SOURCE_READER_FIRST_VIDEO_STREAM, nil, media_type)
    if hr < 0 { log.errorf("camera: SetCurrentMediaType failed: 0x%08X", u32(hr)); return }

    hr = reader->GetCurrentMediaType(mf.MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur)
    if hr < 0 { log.errorf("camera: GetCurrentMediaType failed: 0x%08X", u32(hr)); return }

    frame_size: u64
    hr = cur->GetUINT64(&mf.MF_MT_FRAME_SIZE, &frame_size)
    if hr < 0 { log.errorf("camera: GetUINT64(FRAME_SIZE) failed: 0x%08X", u32(hr)); return }
    w := u32(frame_size >> 32)
    h := u32(frame_size & 0xFFFFFFFF)
    log.infof("camera: negotiated %dx%d", w, h)

    cam.mailbox.width  = w
    cam.mailbox.height = h
    cam.mailbox.buffer = make([]u8, int(w) * int(h) * 4)

    ok = true
    return
}

next_camera_tag_index :: proc(id: u64) -> u8 {
    return u8(id)
}

camera_upload :: proc(
    cam: ^Camera, device: ^d3d11.IDevice,
    texture: ^^d3d11.ITexture2D, srv: ^^d3d11.IShaderResourceView,
    out_w, out_h: ^u32,
) {
    sync.lock(&cam.mailbox.mutex)
    defer sync.unlock(&cam.mailbox.mutex)

    if !cam.mailbox.has_new_frame {
        return
    }

    if texture^ == nil || out_w^ != cam.mailbox.width || out_h^ != cam.mailbox.height {
        if srv^ != nil {
            srv^->Release()
            srv^ = nil
        }
        if texture^ != nil {
            texture^->Release()
            texture^ = nil
        }

        desc := d3d11.TEXTURE2D_DESC{
            Width          = cam.mailbox.width,
            Height         = cam.mailbox.height,
            MipLevels      = 1,
            ArraySize      = 1,
            Format         = .B8G8R8A8_UNORM,
            SampleDesc     = {Count = 1},
            Usage          = .DYNAMIC,
            BindFlags      = {.SHADER_RESOURCE},
            CPUAccessFlags = {.WRITE},
        }

        new_tex: ^d3d11.ITexture2D
        if hr := device->CreateTexture2D(&desc, nil, &new_tex); hr < 0 {
            log.errorf("camera: CreateTexture2D(%vx%v) failed: 0x%08X", cam.mailbox.width, cam.mailbox.height, u32(hr))
            return
        }

        new_srv: ^d3d11.IShaderResourceView
        if hr := device->CreateShaderResourceView((^d3d11.IResource)(new_tex), nil, &new_srv); hr < 0 {
            log.errorf("camera: CreateShaderResourceView failed: 0x%08X", u32(hr))
            new_tex->Release()
            return
        }

        texture^ = new_tex
        srv^ = new_srv
        out_w^ = cam.mailbox.width
        out_h^ = cam.mailbox.height
    }

    ctx: ^d3d11.IDeviceContext
    device->GetImmediateContext(&ctx)
    defer ctx->Release()

    mapped: d3d11.MAPPED_SUBRESOURCE
    if hr := ctx->Map((^d3d11.IResource)(texture^), 0, .WRITE_DISCARD, {}, &mapped); hr < 0 {
        log.errorf("camera: Map failed: 0x%08X", u32(hr))
        return
    }

    src_pitch := int(cam.mailbox.width) * 4
    dst := ([^]u8)(mapped.pData)
    for y in 0..<int(cam.mailbox.height) {
        src_off := y * src_pitch
        dst_off := y * int(mapped.RowPitch)
        copy(dst[dst_off:dst_off+src_pitch], cam.mailbox.buffer[src_off:src_off+src_pitch])

        // RGB32's fourth byte is undefined padding, not a real alpha channel --
        // the MF video processor leaves it at 0 or garbage. Force it opaque so
        // the premultiplied blend doesn't let the layer below show through.
        for x := 3; x < src_pitch; x += 4 {
            dst[dst_off + x] = 255
        }
    }

    ctx->Unmap((^d3d11.IResource)(texture^), 0)

    cam.mailbox.has_new_frame = false
}
