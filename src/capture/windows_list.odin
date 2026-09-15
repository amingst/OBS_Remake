package capture

import "base:runtime"
import "core:strings"
import win32 "core:sys/windows"

// QueryFullProcessImageNameW isn't bound by core:sys/windows.
foreign import kernel32_proc "system:kernel32.lib"
@(default_calling_convention = "stdcall")
foreign kernel32_proc {
	QueryFullProcessImageNameW :: proc(hProcess: win32.HANDLE, dwFlags: u32, lpExeName: win32.LPWSTR, lpdwSize: ^u32) -> win32.BOOL ---
}

Window_Info :: struct {
	hwnd:        win32.HWND,
	title:       string,
	class_name:  string,
	exe_name:    string, // "" if it couldn't be determined (elevated process, etc.) -- not an error
	likely_game: bool,   // borderless or fullscreen-sized -- see is_likely_game
}

// Lists candidate capture-target windows. Call on picker-open, not per frame;
// free the result with destroy_window_list.
enumerate_windows :: proc() -> []Window_Info {
	ectx: Enum_Ctx
	ectx.list = make([dynamic]Window_Info)
	ectx.ctx = context
	win32.EnumWindows(enum_windows_proc, win32.LPARAM(uintptr(rawptr(&ectx))))
	return ectx.list[:]
}

destroy_window_list :: proc(list: []Window_Info) {
	for w in list {
		delete(w.title)
		delete(w.class_name)
		delete(w.exe_name)
	}
	delete(list)
}

@(private = "file")
Enum_Ctx :: struct {
	list: [dynamic]Window_Info,
	ctx:  runtime.Context, // captured so the "system"-convention callback uses the caller's context
}

@(private = "file")
enum_windows_proc :: proc "system" (hwnd: win32.HWND, lparam: win32.LPARAM) -> win32.BOOL {
	ectx := (^Enum_Ctx)(rawptr(uintptr(lparam)))
	context = ectx.ctx

	if !win32.IsWindowVisible(hwnd) do return true

	// Skip windows with no title -- FindWindowW(nil, "") can match one.
	title_len := win32.GetWindowTextLengthW(hwnd)
	if title_len <= 0 do return true

	ex_style := win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE)
	if u32(ex_style) & win32.WS_EX_TOOLWINDOW != 0 do return true

	// Without this, every suspended UWP app appears in the list.
	cloaked: u32
	if hr := win32.DwmGetWindowAttribute(
		hwnd, u32(win32.DWMWINDOWATTRIBUTE.DWMWA_CLOAKED), &cloaked, size_of(cloaked),
	); hr >= 0 && cloaked != 0 {
		return true
	}

	title_buf := make([]u16, title_len + 1, context.temp_allocator)
	tn := win32.GetWindowTextW(hwnd, raw_data(title_buf), i32(len(title_buf)))
	if tn <= 0 do return true
	title, terr := win32.utf16_to_utf8(title_buf[:tn], context.allocator)
	if terr != nil do return true

	class_name := get_class_name(hwnd, context.allocator)
	exe_name := get_exe_basename(hwnd, context.allocator)

	append(&ectx.list, Window_Info{
		hwnd        = hwnd,
		title       = title,
		class_name  = class_name,
		exe_name    = exe_name,
		likely_game = is_likely_game(hwnd),
	})

	return true
}

@(private = "file")
get_class_name :: proc(hwnd: win32.HWND, allocator: runtime.Allocator) -> string {
	class_buf: [256]u16
	cn := win32.GetClassNameW(hwnd, raw_data(class_buf[:]), i32(len(class_buf)))
	if cn <= 0 do return ""
	name, err := win32.utf16_to_utf8(class_buf[:cn], allocator)
	if err != nil do return ""
	return name
}

// Returns "" on any failure (e.g. an elevated process we can't query) -- not an error.
@(private = "file")
get_exe_basename :: proc(hwnd: win32.HWND, allocator: runtime.Allocator) -> string {
	pid: win32.DWORD
	win32.GetWindowThreadProcessId(hwnd, &pid)
	if pid == 0 do return ""

	proc_handle := win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if proc_handle == nil do return ""
	defer win32.CloseHandle(proc_handle)

	path_buf: [win32.MAX_PATH]u16
	path_len := u32(len(path_buf))
	if !QueryFullProcessImageNameW(proc_handle, 0, raw_data(path_buf[:]), &path_len) do return ""

	full_path, perr := win32.utf16_to_utf8(path_buf[:path_len], context.temp_allocator)
	if perr != nil do return ""

	base := full_path
	if idx := strings.last_index_byte(full_path, '\\'); idx >= 0 {
		base = full_path[idx + 1:]
	}
	return strings.clone(base, allocator)
}

