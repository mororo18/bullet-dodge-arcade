package main

import "core:mem"
import "core:fmt"
import "base:runtime"
import "base:intrinsics"

AllocatorData :: struct {
    data: []u8,
    offset: int,
    prev_offset: int,
}

my_alloc :: proc(alloc_data: ^AllocatorData, size: int, alignment: int) -> ([]byte, mem.Allocator_Error) {
    if len(alloc_data.data) - alloc_data.offset >= size {
        ret := mem.byte_slice(&alloc_data.data[alloc_data.offset], size)
        alloc_data.prev_offset = alloc_data.offset
        alloc_data.offset += size

        fmt.println("new offset=", alloc_data.offset)
        return ret, nil
    }

    return nil, .Out_Of_Memory
}

my_free :: proc( alloc_data: ^AllocatorData, old_memory: rawptr,) -> ([]byte, mem.Allocator_Error) {
    if alloc_data.prev_offset == intrinsics.ptr_sub( (^u8)(old_memory), &alloc_data.data[0] ) {
        alloc_data.offset = alloc_data.prev_offset
    }

    return nil, nil
}

my_free_all :: proc(alloc_data: ^AllocatorData) -> ([]byte, mem.Allocator_Error) {
    alloc_data.offset = 0
    alloc_data.prev_offset = 0
    return nil, nil
}

my_resize :: proc(
    alloc_data: ^AllocatorData,
    new_size: int,
    alignment: int,
    old_memory: rawptr,
    old_size: int
) -> ([]byte, mem.Allocator_Error) {

    // NOTE: if old_size is 0 and old_memory is nil,
    // this operation is a no-op, and should not return errors.
    if old_memory == nil && old_size == 0 {
        return nil, nil
    }
    if old_memory == nil {
        return my_alloc(alloc_data, new_size, alignment)
    }

    // Bounds check
    if !(&alloc_data.data[0] <= old_memory && old_memory < &alloc_data.data[alloc_data.offset]) {
        return nil, .Invalid_Pointer
    }

    // Free
    if new_size == 0 {
        return my_free(alloc_data, old_memory)
    }

    if alloc_data.prev_offset == intrinsics.ptr_sub((^u8)(old_memory), &alloc_data.data[0]) {
        alloc_data.offset = alloc_data.prev_offset + new_size
        return mem.byte_slice(old_memory, new_size), nil
    }

    // Alloc and cpy
    new_memory, err := my_alloc(alloc_data, new_size, alignment)
    if err != .None {
        return nil, err
    }
    cpy_size := new_size if new_size < old_size else old_size

    copy_slice(
        new_memory,
        mem.byte_slice(old_memory, cpy_size)
    )

    return new_memory, nil
}

my_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size: int,
	alignment: int,
	old_memory: rawptr,
	old_size: int,
	location: runtime.Source_Code_Location = #caller_location,
) -> ([]byte, mem.Allocator_Error) {
    alloc_data := cast(^AllocatorData)allocator_data
    fmt.println("Alloc_proc mode=", mode)

    switch mode {
    case .Alloc:
        return my_alloc(alloc_data, size, alignment)
    case .Alloc_Non_Zeroed:
        return my_alloc(alloc_data, size, alignment)
    case .Free:
        return my_free(alloc_data, old_memory)
    case .Free_All:
        return my_free_all(alloc_data)
    case .Resize:
        return my_resize(alloc_data, size, alignment, old_memory, old_size)
    case .Resize_Non_Zeroed:
        return my_resize(alloc_data, size, alignment, old_memory, old_size)
    case .Query_Features:
        set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Free_All, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
    case .Query_Info:
        return nil, .Mode_Not_Implemented
    }

    return nil, nil
}

init_allocator_data :: proc(alloc_data: ^AllocatorData, initial_size: int) {
    data, err := mem.alloc_bytes(initial_size)
    assert(err == .None)
    alloc_data^ = {
        data = data,
        offset = 0,
    }
}

free_allocator_data :: proc(alloc_data: ^AllocatorData) {
    mem.free_bytes(alloc_data.data)
}


my_allocator :: proc(alloc_data: ^AllocatorData) -> mem.Allocator {
    return {
        procedure = my_allocator_proc,
        data = alloc_data,
    }
}

