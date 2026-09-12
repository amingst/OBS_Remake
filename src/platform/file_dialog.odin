package platform

import "core:sys/windows"
import "core:log"

OPENFILENAMEW :: struct {
	lStructSize:       u32,
	hwndOwner:         windows.HWND,
	hInstance:          windows.HINSTANCE,
	lpstrFilter:       [^]u16,
	lpstrCustomFilter: [^]u16,
	nMaxCustFilter:    u32,
	nFilterIndex:      u32,
	lpstrFile:         [^]u16,
	nMaxFile:          u32,
	lpstrFileTitle:    [^]u16,
	nMaxFileTitle:     u32,
	lpstrInitialDir:   [^]u16,
	lpstrTitle:        [^]u16,
	Flags:             u32,
	nFileOffset:       u16,
	nFileExtension:    u16,
	lpstrDefExt:       [^]u16,
	lCustData:         uintptr,
	lpfnHook:          rawptr,
	lpTemplateName:    [^]u16,
	pvReserved:        rawptr,
	dwReserved:        u32,
	FlagsEx:           u32,
}

OFN_FILEMUSTEXIST :: 0x00001000
OFN_PATHMUSTEXIST :: 0x00000800
OFN_NOCHANGEDIR   :: 0x00000008

foreign import comdlg32 "system:comdlg32.lib"

@(default_calling_convention = "stdcall")
foreign comdlg32 {
	GetOpenFileNameW     :: proc(ofn: ^OPENFILENAMEW) -> windows.BOOL ---
	CommDlgExtendedError :: proc() -> u32 ---
}

// Opens a native file-open dialog filtered to common image types.
// Returns a UTF-8 path allocated from context.allocator on success.
// Cancel is not an error — returns ("", false) silently.
open_image_dialog :: proc() -> (path: string, ok: bool) {
	buf: [260]u16 // MAX_PATH

	// Double-null-terminated filter: each pair is "description\0pattern\0",
	// with a final \0 to end the list.
	filter := [?]u16{
		'I','m','a','g','e',' ','F','i','l','e','s', 0,
		'*','.','p','n','g',';',
		'*','.','j','p','g',';',
		'*','.','j','p','e','g',';',
		'*','.','b','m','p',';',
		'*','.','g','i','f',';',
		'*','.','t','i','f','f', 0,
		'A','l','l',' ','F','i','l','e','s', 0,
		'*','.','*', 0,
		0,
	}

	ofn := OPENFILENAMEW{
		lStructSize = size_of(OPENFILENAMEW),
		lpstrFilter = &filter[0],
		lpstrFile   = &buf[0],
		nMaxFile    = len(buf),
		Flags       = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR,
	}

	if !GetOpenFileNameW(&ofn) {
		err := CommDlgExtendedError()
		if err != 0 {
			log.errorf("GetOpenFileNameW failed: 0x%08X", err)
		}
		return "", false
	}

	n := 0
	for n < len(buf) && buf[n] != 0 {
		n += 1
	}

	result, alloc_err := windows.wstring_to_utf8_alloc(windows.wstring(raw_data(buf[:])), n, context.allocator)
	if alloc_err != nil {
		log.error("wstring_to_utf8 allocation failed")
		return "", false
	}
	return result, true
}
