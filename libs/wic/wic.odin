package wic

import "core:sys/windows"
import "core:log"
// --- CLSID ---
CLSID_WICImagingFactory := windows.GUID{0x317d06e8, 0x5f24, 0x433d, {0xbd, 0xf7, 0x79, 0xce, 0x68, 0xd8, 0xab, 0xc2}}

// --- IID ---
IID_IWICImagingFactory := windows.GUID{
    0xec5ec8a9, 0xc395, 0x4314,
    {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70},
}

// --- GUID ---
GUID_WICPixelFormat32bppPBGRA := windows.GUID{0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10}}

WICRect :: struct {
	X: i32,
	Y: i32,
	Width: i32,
	Height: i32,
}

IWICBitmapSource_VTable :: struct($T: typeid) {
    GetSize: proc "stdcall" (this: ^T, puiWidth, puiHeight: ^u32) -> windows.HRESULT,
    GetPixelFormat: proc "stdcall" (this: ^T, pPixelFormat: ^windows.GUID) -> windows.HRESULT,
    GetResolution: rawptr,
    CopyPalette:   rawptr,
    CopyPixels: proc "stdcall" (this: ^T, prc: ^WICRect, cbStride: u32, cbBufferSize: u32, pbBuffer: [^]u8) -> windows.HRESULT,
}

// IWICBitmapFrameDecode : IWICBitmapSource : IUnknown
// vtable = IUnknown(3) + IWICBitmapSource(5) + own(3) = 11 slots
IWICBitmapFrameDecode_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IWICBitmapFrameDecode, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IWICBitmapFrameDecode) -> u32,
    Release:        proc "stdcall" (this: ^IWICBitmapFrameDecode) -> u32,

    using src: IWICBitmapSource_VTable(IWICBitmapFrameDecode),

    GetMetadataQueryReader: rawptr,
    GetColorContexts:       rawptr,
    GetThumbnail:           rawptr,
}

IWICBitmapFrameDecode :: struct { using vtbl: ^IWICBitmapFrameDecode_VTable }

WICBitmapDitherType :: enum i32 {
    None           = 0,
    Ordered4x4     = 0x1,
    Ordered8x8     = 0x2,
    Ordered16x16   = 0x3,
    Spiral4x4      = 0x4,
    Spiral8x8      = 0x5,
    DualSpiral4x4  = 0x6,
    DualSpiral8x8  = 0x7,
    ErrorDiffusion = 0x8,
}

WICBitmapPaletteType :: enum i32 {
    Custom      = 0,
    MedianCut   = 0x1,
    FixedBW 	= 0x2,
    FixedHalftone8 = 0x3,
    FixedHalftone27 = 0x4,
    FixedHalftone64 = 0x5,
    FixedHalftone125 = 0x6,
    FixedHalftone216 = 0x7,
    FixedHalftone252 = 0x8,
    FixedHalftone256 = 0x9,
    FixedGray4  = 0xa,
    FixedGray16 = 0xb,
    FixedGray256 = 0xc,
}

WICDecodeOptions :: enum i32 {
    MetadataCacheOnDemand = 0,
    MetadataCacheOnLoad   = 0x1,
}

// IWICFormatConverter : IWICBitmapSource : IUnknown
// vtable = IUnknown(3) + IWICBitmapSource(5) + own(2) = 10 slots
IWICFormatConverter_VTable :: struct {
	QueryInterface: proc "stdcall" (this: ^IWICFormatConverter, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IWICFormatConverter) -> u32,
    Release:        proc "stdcall" (this: ^IWICFormatConverter) -> u32,

    using src: IWICBitmapSource_VTable(IWICFormatConverter),

	Initialize: proc "stdcall" (
    this: ^IWICFormatConverter,
    pISource: ^IWICBitmapFrameDecode,
    dstFormat: ^windows.GUID,
    dither: WICBitmapDitherType,
    pIPalette: rawptr,
    alphaThresholdPercent: f64,
    paletteTranslate: WICBitmapPaletteType,
	) -> windows.HRESULT,
	CanConvert: rawptr,
}

