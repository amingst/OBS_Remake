package mf

import "core:sys/windows"

// Shared IMFAttributes method block. Parameterized on T so `this` is correctly typed
// per concrete interface (IMFMediaType, IMFSample, IMFActivate all inherit
// IMFAttributes) — same reasoning as why QueryInterface/AddRef/Release are spelled
// out per-interface rather than shared via a generic IUnknown vtable.
IMFAttributes_VTable :: struct($T: typeid) {
    GetItem:            rawptr,
    GetItemType:        rawptr,
    CompareItem:        rawptr,
    Compare:            rawptr,
    GetUINT32: proc "stdcall" (this: ^T, key: ^windows.GUID, value: ^u32) -> windows.HRESULT,
    GetUINT64: proc "stdcall" (this: ^T, key: ^windows.GUID, value: ^u64) -> windows.HRESULT,
    GetDouble:          rawptr,
    GetGUID_:           rawptr,
    GetStringLength:    rawptr,
    GetString:          rawptr,
    //GetAllocatedString: proc "stdcall" (this: ^T, key: ^windows.GUID, value: ^cstring16, length: ^u32) -> windows.HRESULT,
    GetAllocatedString: proc "stdcall" (this: ^T, key: ^windows.GUID, value: ^[^]u16, length: ^u32) -> windows.HRESULT,
    GetBlobSize: proc "stdcall" (this: ^T, key: ^windows.GUID, size: ^u32) -> windows.HRESULT,
    GetBlob: proc "stdcall" (this: ^T, key: ^windows.GUID, buf: [^]u8, buf_size: u32, blob_size: ^u32) -> windows.HRESULT,
    GetAllocatedBlob:   rawptr,
    GetUnknown:         rawptr,
    SetItem:            rawptr,
    DeleteItem:         rawptr,
    DeleteAllItems:     rawptr,
    SetUINT32: proc "stdcall" (this: ^T, key: ^windows.GUID, value: u32) -> windows.HRESULT,
    SetUINT64: proc "stdcall" (this: ^T, key: ^windows.GUID, value: u64) -> windows.HRESULT,
    SetDouble:          rawptr,
    SetGUID: proc "stdcall" (this: ^T, key: ^windows.GUID, value: ^windows.GUID) -> windows.HRESULT,
    SetString: proc "stdcall" (this: ^T, key: ^windows.GUID, value: ^u16) -> windows.HRESULT,
    SetBlob:            rawptr,
    SetUnknown:         rawptr,
    LockStore:          rawptr,
    UnlockStore:        rawptr,
    GetCount:           rawptr,
    GetItemByIndex:     rawptr,
    CopyAllItems:       rawptr,
}

IMFAttributes_Full_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFAttributes, riid: ^windows.GUID, out: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFAttributes) -> u32,
    Release:        proc "stdcall" (this: ^IMFAttributes) -> u32,
    using attrs:    IMFAttributes_VTable(IMFAttributes),   // GetItem @ slot 3, correct
}
IMFAttributes :: struct { using vtbl: ^IMFAttributes_Full_VTable }

IMFMediaSource_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFMediaSource, riid: ^windows.GUID, out: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFMediaSource) -> u32,
    Release:        proc "stdcall" (this: ^IMFMediaSource) -> u32,
    // IMFMediaEventGenerator
    GetEvent:       rawptr,
    BeginGetEvent:  rawptr,
    EndGetEvent:    rawptr,
    QueueEvent:     rawptr,
    // IMFMediaSource
    GetCharacteristics:            rawptr,
    CreatePresentationDescriptor:  rawptr,
    Start:          rawptr,
    Stop:           rawptr,
    Pause:          rawptr,
    Shutdown:       proc "stdcall" (this: ^IMFMediaSource) -> windows.HRESULT,
}
IMFMediaSource :: struct { using vtbl: ^IMFMediaSource_VTable }

// ---------------------------------------------------------------------
// IMFMediaType : IMFAttributes : IUnknown
// vtable = IUnknown(3) + IMFAttributes(30) + IMFMediaType-own(5) = 38 slots
// ---------------------------------------------------------------------

IMFMediaType_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFMediaType, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFMediaType) -> u32,
    Release:        proc "stdcall" (this: ^IMFMediaType) -> u32,

    using attrs: IMFAttributes_VTable(IMFMediaType),

    GetMajorType:       rawptr,
    IsCompressedFormat: rawptr,
    IsEqual:            rawptr,
    GetRepresentation:  rawptr,
    FreeRepresentation: rawptr,
}

IMFMediaType :: struct { using vtbl: ^IMFMediaType_VTable }

// ---------------------------------------------------------------------
// IMFSample : IMFAttributes : IUnknown  (3 + 30 + 14 = 47 slots)
// ---------------------------------------------------------------------

