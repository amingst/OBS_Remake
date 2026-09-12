package capture

import "core:log"
import win32 "core:sys/windows"
import "libs:mf"

Camera_Info :: struct {
	friendly_name: string,
	symlink:       string,
}

// enumerate_cameras lists video capture devices via Media Foundation. Every
// string in the result comes from context.allocator; destroy_camera_list
// frees the whole thing. Meant to be called when the picker popup opens and
// destroyed when it closes -- not every frame.
enumerate_cameras :: proc() -> []Camera_Info {
	list := make([dynamic]Camera_Info)

	attrs: ^mf.IMFAttributes
	hr := mf.MFCreateAttributes(&attrs, 1)
	if hr < 0 {
		log.errorf("enumerate_cameras: MFCreateAttributes failed: 0x%08X", u32(hr))
		return list[:]
	}
	defer attrs->Release()

	attrs->SetGUID(&mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)

	activates: [^]^mf.IMFActivate
	count:     u32
	hr = mf.MFEnumDeviceSources(attrs, &activates, &count)
	if hr < 0 {
		log.errorf("enumerate_cameras: MFEnumDeviceSources failed: 0x%08X", u32(hr))
		return list[:]
	}
	if count == 0 {
		// activates is nil / nothing to free when count == 0
		return list[:]
	}
	defer {
		for i in 0..<count {
			activates[i]->Release()
		}
		win32.CoTaskMemFree(activates)
	}

	for i in 0..<count {
		activate := activates[i]

		name_raw: [^]u16
		name_len: u32
		hr = activate->GetAllocatedString(&mf.MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name_raw, &name_len)
		if hr < 0 {
			log.errorf("enumerate_cameras: GetAllocatedString(FRIENDLY_NAME) failed: 0x%08X", u32(hr))
			continue
		}
		friendly_name, name_err := win32.utf16_to_utf8(name_raw[:name_len], context.allocator)
		win32.CoTaskMemFree(name_raw)
		if name_err != nil {
			log.errorf("enumerate_cameras: friendly name utf16_to_utf8 failed: %v", name_err)
			continue
		}

		link_raw: [^]u16
		link_len: u32
		hr = activate->GetAllocatedString(&mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link_raw, &link_len)
		if hr < 0 {
			log.errorf("enumerate_cameras: GetAllocatedString(SYMBOLIC_LINK) failed: 0x%08X", u32(hr))
			delete(friendly_name)
			continue
		}
		symlink, link_err := win32.utf16_to_utf8(link_raw[:link_len], context.allocator)
		win32.CoTaskMemFree(link_raw)
		if link_err != nil {
			log.errorf("enumerate_cameras: symlink utf16_to_utf8 failed: %v", link_err)
			delete(friendly_name)
			continue
		}

		append(&list, Camera_Info{
			friendly_name = friendly_name,
			symlink       = symlink,
		})
	}

	return list[:]
}

destroy_camera_list :: proc(list: []Camera_Info) {
	for c in list {
		delete(c.friendly_name)
		delete(c.symlink)
	}
	delete(list)
}
