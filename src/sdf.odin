package main

import "core:strings"
import "core:sys/windows"

// Read-only reader for unencrypted SQL Server Compact 4.0 (.sdf) files, enough
// to read ManicTime's database without ManicTime's DLLs, .NET or PowerShell.
//
// The on-disk format is undocumented; the layout used here follows the
// reverse-engineering in github.com/boykopovar/sqlce (MIT). Every offset is
// bounds-checked: the file may be mid-write (ManicTime keeps it open) or
// corrupt, and must never crash aika.
//
// Allocation: persistent structures (tables, page map) use context.allocator
// (callers pass an arena). Per-row values use context.temp_allocator and are
// freed by sdf_each_row after each callback, so callbacks must clone anything
// they keep.

SDF_PAGE :: 4096

SDF_PAGE_DATA   :: 0x40
SDF_PAGE_ROOT   :: 0x30
SDF_PAGE_BITMAP :: 0x80
SDF_PAGE_LVMAP  :: 0x90

SDF_CATALOG_ROOT :: 1027
SDF_MAP_B_SPAN   :: 1527
SDF_MAP_A_SLOTS  :: 1530
SDF_LOGICAL_MAX  :: SDF_CATALOG_ROOT + SDF_MAP_B_SPAN * SDF_MAP_A_SLOTS

SDF_UNIX_EPOCH_DAYS :: 25567 // 1900-01-01 -> 1970-01-01

Sdf_Type :: enum u16 {
	TinyInt = 0, SmallInt = 1, Int = 3, BigInt = 5, NChar = 7, NVarChar = 8, NText = 9,
	Binary = 10, VarBinary = 11, Image = 12, DateTime = 13, Guid = 14, Bit = 15,
	Real = 16, Float = 17, Money = 18, Numeric = 19, RowVersion = 20,
	Unknown = 0xFFFF,
}

// SQL Server datetime: days since 1900-01-01 and 1/300-second ticks.
Sdf_DateTime :: struct { days: i32, ticks: u32 }

Sdf_Value :: union { i64, f64, bool, string, Sdf_DateTime, []u8 }

Sdf_Column :: struct {
	name:      string,
	ordinal:   int,
	type:      Sdf_Type,
	size:      int,
	precision: u8,
	scale:     u8,
}

Sdf_Table :: struct {
	name:    string,
	root:    u32,
	columns: [dynamic]Sdf_Column,
	pages:   [dynamic]u32, // physical heap pages; filled by sdf_table
	loaded:  bool,
}

Sdf_Error :: enum {
	None,
	Open,        // missing, unreadable or empty file
	Not_Sdf,     // wrong size/layout
	Encrypted,   // password-protected or encrypted databases are unsupported
	Format,      // internal structure not understood
}

Sdf :: struct {
	file:       windows.HANDLE,
	page_count: u32,
	logical:    []u32, // logical page id -> physical page (0 = unmapped)
	tables:     [dynamic]Sdf_Table,
	lob_errors: int,
	error:      Sdf_Error,
}

// --- little-endian helpers (out-of-range reads return 0) ---

sdf_u16 :: proc(b: []u8, o: int) -> u16 {
	if o < 0 || o + 2 > len(b) { return 0 }
	return u16(b[o]) | u16(b[o + 1]) << 8
}

