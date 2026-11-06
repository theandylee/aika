package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sys/windows"

Totals_Node :: struct {
	name, path: string,
	ms: i64,
	color: u32,
	group_id: i64,
	depth: i32,
	children: [dynamic]^Totals_Node,
}

totals_tree_key :: proc(path: string) -> string {
	return fmt.tprintf("%d:%s", ui.lane, path)
}

totals_tree_rows :: proc(totals: []TotRow) -> []^Totals_Node {
	allocator := context.temp_allocator
	by_path := make(map[string]^Totals_Node, allocator)
	all := make([dynamic]^Totals_Node, allocator)
	roots := make([dynamic]^Totals_Node, allocator)
	for t in totals {
		parent: ^Totals_Node
		path := ""
		for raw in strings.split(t.name, "/", allocator) {
			name := strings.trim_space(raw)
			if name == "" { continue }
			path = fmt.tprintf("%s/%s", path, name)
			node, found := by_path[path]
			if !found {
				node = new(Totals_Node, allocator)
				node.name, node.path = name, path
				node.color, node.group_id = t.color, t.group_id
				node.children = make([dynamic]^Totals_Node, allocator)
				if parent != nil {
					node.depth = parent.depth + 1
					append(&parent.children, node)
				} else {
					append(&roots, node)
				}
				by_path[path] = node
				append(&all, node)
			}
			node.ms += t.ms
			parent = node
		}
		// Empty/slash-only names remain visible rather than losing their time.
		if parent == nil {
			node := new(Totals_Node, allocator)
			node.name, node.ms, node.color, node.group_id = t.name, t.ms, t.color, t.group_id
			append(&roots, node)
		}
	}
	less :: proc(a, b: ^Totals_Node) -> bool {
		if a.ms != b.ms { return a.ms > b.ms }
		return a.name < b.name
	}
	slice.sort_by(roots[:], less)
	for node in all { slice.sort_by(node.children[:], less) }
	stack := make([dynamic]^Totals_Node, allocator)
	rows := make([dynamic]^Totals_Node, allocator)
	for i := len(roots) - 1; i >= 0; i -= 1 { append(&stack, roots[i]) }
	for len(stack) > 0 {
		node := pop(&stack)
		append(&rows, node)
		if ui.totals_expanded[totals_tree_key(node.path)] {
			for i := len(node.children) - 1; i >= 0; i -= 1 { append(&stack, node.children[i]) }
		}
	}
	return rows[:]
}

totals_mode_rect :: proc(lay: Layout) -> windows.RECT {
	right := lay.sidebar_x + lay.sidebar_w - 5
	return windows.RECT{right - 24, lay.list_top + 2, right, lay.list_top + 22}
}

draw_totals_mode :: proc(dc: windows.HDC, lay: Layout) {
	r := totals_mode_rect(lay)
	draw_button(dc, r, "", HIT_TOTALS_TREE)
	color := C_ACCENT if ui.totals_tree else C_TXT
	if ui.totals_tree { fill_frame(dc, r.left, r.top, 24, 20, C_ACCENT) }
	x, y := r.left + 6, r.top + 5
	line_v(dc, x, y, 9, color)
	line_h(dc, x, y + 3, 7, color)
	line_h(dc, x, y + 8, 7, color)
	fill_rect(dc, x + 7, y + 1, 4, 4, color)
	fill_rect(dc, x + 7, y + 6, 4, 4, color)
}

draw_totals_mode_tooltip :: proc(dc: windows.HDC, lay: Layout) {
	if ui.tab != 0 || !ui.mouse_valid || ui.pressed_hit != HIT_NONE || ui.pane_drag != 0 ||
	   tag_ui.drag != 0 || tag_ui.popup != nil ||
	   !rect_hit(totals_mode_rect(lay), ui.mouse.x, ui.mouse.y) { return }
	label := "Show flat totals" if ui.totals_tree else "Group totals by /"
	w := text_pixel_width(label, ui.font_normal) + 16
	x, y := lay.sidebar_x + lay.sidebar_w - w - 5, lay.list_top - 26
	fill_rect(dc, x, y, w, 24, C_TIP_BG)
	fill_frame(dc, x, y, w, 24, C_TIP_BORDER)
	draw_string(dc, label, x + 8, y + 6, ui.font_normal, C_TXT)
}

draw_totals_tree_row :: proc(dc: windows.HDC, node: ^Totals_Node, x, y, w: i32) {
	dur := fmt_span_hm(node.ms)
	dw := text_pixel_width(dur, ui.font_normal)
	indent := min(node.depth * 14, max(0, w - dw - 80))
	left := x + 8 + indent
	if len(node.children) > 0 {
		// Align with the label's visible capitals, not the row/color-chip center:
		// draw_string shifts its text rectangle up by two pixels.
		cx, cy := left + 6, y + 7
		expanded := ui.totals_expanded[totals_tree_key(node.path)]
		for i := i32(0); i < 4; i += 1 {
			if expanded {
				line_h(dc, cx - 3 + i, cy - 2 + i, 7 - 2 * i, C_TXT)
			} else {
				line_v(dc, cx - 2 + i, cy - 3 + i, 7 - 2 * i, C_TXT)
			}
		}
	} else {
		color := activity_colorref(Activity{group_id = node.group_id, color = node.color})
		fill_rect(dc, left + 1, y + 4, 10, 10, color)
	}
	font := ui.font_bold if len(node.children) > 0 else ui.font_normal
	draw_string(dc, node.name, left + 16, y + 2, font, C_TXT, x + w - dw - 16 - (left + 16))
	draw_string(dc, dur, x + w - 8 - dw, y + 2, ui.font_normal, C_DIM)
}

totals_tree_click :: proc(app: ^App, y: i32, lay: Layout) {
	snapshot := build_day_snapshot(app, tracker_now(app), tracker_monotonic(app))
	totals := build_totals(snapshot, lane_timeline(i32(ui.lane)))
	defer free_totals_slice(totals)
	rows := totals_tree_rows(totals)
	index := int(ui.totals_scroll.pos + (y - lay.list_top - 32) / LIST_ROW)
	if index < 0 || index >= len(rows) { return }
	node := rows[index]
	if len(node.children) == 0 { return }
	if ui.totals_expanded == nil { ui.totals_expanded = make(map[string]bool) }
	key := totals_tree_key(node.path)
	if ui.totals_expanded[key] {
		for saved in ui.totals_expanded {
			if saved == key {
				delete_key(&ui.totals_expanded, saved)
				delete(saved)
				break
			}
		}
	} else {
		ui.totals_expanded[strings.clone(key)] = true
	}
}

totals_tree_shutdown :: proc() {
	for key in ui.totals_expanded { delete(key) }
	delete(ui.totals_expanded)
}
