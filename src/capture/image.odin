package capture

import "libs:wic"
import "vendor:directx/d3d11"
import "core:sys/windows"
import "core:log"

MAX_IMAGE_DIMENSION :: 16384

load_image :: proc(device: ^d3d11.IDevice, path: string) -> (texture: ^d3d11.ITexture2D, srv: ^d3d11.IShaderResourceView, width: u32, height: u32, ok: bool) {
	if wic.factory == nil {
		log.error("load_image called with no WIC factory")
		return nil, nil, 0, 0, false
	}

	wpath := windows.utf8_to_wstring(path)
	decoder: ^wic.IWICBitmapDecoder
	GENERIC_READ :: 0x8000_0000
	hr := wic.factory->CreateDecoderFromFilename(wpath, nil, GENERIC_READ, .MetadataCacheOnDemand, &decoder)
	if hr != windows.S_OK {
		log.errorf("CreateDecoderFromFilename(%s) failed: 0x%08X", path, u32(hr))
		return nil, nil, 0, 0, false
	}
	defer decoder->Release()

	frame: ^wic.IWICBitmapFrameDecode
	hr = decoder->GetFrame(0, &frame)
	if hr != windows.S_OK {
		log.errorf("GetFrame(%s) failed: 0x%08X", path, u32(hr))
		return nil, nil, 0, 0, false
	}
	defer frame->Release()

	hr = frame->GetSize(&width, &height)
	if hr != windows.S_OK {
		log.errorf("GetSize(%s) failed: 0x%08X", path, u32(hr))
		return nil, nil, 0, 0, false
	}

	if width == 0 || height == 0 || width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION {
		log.errorf("load_image(%s): dimensions out of range: %dx%d", path, width, height)
		return nil, nil, 0, 0, false
	}

	conv: ^wic.IWICFormatConverter
	hr = wic.factory->CreateFormatConverter(&conv)
	if hr != windows.S_OK {
		log.errorf("CreateFormatConverter failed: 0x%08X", u32(hr))
		return nil, nil, 0, 0, false
	}
	defer conv->Release()

	hr = conv->Initialize(frame, &wic.GUID_WICPixelFormat32bppPBGRA, .None, nil, 0.0, .Custom)
	if hr != windows.S_OK {
		log.errorf("Initialize failed: 0x%08X", u32(hr))
		return nil, nil, 0, 0, false
	}

	stride := width * 4
	buf_size := stride * height
	buf := make([]u8, buf_size)
	defer delete(buf)

	hr = conv->CopyPixels(nil, stride, buf_size, raw_data(buf))
	if hr != windows.S_OK {
		log.errorf("CopyPixels failed: 0x%08X", u32(hr))
		return nil, nil, 0, 0, false
	}

	desc := d3d11.TEXTURE2D_DESC{
		Width      = width,
		Height     = height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .B8G8R8A8_UNORM,
		SampleDesc = {Count = 1},
		Usage      = .IMMUTABLE,
		BindFlags  = {.SHADER_RESOURCE},
	}
	data := d3d11.SUBRESOURCE_DATA{ pSysMem = raw_data(buf), SysMemPitch = stride }
	hr = device->CreateTexture2D(&desc, &data, &texture)
	if hr != windows.S_OK {
		log.errorf("CreateTexture2D failed: 0x%08X", u32(hr))
		return nil, nil, 0, 0, false
	}

	hr = device->CreateShaderResourceView((^d3d11.IResource)(texture), nil, &srv)
	if hr != windows.S_OK {
		log.errorf("CreateShaderResourceView failed: 0x%08X", u32(hr))
		texture->Release()
		return nil, nil, 0, 0, false
	}

	return texture, srv, width, height, true
}