sdf_u32 :: proc(b: []u8, o: int) -> u32 {
	if o < 0 || o + 4 > len(b) { return 0 }
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

sdf_u64 :: proc(b: []u8, o: int) -> u64 {
	return u64(sdf_u32(b, o)) | u64(sdf_u32(b, o + 4)) << 32
}

// 20-bit slots packed three per 64-bit word.
sdf_packed :: proc(b: []u8, base, slot: int) -> u32 {
	wo := base + (slot / 3) * 8
	if wo < 0 || wo + 8 > len(b) { return 0 }
	return u32((sdf_u64(b, wo) >> uint((20 * slot) % 60)) & 0xFFFFF)
}

sdf_read_page :: proc(s: ^Sdf, n: u32, buf: []u8) -> bool {
	if n >= s.page_count || len(buf) < SDF_PAGE { return false }
	off := u64(n) * SDF_PAGE
	ov := windows.OVERLAPPED{Offset = u32(off), OffsetHigh = u32(off >> 32)}
	read: u32
	ok := windows.ReadFile(s.file, raw_data(buf), SDF_PAGE, &read, &ov)
	return bool(ok) && read == SDF_PAGE
}

sdf_close :: proc(s: ^Sdf) {
	if s.file != nil && s.file != windows.INVALID_HANDLE_VALUE { windows.CloseHandle(s.file) }
	s.file = nil
}

sdf_resolve :: proc(s: ^Sdf, id: u32) -> (u32, bool) {
	if int(id) >= len(s.logical) { return 0, false }
	p := s.logical[id]
	return p, p != 0
}

sdf_page_is :: proc(b: []u8, type: u8, logical: u32) -> bool {
	return len(b) > 7 && b[6] == type && sdf_u32(b, 4) & 0xFFFFF == logical
}

sdf_open :: proc(path: string) -> (s: Sdf, ok: bool) {
	s.file = windows.CreateFileW(wtext(path), windows.GENERIC_READ,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, nil)
	if s.file == windows.INVALID_HANDLE_VALUE { s.file = nil; s.error = .Open; return }
	size: windows.LARGE_INTEGER
	if !windows.GetFileSizeEx(s.file, &size) || size <= 0 { s.error = .Open; sdf_close(&s); return }
	if size % SDF_PAGE != 0 || size / SDF_PAGE > 0xFFFFFFF { s.error = .Not_Sdf; sdf_close(&s); return }
	s.page_count = u32(size / SDF_PAGE)

	page0: [SDF_PAGE]u8
	if !sdf_read_page(&s, 0, page0[:]) { s.error = .Open; sdf_close(&s); return }
	if sdf_u32(page0[:], 16) != 4_000_000 { s.error = .Not_Sdf; sdf_close(&s); return }
	if sdf_u32(page0[:], 184) != 0 { s.error = .Encrypted; sdf_close(&s); return }
	if !sdf_build_map(&s, page0[:]) { s.error = .Format; sdf_close(&s); return }
	if !sdf_load_catalog(&s) { s.error = .Format; sdf_close(&s); return }
	return s, true
}

sdf_build_map :: proc(s: ^Sdf, page0: []u8) -> bool {
	map_a := sdf_u32(page0, 44)
	if map_a == 0 || map_a >= s.page_count { return false }
	pa, pb: [SDF_PAGE]u8
	if !sdf_read_page(s, map_a, pa[:]) || !sdf_page_is(pa[:], 0x10, 1) { return false }
	b0 := sdf_packed(pa[:], 16, 0)
	if b0 == 0 || b0 >= s.page_count { return false }
	if !sdf_read_page(s, b0, pb[:]) || !sdf_page_is(pb[:], 0x20, 2) { return false }

	s.logical = make([]u32, SDF_LOGICAL_MAX)
	s.logical[1] = map_a
	s.logical[2] = b0
	sdf_load_map_b(s, pb[:], SDF_CATALOG_ROOT)

	// Map A slot k holds the Map B page for logical ids
	// 1027 + 1527*k .. +1526 (verified against each page's own id; the
	// reference reader skips slot 1 and mislabels every later range).
	for slot := 1; 16 + (slot / 3) * 8 + 8 <= SDF_PAGE; slot += 1 {
		phys := sdf_packed(pa[:], 16, slot)
		if phys != 0 && phys < s.page_count && sdf_read_page(s, phys, pb[:]) {
			sdf_load_map_b(s, pb[:], u32(SDF_CATALOG_ROOT + SDF_MAP_B_SPAN * slot))
		}
	}
	return true
}

sdf_load_map_b :: proc(s: ^Sdf, pb: []u8, start: u32) {
	for slot in 0 ..< SDF_MAP_B_SPAN {
		phys := sdf_packed(pb, 16, slot)
		idx := int(start) + slot
		if phys == 0 || phys >= s.page_count || idx >= len(s.logical) { continue }
		s.logical[idx] = phys
	}
}

// Physical data pages of the table/catalog whose root is `root` (logical id).
sdf_heap_pages :: proc(s: ^Sdf, root: u32) -> (pages: [dynamic]u32) {
	phys, found := sdf_resolve(s, root)
	if !found { return }
	buf: [SDF_PAGE]u8
	if !sdf_read_page(s, phys, buf[:]) || buf[6] != SDF_PAGE_ROOT { return }
	count := int(sdf_u32(buf[:], 16))
	indirect := sdf_u32(buf[:], 20) != 0
	base, region_end :: 24, 16 + 96

	if indirect {
		bm: [SDF_PAGE]u8
		for g in 0 ..< 32 {
			if base + (g / 3) * 8 + 8 > region_end { break }
			bid := sdf_packed(buf[:], base, g)
			if bid == 0 { continue }
			bp, ok := sdf_resolve(s, bid)
			if !ok || !sdf_read_page(s, bp, bm[:]) || bm[6] != SDF_PAGE_BITMAP { continue }
			first, last := int(sdf_u16(bm[:], 18)), int(sdf_u16(bm[:], 20))
			for bit in first ..= last {
				bo := 32 + bit >> 3
				if bo >= SDF_PAGE { break }
				if (bm[bo] >> uint(bit & 7)) & 1 == 0 { continue }
				if p, ok2 := sdf_resolve(s, u32(bit) + 32512 * u32(g)); ok2 { append(&pages, p) }
			}
		}
		return
	}
	for slot in 0 ..< count {
		if base + (slot / 3) * 8 + 8 > region_end { break }
		id := sdf_packed(buf[:], base, slot)
		if id == 0 { continue }
		if p, ok := sdf_resolve(s, id); ok { append(&pages, p) }
	}
	return
}

// --- page rows ---

Sdf_Slice :: struct {
	index, start, length: int,
	first:                bool,
	has_cont:             bool,
	cont_page:            u32, // logical
	cont_slot:            int,
}

sdf_page_slices :: proc(b: []u8, out: ^[dynamic]Sdf_Slice) {
	clear(out)
	n := int(sdf_u32(b, 20) & 0xFFF)
	for i in 0 ..< n {
		so := 4 * (1017 - i)
		if so < 0 || so + 28 > SDF_PAGE { continue }
		flags := b[so + 27]
		if flags & 1 != 0 { continue }
		dw := sdf_u32(b, so + 24)
		off := int(dw & 0xFFF)
		lf := int((dw >> 12) & 0xFFF)
		if lf <= 4 { continue }
		start := off + 28
		end := start + (lf - 4)
		if end > SDF_PAGE { continue }
		cd := sdf_u32(b, off + 24)
		append(out, Sdf_Slice{index = i, start = start, length = lf - 4, first = flags & 2 != 0,
			has_cont = cd != 0, cont_page = cd >> 12, cont_slot = int(cd & 0xFFF)})
	}
}

// Joins a row's fragments. A continuation that points nowhere valid ends the
// row there (as the reference reader does); structural errors fail.
sdf_assemble :: proc(s: ^Sdf, page: []u8, first: Sdf_Slice, owner: u8, catalog: ^map[u32]struct{}) -> (row: []u8, ok: bool) {
	buf := make([dynamic]u8, 0, first.length, context.temp_allocator)
	append(&buf, ..page[first.start:first.start + first.length])
	cur := first
	next: [SDF_PAGE]u8
	slices := make([dynamic]Sdf_Slice, context.temp_allocator)
	for hops := 0; cur.has_cont; hops += 1 {
		if hops >= 64 { return nil, false }
		phys, found := sdf_resolve(s, cur.cont_page)
		if !found { break }
		if !sdf_read_page(s, phys, next[:]) { return nil, false }
		if catalog != nil {
			if phys not_in catalog^ { break }
		} else if next[6] != SDF_PAGE_DATA || next[16] != owner {
			break
		}
		sdf_page_slices(next[:], &slices)
		matched := false
		for sl in slices {
			if sl.index != cur.cont_slot { continue }
			append(&buf, ..next[sl.start:sl.start + sl.length])
			cur = sl
			matched = true
			break
		}
		if !matched { return nil, false }
	}
	return buf[:], true
}

// --- catalog (table and column definitions) ---

Sdf_Cat_Kind :: enum u8 { Tiny, Small, Int, Big, Var, Bit }

Sdf_Cat_Field :: struct {
	name: string,
	kind: Sdf_Cat_Kind,
	col:  u8,
	tbl:  u8, // 255 = every row type, else the SysObjectType it belongs to
}

SDF_CAT_ANY :: 255

// Fixed fields occupy space for every row type; only applicable ones carry data.
sdf_cat_schema := [?]Sdf_Cat_Field{
	{"SysObjectType", .Small, 0, SDF_CAT_ANY},
	{"SysObjectOwner", .Var, 1, SDF_CAT_ANY},
	{"SysObjectName", .Var, 2, SDF_CAT_ANY},
	{"SysObjectIsSystem", .Bit, 3, SDF_CAT_ANY},
	{"SysObjectVersion", .Big, 4, SDF_CAT_ANY},
	{"SysObjectOrdinal", .Small, 5, SDF_CAT_ANY},
	{"SysObjectCedbInfo", .Int, 6, SDF_CAT_ANY},
	{"SysTablePageId", .Int, 7, 1},
	{"SysTableNick", .Int, 8, 1},
	{"SysTableTrackingType", .Small, 9, 1},
	{"SysTableDdlGranted", .Int, 10, 1},
	{"SysTableReadOnly", .Bit, 11, 1},
	{"SysTableCompressed", .Bit, 12, 1},
	{"SysColumnType", .Small, 13, 4},
	{"SysColumnSize", .Small, 14, 4},
	{"SysColumnPrecision", .Tiny, 15, 4},
	{"SysColumnScale", .Tiny, 16, 4},
	{"SysColumnFixed", .Bit, 17, 4},
	{"SysColumnNullable", .Bit, 18, 4},
	{"SysColumnWriteable", .Bit, 19, 4},
	{"SysColumnAutoType", .Small, 20, 4},
	{"SysColumnPosition", .Small, 21, 4},
	{"SysColumnDefault", .Var, 22, 4},
	{"SysColumnCompressed", .Bit, 23, 4},
	{"SysIndexRoot", .Int, 24, 2},
	{"SysIndexKey", .Var, 25, 2},
	{"SysIndexUnique", .Bit, 26, 2},
	{"SysIndexNullOption", .Small, 27, 2},
	{"SysIndexPositional", .Bit, 28, 2},
	{"SysIndexHistogram", .Var, 29, 2},
	{"SysConstraintType", .Int, 30, 8},
	{"SysConstraintIndex", .Var, 31, 8},
	{"SysConstraintTargetIndex", .Var, 32, 8},
	{"SysConstraintTargetTable", .Var, 33, 8},
	{"SysConstraintOnDelete", .Int, 34, 8},
	{"SysConstraintOnUpdate", .Int, 35, 8},
	{"SysConstraintKey", .Var, 36, 8},
	{"SysConstraintColumn", .Var, 37, 8},
}

SDF_CAT_PRESENCE_BYTES :: (len(sdf_cat_schema) + 7) / 8

Sdf_Cat_Row :: struct {
	kind:        u16,
	owner, name: string,
	has_owner, has_name: bool,
	ordinal:     int,
	has_ordinal: bool,
	table_page:  u32,
	has_page:    bool,
	col_type:    u16,
	col_size:    u16,
	has_type:    bool,
	precision, scale: u8,
}

sdf_cat_size :: proc(k: Sdf_Cat_Kind) -> int {
	switch k {
	case .Tiny: return 1
	case .Small: return 2
	case .Int: return 4
	case .Big: return 8
	case .Var, .Bit: return 0
	}
	return 0
}

// Catalog presence bits are inverted relative to intuition: set = NULL.
sdf_cat_null :: proc(presence: []u8, col: u8) -> bool {
	bi := int(col) / 8
	if bi >= len(presence) { return true }
	return (presence[bi] >> (col % 8)) & 1 != 0
}

// Catalog names are stored one byte per character, NUL-terminated.
sdf_cat_string :: proc(chunk: []u8) -> string {
	n := 0
	for n < len(chunk) && chunk[n] != 0 { n += 1 }
	return strings.clone(string(chunk[:n]))
}

sdf_cat_decode :: proc(rb: []u8) -> (r: Sdf_Cat_Row, ok: bool) {
	if len(rb) < 4 + SDF_CAT_PRESENCE_BYTES { return }
	presence := rb[4:4 + SDF_CAT_PRESENCE_BYTES]
	if sdf_cat_null(presence, 0) { return }
	off := 4 + SDF_CAT_PRESENCE_BYTES + 2
	if off + 2 > len(rb) { return }
	r.kind = sdf_u16(rb, off)
	applic: u8
	switch r.kind {
	case 1, 2, 4, 8: applic = u8(r.kind)
	}

	for f in sdf_cat_schema {
		if f.kind == .Var || f.kind == .Bit { continue }
		size := sdf_cat_size(f.kind)
		if f.tbl != SDF_CAT_ANY && f.tbl != applic { off += size; continue }
		if off + size > len(rb) { return }
		if sdf_cat_null(presence, f.col) { off += size; continue }
		raw: u64
		switch size {
		case 1: raw = u64(rb[off])
		case 2: raw = u64(sdf_u16(rb, off))
		case 4: raw = u64(sdf_u32(rb, off))
		case 8: raw = sdf_u64(rb, off)
		}
		switch f.name {
		case "SysObjectOrdinal": r.ordinal = int(raw); r.has_ordinal = true
		case "SysTablePageId": r.table_page = u32(raw); r.has_page = true
		case "SysColumnType": r.col_type = u16(raw); r.has_type = true
		case "SysColumnSize": r.col_size = u16(raw)
		case "SysColumnPrecision": r.precision = u8(raw)
		case "SysColumnScale": r.scale = u8(raw)
		}
		off += size
	}

	var_count := 0
	for f in sdf_cat_schema { if f.kind == .Var { var_count += 1 } }
	dir_end := off + 2 * var_count
	if dir_end > len(rb) { return }
	var_data := rb[dir_end:]

	idx, prev := 0, 0
	for f in sdf_cat_schema {
		if f.kind != .Var { continue }
		cum := len(var_data)
		if idx != var_count - 1 { cum = int(sdf_u16(rb, off + 2 * (idx + 1)) & 0x7FFF) }
		idx += 1
		present := (f.tbl == SDF_CAT_ANY || f.tbl == applic) && !sdf_cat_null(presence, f.col)
		start := prev
		prev = cum
		if !present || start > cum || cum > len(var_data) { continue }
		switch f.name {
		case "SysObjectOwner": r.owner = sdf_cat_string(var_data[start:cum]); r.has_owner = true
		case "SysObjectName": r.name = sdf_cat_string(var_data[start:cum]); r.has_name = true
		}
	}
	return r, true
}

sdf_load_catalog :: proc(s: ^Sdf) -> bool {
	pages := sdf_heap_pages(s, SDF_CATALOG_ROOT)
	if len(pages) == 0 { return false }
	set := make(map[u32]struct{}, context.temp_allocator)
	for p in pages { set[p] = {} }

	page: [SDF_PAGE]u8
	slices := make([dynamic]Sdf_Slice, context.temp_allocator)

	// Continuation fragments are not rows of their own.
	targets := make(map[u64]struct{}, context.temp_allocator)
	for pn in pages {
		if !sdf_read_page(s, pn, page[:]) { return false }
		sdf_page_slices(page[:], &slices)
		for sl in slices {
			if !sl.has_cont { continue }
			if p, ok := sdf_resolve(s, sl.cont_page); ok && p in set {
				targets[u64(p) << 32 | u64(sl.cont_slot)] = {}
			}
		}
	}

	Pending :: struct { owner: string, col: Sdf_Column }
	pending := make([dynamic]Pending, context.temp_allocator)

	for pn in pages {
		if !sdf_read_page(s, pn, page[:]) { return false }
		sdf_page_slices(page[:], &slices)
		for sl in slices {
			if !sl.first || (u64(pn) << 32 | u64(sl.index)) in targets { continue }
			rb, ok := sdf_assemble(s, page[:], sl, page[16], &set)
			if !ok { return false }
			r, decoded := sdf_cat_decode(rb)
			if !decoded { continue }
			switch r.kind {
			case 1:
				if r.has_name && r.has_page {
					append(&s.tables, Sdf_Table{name = r.name, root = r.table_page})
				}
			case 4:
				if r.has_owner && r.has_name && r.has_ordinal && r.has_type {
					t := Sdf_Type(r.col_type)
					if r.col_type > 20 || r.col_type == 2 || r.col_type == 4 || r.col_type == 6 { t = .Unknown }
					append(&pending, Pending{r.owner, Sdf_Column{name = r.name, ordinal = r.ordinal,
						type = t, size = int(r.col_size), precision = r.precision, scale = r.scale}})
				}
			}
		}
	}
	for p in pending {
		for &t in s.tables {
			if t.name == p.owner { append(&t.columns, p.col); break }
		}
	}
	for &t in s.tables {
		// insertion sort: column counts are tiny
		for i in 1 ..< len(t.columns) {
			for j := i; j > 0 && t.columns[j - 1].ordinal > t.columns[j].ordinal; j -= 1 {
				t.columns[j - 1], t.columns[j] = t.columns[j], t.columns[j - 1]
			}
		}
	}
	return true
}

// Finds a table by exact name and resolves its data pages.
sdf_table :: proc(s: ^Sdf, name: string) -> ^Sdf_Table {
	for &t in s.tables {
		if t.name != name { continue }
		if !t.loaded {
			t.pages = sdf_heap_pages(s, t.root)
			t.loaded = true
		}
		return &t
	}
	return nil
}

// Row count stored in the table's root page; 0 if unavailable. Only an
// estimate for progress reporting.
sdf_row_count :: proc(s: ^Sdf, t: ^Sdf_Table) -> int {
	phys, ok := sdf_resolve(s, t.root)
	if !ok { return 0 }
	buf: [SDF_PAGE]u8
	if !sdf_read_page(s, phys, buf[:]) || buf[6] != SDF_PAGE_ROOT { return 0 }
	return int(sdf_u32(buf[:], 388))
}

// Index of a column by name, or -1.
sdf_column :: proc(t: ^Sdf_Table, name: string) -> int {
	for c, i in t.columns { if c.name == name { return i } }
	return -1
}

// --- row decoding ---

sdf_is_var :: proc(t: Sdf_Type) -> bool {
	#partial switch t {
	case .NVarChar, .VarBinary, .NText, .Image: return true
	}
	return false
}