IMFSample_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFSample, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFSample) -> u32,
    Release:        proc "stdcall" (this: ^IMFSample) -> u32,

    // IMFAttributes block — unused here, all placeholders
    GetItem: rawptr, GetItemType: rawptr, CompareItem: rawptr, Compare: rawptr,
    GetUINT32_: rawptr, GetUINT64_: rawptr, GetDouble: rawptr, GetGUID_: rawptr,
    GetStringLength: rawptr, GetString: rawptr, GetAllocatedString: rawptr,
    GetBlobSize: rawptr, GetBlob: rawptr, GetAllocatedBlob: rawptr, GetUnknown: rawptr,
    SetItem: rawptr, DeleteItem: rawptr, DeleteAllItems: rawptr,
    SetUINT32_: rawptr, SetUINT64_: rawptr, SetDouble: rawptr, SetGUID_: rawptr,
    SetString: rawptr, SetBlob: rawptr, SetUnknown: rawptr,
    LockStore: rawptr, UnlockStore: rawptr, GetCount: rawptr, GetItemByIndex: rawptr,
    CopyAllItems: rawptr,

    // IMFSample-own
    GetSampleFlags:    rawptr,
    SetSampleFlags:    rawptr,
    GetSampleTime:     rawptr,
    SetSampleTime: proc "stdcall" (this: ^IMFSample, sample_time: i64) -> windows.HRESULT,
    GetSampleDuration: rawptr,
    SetSampleDuration: proc "stdcall" (this: ^IMFSample, duration: i64) -> windows.HRESULT,
    GetBufferCount:    rawptr,
    GetBufferByIndex: proc "stdcall" (this: ^IMFSample, index: u32, buffer: ^^IMFMediaBuffer) -> windows.HRESULT,
    ConvertToContiguousBuffer: proc "stdcall" (this: ^IMFSample, buffer: ^^IMFMediaBuffer) -> windows.HRESULT,
    AddBuffer: proc "stdcall" (this: ^IMFSample, buffer: ^IMFMediaBuffer) -> windows.HRESULT,
    RemoveBufferByIndex: rawptr,
    RemoveAllBuffers:    rawptr,
    GetTotalLength:      rawptr,
    CopyToBuffer:        rawptr,
}

IMFSample :: struct { using vtbl: ^IMFSample_VTable }

// ---------------------------------------------------------------------
// IMFMediaBuffer : IUnknown  (8 slots)
// ---------------------------------------------------------------------

IMFMediaBuffer_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFMediaBuffer, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFMediaBuffer) -> u32,
    Release:        proc "stdcall" (this: ^IMFMediaBuffer) -> u32,

        Lock: proc "stdcall" (this: ^IMFMediaBuffer, buffer: ^[^]u8, max_length: ^u32, current_length: ^u32) -> windows.HRESULT,
    Unlock: proc "stdcall" (this: ^IMFMediaBuffer) -> windows.HRESULT,
    GetCurrentLength: proc "stdcall" (this: ^IMFMediaBuffer, length: ^u32) -> windows.HRESULT,
    SetCurrentLength: proc "stdcall" (this: ^IMFMediaBuffer, length: u32) -> windows.HRESULT,
    GetMaxLength:     rawptr,
}

IMFMediaBuffer :: struct { using vtbl: ^IMFMediaBuffer_VTable }

MFT_REGISTER_TYPE_INFO :: struct {
    major_type: windows.GUID,
    subtype:    windows.GUID,
}

IMFActivate_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFActivate, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFActivate) -> u32,
    Release:        proc "stdcall" (this: ^IMFActivate) -> u32,

    using attrs: IMFAttributes_VTable(IMFActivate),

    ActivateObject: proc "stdcall" (this: ^IMFActivate, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    ShutdownObject: proc "stdcall" (this: ^IMFActivate) -> windows.HRESULT,
    DetachObject:   proc "stdcall" (this: ^IMFActivate) -> windows.HRESULT,
}

IMFActivate :: struct { using vtbl: ^IMFActivate_VTable }

MFT_INPUT_STREAM_INFO :: struct {
    hnsMaxLatency:   i64,
    dwFlags:         u32,
    cbSize:          u32,
    cbMaxLookahead:  u32,
    cbAlignment:     u32,
}

MFT_OUTPUT_STREAM_INFO :: struct {
    dwFlags:     u32,
    cbSize:      u32,
    cbAlignment: u32,
}

MFT_OUTPUT_DATA_BUFFER :: struct {
    dwStreamID: u32,
    pSample:    ^IMFSample,
    dwStatus:   u32,
    pEvents:    rawptr, // IMFCollection* - unused, never typed this interface
}

