package main

// One pointer interaction at a time. The main window holds mouse capture exactly
// while `ui.interaction` is not nil, so capture and state cannot disagree.
//
// Rules (see docs/ARCHITECTURE.md, "Interaction state machine"):
//  * begin_* procs set the value, then the caller (or the begin proc) SetCapture.
//  * Ending an interaction sets it to nil BEFORE ReleaseCapture: ReleaseCapture
//    sends WM_CAPTURECHANGED synchronously, which re-enters interaction_cancel.
//  * interaction_cancel is idempotent, rolls the interaction back (Escape,
//    WM_CANCELMODE, capture loss) and never calls ReleaseCapture itself.
//  * Data that must outlive the interaction (the tag range handed to the picker)
//    lives outside the payload in tag_ui.

// A toolbar-style button that shows its pressed state and acts on release.
Press_State :: struct {
	hit: Hit,
}

// Splitter drag: kind selects the axis, offset anchors the pointer, and the
// saved geometry is the cancel snapshot.
Pane_State :: struct {
	kind:          Pane_Drag,
	offset:        i32,
	saved_lane_h:  i32,
	saved_totals_w: i32,
}

// Zoom drag: kind selects handle/pan, start/end snapshot the live view for
// cancellation, anchor fixes the grab point.
Zoom_State :: struct {
	kind:         Zoom_Drag,
	anchor:       f64,
	start, end:   f64,
}

// Tag drag: kind selects new-range/edge, id selects the resized block.
// The live range (anchor/start/end/view/down_x) stays in tag_ui so it can
// outlive the interaction for the picker; cancel only clears the kind.
Tag_State :: struct {
	kind: Tag_Drag,
	id:   i64,
}

Interaction :: union {
	Press_State,
	Pane_State,
	Zoom_State,
	Tag_State,
}

Interaction_Kind :: enum { None, Press, Pane, Zoom, Tag }

interaction_kind :: proc(i: Interaction) -> Interaction_Kind {
	switch _ in i {
	case Press_State: return .Press
	case Pane_State:  return .Pane
	case Zoom_State:  return .Zoom
	case Tag_State:   return .Tag
	}
	return .None
}

interaction_active :: proc() -> bool {
	return ui.interaction != nil
}

// Commit: the interaction is over and its effect stays. Callers do this before
// ReleaseCapture.
interaction_end :: proc() {
	ui.interaction = nil
}

// Roll back whatever is active and clear it. Safe to call at any time, any
// number of times (including re-entrantly from WM_CAPTURECHANGED).
interaction_cancel :: proc() {
	switch v in ui.interaction {
	case Pane_State:
		ui.pane_lane_h, ui.pane_totals_w = v.saved_lane_h, v.saved_totals_w
	case Zoom_State:
		ui.zoom_start, ui.zoom_end = v.start, v.end
	case Tag_State:
	case Press_State:
	}
	ui.interaction = nil
}

// --- Pressed button ---

press_begin :: proc(hit: Hit) {
	ui.interaction = Press_State{hit = hit}
}

// The button currently held down, or .None.
press_hit :: proc() -> Hit {
	if s, ok := ui.interaction.(Press_State); ok { return s.hit }
	return .None
}

// --- Pane splitter ---

pane_begin :: proc(kind: Pane_Drag, offset: i32) {
	ui.interaction = Pane_State{kind = kind, offset = offset,
		saved_lane_h = ui.pane_lane_h, saved_totals_w = ui.pane_totals_w}
}

pane_drag :: proc() -> Pane_Drag {
	if s, ok := ui.interaction.(Pane_State); ok { return s.kind }
	return .None
}

pane_state :: proc() -> (Pane_State, bool) {
	if s, ok := ui.interaction.(Pane_State); ok { return s, true }
	return {}, false
}

// --- Zoom ---

zoom_begin :: proc(kind: Zoom_Drag, anchor: f64) {
	ui.interaction = Zoom_State{kind = kind, anchor = anchor,
		start = ui.zoom_start, end = ui.zoom_end}
}

zoom_drag :: proc() -> Zoom_Drag {
	if s, ok := ui.interaction.(Zoom_State); ok { return s.kind }
	return .None
}

zoom_state :: proc() -> (Zoom_State, bool) {
	if s, ok := ui.interaction.(Zoom_State); ok { return s, true }
	return {}, false
}

// --- Tag ---

tag_begin :: proc(kind: Tag_Drag, id: i64) {
	ui.interaction = Tag_State{kind = kind, id = id}
}

tag_drag :: proc() -> Tag_Drag {
	if s, ok := ui.interaction.(Tag_State); ok { return s.kind }
	return .None
}

tag_drag_id :: proc() -> i64 {
	if s, ok := ui.interaction.(Tag_State); ok { return s.id }
	return 0
}
