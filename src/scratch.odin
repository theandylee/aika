package main

import "core:mem"
import rt "base:runtime"

// Each native callback owns a distinct, lazy arena. A nested SendMessage or
// modal loop must never reset the caller's scratch. Nothing allocated here may
// escape the scope; persistent metadata continues using context.allocator.
Scratch :: mem.Dynamic_Arena

scratch_begin :: proc(s: ^Scratch) -> mem.Allocator {
	// Dynamic_Arena uses its configured alignment, not each request's alignment.
	// Snapshot maps require runtime cache-line alignment (not heap's default 16).
	mem.dynamic_arena_init(s, block_size = 16 * 1024, out_band_size = 16 * 1024,
		alignment = rt.MAP_CACHE_LINE_SIZE)
	return mem.dynamic_arena_allocator(s)
}

scratch_end :: proc(s: ^Scratch) {
	mem.dynamic_arena_destroy(s)
}