IWICFormatConverter :: struct { using vtbl: ^IWICFormatConverter_VTable }

// IWICBitmapDecoder : IUnknown  (3 + 11 = 14 slots)
IWICBitmapDecoder_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IWICBitmapDecoder, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IWICBitmapDecoder) -> u32,
    Release:        proc "stdcall" (this: ^IWICBitmapDecoder) -> u32,

    QueryCapability:        rawptr,
    Initialize:             rawptr,
    GetContainerFormat:     rawptr,
    GetDecoderInfo:         rawptr,
    CopyPalette:            rawptr,
    GetMetadataQueryReader: rawptr,
    GetPreview:             rawptr,
    GetColorContexts:       rawptr,
    GetThumbnail:           rawptr,
    GetFrameCount:          rawptr,
    GetFrame: proc "stdcall" (this: ^IWICBitmapDecoder, index: u32, ppIBitmapFrame: ^^IWICBitmapFrameDecode) -> windows.HRESULT,
}

IWICBitmapDecoder :: struct { using vtbl: ^IWICBitmapDecoder_VTable }

// IWICImagingFactory : IUnknown  (3 + 25 = 28 slots)
IWICImagingFactory_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IWICImagingFactory, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IWICImagingFactory) -> u32,
    Release:        proc "stdcall" (this: ^IWICImagingFactory) -> u32,

    CreateDecoderFromFilename: proc "stdcall" (
        this: ^IWICImagingFactory,
        wzFilename: windows.wstring,
        pguidVendor: ^windows.GUID,
        dwDesiredAccess: u32,
        metadataOptions: WICDecodeOptions,
        ppIDecoder: ^^IWICBitmapDecoder,
    ) -> windows.HRESULT,

    CreateDecoderFromStream:     rawptr,
    CreateDecoderFromFileHandle: rawptr,
    CreateComponentInfo:         rawptr,
    CreateDecoder:               rawptr,
    CreateEncoder:               rawptr,
    CreatePalette:               rawptr,

    CreateFormatConverter: proc "stdcall" (
        this: ^IWICImagingFactory,
        ppIFormatConverter: ^^IWICFormatConverter,
    ) -> windows.HRESULT,

    CreateBitmapScaler:                       rawptr,
    CreateBitmapClipper:                      rawptr,
    CreateBitmapFlipRotator:                  rawptr,
    CreateStream:                             rawptr,
    CreateColorContext:                       rawptr,
    CreateColorTransformer:                   rawptr,
    CreateBitmap:                             rawptr,
    CreateBitmapFromSource:                   rawptr,
    CreateBitmapFromSourceRect:               rawptr,
    CreateBitmapFromMemory:                   rawptr,
    CreateBitmapFromHBITMAP:                  rawptr,
    CreateBitmapFromHICON:                    rawptr,
    CreateComponentEnumerator:                rawptr,
    CreateFastMetadataEncoderFromDecoder:     rawptr,
    CreateFastMetadataEncoderFromFrameDecode: rawptr,
    CreateQueryWriter:                        rawptr,
    CreateQueryWriterFromReader:              rawptr,
}

IWICImagingFactory :: struct { using vtbl: ^IWICImagingFactory_VTable }

factory: ^IWICImagingFactory

wic_init :: proc() -> bool {
	CLSCTX_INPROC_SERVER :: 0x1
	hr := windows.CoCreateInstance(
		&CLSID_WICImagingFactory,
		nil,
		CLSCTX_INPROC_SERVER,
		&IID_IWICImagingFactory,
		cast(^rawptr)&factory)
	if hr != windows.S_OK {
		log.errorf("Failed to create WIC Imaging Factory: %d", hr)
		return false
	}

	return true
}

wic_shutdown :: proc() {
    if factory != nil {
        factory->Release()
        factory = nil
    }
}