sdf_fixed_size :: proc(c: Sdf_Column) -> int {
	#partial switch c.type {
	case .TinyInt: return 1
	case .SmallInt: return 2
	case .Int, .Real: return 4
	case .BigInt, .DateTime, .Float, .Money, .RowVersion: return 8
	case .Guid: return 16
	case .Numeric: return 19
	case .Binary, .NChar: return c.size if c.size != 0 else 1
	}
	return c.size if c.size != 0 else 4
}

// Row presence bits: set = NULL (ordinal is the zero-based bit index).
sdf_row_null :: proc(presence: []u8, ordinal: int) -> bool {
	bi := ordinal / 8
	if ordinal < 0 || bi >= len(presence) { return false }
	return (presence[bi] >> uint(ordinal % 8)) & 1 != 0
}

sdf_decode_text :: proc(chunk: []u8, compressed: bool) -> string {
	sb := strings.builder_make(0, len(chunk), context.temp_allocator)
	if compressed {
		for c in chunk { strings.write_rune(&sb, rune(c)) }
		return strings.to_string(sb)
	}
	n := len(chunk) / 2
	for i := 0; i < n; i += 1 {
		u := rune(sdf_u16(chunk, 2 * i))
		if u >= 0xD800 && u <= 0xDBFF && i + 1 < n {
			lo := rune(sdf_u16(chunk, 2 * (i + 1)))
			if lo >= 0xDC00 && lo <= 0xDFFF {
				strings.write_rune(&sb, 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00))
				i += 1
				continue
			}
		}
		strings.write_rune(&sb, u)
	}
	return strings.to_string(sb)
}

