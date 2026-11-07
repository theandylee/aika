package main

import "core:mem"
import rt "base:runtime"

// Each native callback owns a distinct, lazy arena. A nested SendMessage or
// modal loop must never reset the caller's scratch. Nothing allocated here may
// escape the scope; persistent metadata continues using context.allocator.
Scratch :: mem.Dynamic_Arena

scratch_begin :: proc(s: ^Scratch) -> mem.Allocator {
	// Keep cache-line alignment as the minimum for snapshot map allocations.
	// Dynamic_Arena also honors larger per-request alignments.
	mem.dynamic_arena_init(s, block_size = 16 * 1024, out_band_size = 16 * 1024,
		minimum_alignment = rt.MAP_CACHE_LINE_SIZE)
	return mem.dynamic_arena_allocator(s)
}

scratch_end :: proc(s: ^Scratch) {
	mem.dynamic_arena_destroy(s)
}
