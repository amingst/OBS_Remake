package mf

import "core:sys/windows"

// ---------------------------------------------------------------------
// IMFMediaType : IMFAttributes : IUnknown
// vtable = IUnknown(3) + IMFAttributes(30) + IMFMediaType-own(5) = 38 slots
// ---------------------------------------------------------------------

IMFMediaType_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFMediaType, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFMediaType) -> u32,
    Release:        proc "stdcall" (this: ^IMFMediaType) -> u32,

    // IMFAttributes block — order matters, only Set{UINT32,UINT64,GUID} are typed
    GetItem:            rawptr,
    GetItemType:        rawptr,
    CompareItem:        rawptr,
    Compare:            rawptr,
    GetUINT32_:         rawptr,
    GetUINT64_:         rawptr,
    GetDouble:          rawptr,
    GetGUID_:           rawptr,
    GetStringLength:    rawptr,
    GetString:          rawptr,
    GetAllocatedString: rawptr,
    GetBlobSize:        rawptr,
    GetBlob:            rawptr,
    GetAllocatedBlob:   rawptr,
    GetUnknown:         rawptr,
    SetItem:            rawptr,
    DeleteItem:         rawptr,
    DeleteAllItems:     rawptr,
    SetUINT32: proc "stdcall" (this: ^IMFMediaType, key: ^windows.GUID, value: u32) -> windows.HRESULT,
    SetUINT64: proc "stdcall" (this: ^IMFMediaType, key: ^windows.GUID, value: u64) -> windows.HRESULT,
    SetDouble:          rawptr,
    SetGUID: proc "stdcall" (this: ^IMFMediaType, key: ^windows.GUID, value: ^windows.GUID) -> windows.HRESULT,
    SetString:          rawptr,
    SetBlob:            rawptr,
    SetUnknown:         rawptr,
    LockStore:          rawptr,
    UnlockStore:        rawptr,
    GetCount:           rawptr,
    GetItemByIndex:     rawptr,
    CopyAllItems:       rawptr,

    // IMFMediaType-own
    GetMajorType:       rawptr,
    IsCompressedFormat: rawptr,
    IsEqual:            rawptr,
    GetRepresentation:  rawptr,
    FreeRepresentation: rawptr,
}

IMFMediaType :: struct { using vtbl: ^IMFMediaType_VTable }

// ---------------------------------------------------------------------
// IMFSinkWriter : IUnknown  (14 slots)
// ---------------------------------------------------------------------

IMFSinkWriter_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFSinkWriter, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFSinkWriter) -> u32,
    Release:        proc "stdcall" (this: ^IMFSinkWriter) -> u32,

    AddStream: proc "stdcall" (this: ^IMFSinkWriter, target_type: ^IMFMediaType, stream_index: ^u32) -> windows.HRESULT,
    SetInputMediaType: proc "stdcall" (this: ^IMFSinkWriter, stream_index: u32, input_type: ^IMFMediaType, encoding_params: rawptr) -> windows.HRESULT,
    BeginWriting: proc "stdcall" (this: ^IMFSinkWriter) -> windows.HRESULT,
    WriteSample: proc "stdcall" (this: ^IMFSinkWriter, stream_index: u32, sample: ^IMFSample) -> windows.HRESULT,
    SendStreamTick:      rawptr,
    PlaceMarker:         rawptr,
    NotifyEndOfSegment:  rawptr,
    Flush:               rawptr,
    Finalize: proc "stdcall" (this: ^IMFSinkWriter) -> windows.HRESULT,
    GetServiceForStream: rawptr,
    GetStatistics:       rawptr,
}

IMFSinkWriter :: struct { using vtbl: ^IMFSinkWriter_VTable }

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
    GetBufferByIndex:  rawptr,
    ConvertToContiguousBuffer: rawptr,
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
    GetCurrentLength: rawptr,
    SetCurrentLength: proc "stdcall" (this: ^IMFMediaBuffer, length: u32) -> windows.HRESULT,
    GetMaxLength:     rawptr,
}

IMFMediaBuffer :: struct { using vtbl: ^IMFMediaBuffer_VTable }