// Resolves a persisted window identity to a live hwnd: exact title+class+exe
// match first, then class+exe alone (handles a title that changes with the
// open file), else unresolved. Empty class_name falls back to title-only
// FindWindowW for sources persisted before class/exe tracking existed.
resolve_window :: proc(title, class_name, exe_name: string) -> (hwnd: win32.HWND, ok: bool) {
	if class_name == "" {
		h := win32.FindWindowW(nil, win32.utf8_to_wstring(title))
		return h, h != nil
	}

	rctx: Resolve_Ctx
	rctx.ctx        = context
	rctx.title      = title
	rctx.class_name = class_name
	rctx.exe_name   = exe_name
	win32.EnumWindows(resolve_enum_proc, win32.LPARAM(uintptr(rawptr(&rctx))))

	if rctx.exact_match != nil do return rctx.exact_match, true
	if rctx.class_exe_match != nil do return rctx.class_exe_match, true
	return nil, false
}

@(private = "file")
Resolve_Ctx :: struct {
	ctx:             runtime.Context,
	title:           string,
	class_name:      string,
	exe_name:        string,
	exact_match:     win32.HWND,
	class_exe_match: win32.HWND, // first found; exact_match still wins if one turns up later
}

@(private = "file")
resolve_enum_proc :: proc "system" (hwnd: win32.HWND, lparam: win32.LPARAM) -> win32.BOOL {
	rctx := (^Resolve_Ctx)(rawptr(uintptr(lparam)))
	context = rctx.ctx

	if !win32.IsWindowVisible(hwnd) do return true

	ex_style := win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE)
	if u32(ex_style) & win32.WS_EX_TOOLWINDOW != 0 do return true

	cloaked: u32
	if hr := win32.DwmGetWindowAttribute(
		hwnd, u32(win32.DWMWINDOWATTRIBUTE.DWMWA_CLOAKED), &cloaked, size_of(cloaked),
	); hr >= 0 && cloaked != 0 {
		return true
	}

	class_name := get_class_name(hwnd, context.temp_allocator)
	if class_name != rctx.class_name do return true

	exe_name := get_exe_basename(hwnd, context.temp_allocator)
	if exe_name != rctx.exe_name do return true

	// class + exe matched. Check title for the exact-match upgrade.
	title_matches := false
	title_len := win32.GetWindowTextLengthW(hwnd)
	if title_len > 0 {
		title_buf := make([]u16, title_len + 1, context.temp_allocator)
		tn := win32.GetWindowTextW(hwnd, raw_data(title_buf), i32(len(title_buf)))
		if tn > 0 {
			if title_str, terr := win32.utf16_to_utf8(title_buf[:tn], context.temp_allocator); terr == nil {
				title_matches = title_str == rctx.title
			}
		}
	}

	if title_matches {
		rctx.exact_match = hwnd
		return false // best possible match found, stop enumerating
	}

	if rctx.class_exe_match == nil {
		rctx.class_exe_match = hwnd
	}
	return true
}

// Coarse heuristic for the picker's default filter: borderless or monitor-sized.
@(private = "file")
is_likely_game :: proc(hwnd: win32.HWND) -> bool {
	style := win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE)
	borderless := u32(style) & (win32.WS_CAPTION | win32.WS_THICKFRAME) == 0

	rect: win32.RECT
	if !win32.GetWindowRect(hwnd, &rect) do return borderless

	mon := win32.MonitorFromWindow(hwnd, .MONITOR_DEFAULTTONEAREST)
	if mon == nil do return borderless

	mi: win32.MONITORINFO
	mi.cbSize = size_of(win32.MONITORINFO)
	if !win32.GetMonitorInfoW(mon, &mi) do return borderless

	fullscreen_sized :=
		rect.left <= mi.rcMonitor.left && rect.top <= mi.rcMonitor.top &&
		rect.right >= mi.rcMonitor.right && rect.bottom >= mi.rcMonitor.bottom

	return borderless || fullscreen_sized
}