sdf_decode_fixed :: proc(c: Sdf_Column, b: []u8) -> Sdf_Value {
	#partial switch c.type {
	case .TinyInt: return i64(b[0])
	case .SmallInt: return i64(i16(sdf_u16(b, 0)))
	case .Int: return i64(i32(sdf_u32(b, 0)))
	case .BigInt: return i64(sdf_u64(b, 0))
	case .DateTime: return Sdf_DateTime{days = i32(sdf_u32(b, 4)), ticks = sdf_u32(b, 0)}
	case .Money: return f64(i64(sdf_u64(b, 0))) / 10000.0
	case .Real: return f64(transmute(f32)sdf_u32(b, 0))
	case .Float: return transmute(f64)sdf_u64(b, 0)
	case .NChar: return sdf_decode_text(b, false)
	}
	return b
}

// 20-bit slots up to `limit`, stopping at the null marker.
sdf_read_slots :: proc(out: ^[dynamic]u32, b: []u8, base, limit: int) {
	for slot in 0 ..< limit {
		if base + (slot / 3) * 8 + 8 > len(b) { break }
		v := sdf_packed(b, base, slot)
		if v == 0xFFFFF { break }
		append(out, v)
	}
}

sdf_decode_lob :: proc(s: ^Sdf, c: Sdf_Column, chunk: []u8, compressed: bool) -> Sdf_Value {
	is_text := c.type == .NText
	if len(chunk) < 8 {
		if is_text { return "" }
		return []u8{}
	}
	length := int(sdf_u32(chunk, 0))
	tail := chunk[8:]
	data: []u8
	if length <= 0xF8 {
		data = tail[:min(len(tail), length)]
	} else {
		per :: SDF_PAGE - 16
		need := (length + per - 1) / per
		ids := make([dynamic]u32, context.temp_allocator)
		if length <= 0x5CA30 {
			sdf_read_slots(&ids, tail, 0, min(need, 93))
		} else {
			head := make([dynamic]u32, context.temp_allocator)
			sdf_read_slots(&head, tail, 0, 1)
			if len(head) > 0 {
				mp: [SDF_PAGE]u8
				if p, ok := sdf_resolve(s, head[0]); ok && sdf_read_page(s, p, mp[:]) && mp[6] == SDF_PAGE_LVMAP {
					sdf_read_slots(&ids, mp[:], 16, min(need, SDF_MAP_B_SPAN))
				}
			}
		}
		out := make([]u8, length, context.temp_allocator)
		pg: [SDF_PAGE]u8
		got, pages := 0, 0
		for id in ids {
			p, ok := sdf_resolve(s, id)
			if !ok || !sdf_read_page(s, p, pg[:]) { break }
			take := min(per, length - got)
			copy(out[got:got + take], pg[16:16 + take])
			got += take
			pages += 1
		}
		if pages != need || got != length {
			s.lob_errors += 1
			return nil
		}
		data = out
	}
	if is_text { return sdf_decode_text(data, compressed) }
	return data
}

