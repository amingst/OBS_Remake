Profile_Info :: struct {
    id:   string,   // owned
    name: string,   // owned
    path: string,   // owned; full path to the json
}

enumerate     :: proc(dir: string) -> []Profile_Info
destroy_infos :: proc(infos: []Profile_Info)

load_by_id :: proc(dir, id: string) -> (Profile, bool)
save       :: proc(p: ^Profile, dir: string) -> bool
create     :: proc(dir, name: string) -> (Profile, bool)
remove     :: proc(dir, id: string) -> bool