IMFTransform_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFTransform, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFTransform) -> u32,
    Release:        proc "stdcall" (this: ^IMFTransform) -> u32,

    GetStreamLimits: rawptr,
    GetStreamCount:  rawptr,
    GetStreamIDs:    rawptr,
    GetInputStreamInfo: proc "stdcall" (this: ^IMFTransform, stream_id: u32, info: ^MFT_INPUT_STREAM_INFO) -> windows.HRESULT,
    GetOutputStreamInfo: proc "stdcall" (this: ^IMFTransform, stream_id: u32, info: ^MFT_OUTPUT_STREAM_INFO) -> windows.HRESULT,
    GetAttributes:       rawptr,
    GetInputStreamAttributes:  rawptr,
    GetOutputStreamAttributes: rawptr,
    DeleteInputStream: rawptr,
    AddInputStreams:   rawptr,
    GetInputAvailableType:  rawptr,
    GetOutputAvailableType: rawptr,
    SetInputType: proc "stdcall" (this: ^IMFTransform, stream_id: u32, media_type: ^IMFMediaType, flags: u32) -> windows.HRESULT,
    SetOutputType: proc "stdcall" (this: ^IMFTransform, stream_id: u32, media_type: ^IMFMediaType, flags: u32) -> windows.HRESULT,
    GetInputCurrentType:  rawptr,
    GetOutputCurrentType: proc "stdcall" (this: ^IMFTransform, stream_id: u32, media_type: ^^IMFMediaType) -> windows.HRESULT,
    GetInputStatus:  rawptr,
    GetOutputStatus: rawptr,
    SetOutputBounds: rawptr,
    ProcessEvent:    rawptr,
    ProcessMessage: proc "stdcall" (this: ^IMFTransform, message: u32, param: uint) -> windows.HRESULT,
    ProcessInput: proc "stdcall" (this: ^IMFTransform, stream_id: u32, sample: ^IMFSample, flags: u32) -> windows.HRESULT,
    ProcessOutput: proc "stdcall" (this: ^IMFTransform, flags: u32, count: u32, samples: ^MFT_OUTPUT_DATA_BUFFER, status: ^u32) -> windows.HRESULT,
}

IMFTransform :: struct { using vtbl: ^IMFTransform_VTable }

// ---------------------------------------------------------------------
// ICodecAPI : IUnknown  (3 + 15 = 18 slots)
// Only SetValue is typed — the rest are placeholders.
// ---------------------------------------------------------------------

VARIANT :: struct {
    vt:        u16,
    _reserved: [3]u16,
    val:       u64, // overlaid union; we only ever store a u32 (VT_UI4)
}

ICodecAPI_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^ICodecAPI, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^ICodecAPI) -> u32,
    Release:        proc "stdcall" (this: ^ICodecAPI) -> u32,

    IsSupported:       rawptr,
    IsModifiable:      rawptr,
    GetParameterRange: rawptr,
    GetParameterValues: rawptr,
    GetDefaultValue:   rawptr,
    GetValue:          rawptr,
    SetValue: proc "stdcall" (this: ^ICodecAPI, api: ^windows.GUID, value: ^VARIANT) -> windows.HRESULT,
}

ICodecAPI :: struct { using vtbl: ^ICodecAPI_VTable }

IMFSourceReader_VTable :: struct {
    QueryInterface:          proc "stdcall" (this: ^IMFSourceReader, riid: ^windows.GUID, out: ^rawptr) -> windows.HRESULT,
    AddRef:                  proc "stdcall" (this: ^IMFSourceReader) -> u32,
    Release:                 proc "stdcall" (this: ^IMFSourceReader) -> u32,
    GetStreamSelection:      rawptr,
    SetStreamSelection:      rawptr,
    GetNativeMediaType:      rawptr,
    GetCurrentMediaType:     proc "stdcall" (this: ^IMFSourceReader, stream_index: u32, media_type: ^^IMFMediaType) -> windows.HRESULT,
    SetCurrentMediaType:     proc "stdcall" (this: ^IMFSourceReader, stream_index: u32, reserved: ^u32, media_type: ^IMFMediaType) -> windows.HRESULT,
    SetCurrentPosition:      rawptr,
    ReadSample:              proc "stdcall" (this: ^IMFSourceReader, stream_index: u32, control_flags: u32, actual_stream_index: ^u32, stream_flags: ^u32, timestamp: ^windows.LONGLONG, sample: ^^IMFSample) -> windows.HRESULT,
    Flush:                   rawptr,
    GetServiceForStream:     rawptr,
    GetPresentationAttribute: rawptr,
}

IMFSourceReader :: struct { using vtbl: ^IMFSourceReader_VTable }