sdf_decode_row :: proc(s: ^Sdf, t: ^Sdf_Table, rb: []u8) -> []Sdf_Value {
	cols := t.columns[:]
	n := len(cols)
	vals := make([]Sdf_Value, n, context.temp_allocator)

	presence_bytes := (n + 7) / 8
	nbits := 0
	for c in cols { if c.type == .Bit { nbits += 1 } }
	bit_bytes := (nbits + 7) / 8

	off := 4
	presence, bitreg: []u8
	if off + presence_bytes <= len(rb) { presence = rb[off:off + presence_bytes] }
	off += presence_bytes
	if off + bit_bytes <= len(rb) { bitreg = rb[off:off + bit_bytes] }
	off += bit_bytes

	bit := 0
	for c, i in cols {
		if c.type == .Bit {
			if !sdf_row_null(presence, c.ordinal) && bit / 8 < len(bitreg) {
				vals[i] = (bitreg[bit / 8] >> uint(bit % 8)) & 1 != 0
			}
			bit += 1
			continue
		}
		if sdf_is_var(c.type) { continue }
		size := sdf_fixed_size(c)
		if !sdf_row_null(presence, c.ordinal) && off + size <= len(rb) {
			vals[i] = sdf_decode_fixed(c, rb[off:off + size])
		}
		off += size
	}

	var_idx := make([dynamic]int, context.temp_allocator)
	any_value := false
	for c, i in cols {
		if !sdf_is_var(c.type) { continue }
		append(&var_idx, i)
		if !sdf_row_null(presence, c.ordinal) { any_value = true }
	}
	if !any_value { return vals }
	dir_len := 2 * len(var_idx)
	if off + dir_len > len(rb) { return vals }
	dir := rb[off:off + dir_len]
	data := rb[off + dir_len:]

	for k in 0 ..< len(var_idx) {
		c := cols[var_idx[k]]
		if sdf_row_null(presence, c.ordinal) { continue }
		e := sdf_u16(dir, 2 * k)
		start := int(e & 0x7FFF)
		end := len(data)
		if k + 1 < len(var_idx) { end = int(sdf_u16(dir, 2 * (k + 1)) & 0x7FFF) }
		if start > end || end > len(data) { continue }
		chunk := data[start:end]
		compressed := e & 0x8000 != 0
		#partial switch c.type {
		case .NText, .Image: vals[var_idx[k]] = sdf_decode_lob(s, c, chunk, compressed)
		case .NVarChar: vals[var_idx[k]] = sdf_decode_text(chunk, compressed)
		case: vals[var_idx[k]] = chunk
		}
	}
	return vals
}

Sdf_Row_Proc :: proc(t: ^Sdf_Table, row: []Sdf_Value, data: rawptr) -> bool

// Calls cb for every row; cb returns false to stop early. Returns false on a
// structural read failure. Temp-allocator memory is freed after each row.
sdf_each_row :: proc(s: ^Sdf, t: ^Sdf_Table, cb: Sdf_Row_Proc, data: rawptr) -> bool {
	page: [SDF_PAGE]u8
	slices := make([dynamic]Sdf_Slice)
	defer delete(slices)
	for pn in t.pages {
		if !sdf_read_page(s, pn, page[:]) { return false }
		// The space map also lists index/overflow pages of the same object.
		if page[6] != SDF_PAGE_DATA { continue }
		owner := page[16]
		sdf_page_slices(page[:], &slices)
		for sl in slices {
			if !sl.first { continue }
			rb, ok := sdf_assemble(s, page[:], sl, owner, nil)
			if !ok { return false }
			keep := cb(t, sdf_decode_row(s, t, rb), data)
			free_all(context.temp_allocator)
			if !keep { return true }
		}
	}
	return true
}

// SQL Server datetime -> Unix milliseconds (UTC when the column stores UTC).
sdf_unix_ms :: proc(v: Sdf_DateTime) -> i64 {
	ms := (i64(v.ticks) * 10 + 1) / 3
	return (i64(v.days) - SDF_UNIX_EPOCH_DAYS) * 86_400_000 + ms
}
