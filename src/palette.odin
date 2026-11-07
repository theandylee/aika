package main

import "core:sys/windows"

// One named palette per theme. Colors are COLORREF (0x00BBGGRR); comments show
// rgb(R,G,B) where it helps. `Palette` is the only place theme values live:
// theme_set_palette copies the active one into the C_* variables that the
// drawing code reads, so there is no second value list to keep in sync.

// Shared literals: values that two palette fields (or other code) must agree on.
LIGHT_HOVER_FILL :: 0x00FCE0E4 // light hover highlight (buttons, hot tab, splitters, previews)
DARK_HOVER_FILL  :: 0x00504030
TEXT_DARK        :: 0x0028221E // light theme's text color; also the dark text on light tag fills
TEXT_LIGHT       :: 0x00FFFFFF // text on dark tag fills

Palette :: struct {
	bg:            windows.COLORREF, // window background
	panel:         windows.COLORREF, // list/toolbar/content surfaces
	border:        windows.COLORREF,
	border_soft:   windows.COLORREF,
	lane_bg:       windows.COLORREF,
	lane_grid:     windows.COLORREF,
	lane_text:     windows.COLORREF, // unselected lane label
	text:          windows.COLORREF,
	text_dim:      windows.COLORREF,
	tab_bg:        windows.COLORREF,
	tab_active:    windows.COLORREF,
	button_face:   windows.COLORREF,
	button_border: windows.COLORREF,
	button_hover:  windows.COLORREF, // hot/pressed button face and hot tab
	header_bg:     windows.COLORREF, // list header row, calendar title
	row_alt:       windows.COLORREF, // zebra rows
	tooltip_bg:    windows.COLORREF,
	tooltip_border: windows.COLORREF,
	splitter_hot:  windows.COLORREF, // pane splitter under the cursor
	tag_preview:   windows.COLORREF, // range being dragged/picked on the Tags lane
	section_head:  windows.COLORREF, // selected-section highlight in the Settings window
	zoom_selection: windows.COLORREF, // visible range in the overview bar
}

PALETTE_LIGHT :: Palette{
	bg = 0x00FAF7F5, panel = 0x00FFFFFF, border = 0x00C0AF9C, border_soft = 0x00E2D8CD,
	lane_bg = 0x00F4ECE2, lane_grid = 0x00E4D8CB, lane_text = 0x00746658,
	text = TEXT_DARK, text_dim = 0x00908478,
	tab_bg = 0x00F5EFE8, tab_active = 0x00FFFFFF,
	button_face = 0x00FFFFFF, button_border = 0x00EAB47E, button_hover = LIGHT_HOVER_FILL,
	header_bg = 0x00F8F4EF, row_alt = 0x00FCF9F6,
	tooltip_bg = 0x00E1FFFF, tooltip_border = 0x008C8278,
	splitter_hot = LIGHT_HOVER_FILL, tag_preview = LIGHT_HOVER_FILL, section_head = LIGHT_HOVER_FILL,
	zoom_selection = 0x00A8DDFF, // rgb(255,221,168)
}

PALETTE_DARK :: Palette{
	bg = 0x00201B18, panel = 0x00282320, border = 0x006B594B, border_soft = 0x004C4036,
	lane_bg = 0x00302820, lane_grid = 0x0040362D, lane_text = 0x00B8A99A,
	text = 0x00F0E8E0, text_dim = 0x00B8A99A,
	tab_bg = 0x00201B18, tab_active = 0x00282320,
	button_face = 0x00382F28, button_border = 0x00907050, button_hover = DARK_HOVER_FILL,
	header_bg = 0x00342C25, row_alt = 0x002E2722,
	tooltip_bg = 0x00382F28, tooltip_border = 0x00907050,
	splitter_hot = DARK_HOVER_FILL, tag_preview = DARK_HOVER_FILL, section_head = DARK_HOVER_FILL,
	zoom_selection = 0x0020415A, // rgb(90,65,32)
}

// Fixed accents: the same in both themes, typed like the palette variables.
C_ACCENT :: windows.COLORREF(0x0030A0F0) // rgb(240,160,48) - selected lane, ManicTime orange
C_GREEN  :: windows.COLORREF(0x0087C94C) // rgb(76,201,135)
C_ORANGE :: windows.COLORREF(0x0050A0F0) // rgb(240,160,80)
C_RED    :: windows.COLORREF(0x005A5ADE) // rgb(222,90,90)

// Active palette, mirrored into the C_* variables below by palette_apply.
palette_active: Palette = PALETTE_LIGHT

C_BG:             windows.COLORREF = PALETTE_LIGHT.bg
C_PANEL:          windows.COLORREF = PALETTE_LIGHT.panel
C_BORDER:         windows.COLORREF = PALETTE_LIGHT.border
C_BORDER_SOFT:    windows.COLORREF = PALETTE_LIGHT.border_soft
C_LANE_BG:        windows.COLORREF = PALETTE_LIGHT.lane_bg
C_LANE_GRID:      windows.COLORREF = PALETTE_LIGHT.lane_grid
C_LANE_TXT:       windows.COLORREF = PALETTE_LIGHT.lane_text
C_TXT:            windows.COLORREF = PALETTE_LIGHT.text
C_DIM:            windows.COLORREF = PALETTE_LIGHT.text_dim
C_TAB_BG:         windows.COLORREF = PALETTE_LIGHT.tab_bg
C_TAB_ACTIVE:     windows.COLORREF = PALETTE_LIGHT.tab_active
C_BTN_FACE:       windows.COLORREF = PALETTE_LIGHT.button_face
C_BTN_BORDER:     windows.COLORREF = PALETTE_LIGHT.button_border
C_BTN_HOVER:      windows.COLORREF = PALETTE_LIGHT.button_hover
C_HEAD_BG:        windows.COLORREF = PALETTE_LIGHT.header_bg
C_ROW_ALT:        windows.COLORREF = PALETTE_LIGHT.row_alt
C_TIP_BG:         windows.COLORREF = PALETTE_LIGHT.tooltip_bg
C_TIP_BORDER:     windows.COLORREF = PALETTE_LIGHT.tooltip_border
C_SPLITTER_HOT:   windows.COLORREF = PALETTE_LIGHT.splitter_hot
C_TAG_PREVIEW:    windows.COLORREF = PALETTE_LIGHT.tag_preview
C_SECTION_HEAD:   windows.COLORREF = PALETTE_LIGHT.section_head
C_ZOOM_SELECTION: windows.COLORREF = PALETTE_LIGHT.zoom_selection

palette_apply :: proc(p: Palette) {
	palette_active = p
	C_BG, C_PANEL, C_BORDER, C_BORDER_SOFT = p.bg, p.panel, p.border, p.border_soft
	C_LANE_BG, C_LANE_GRID, C_LANE_TXT = p.lane_bg, p.lane_grid, p.lane_text
	C_TXT, C_DIM = p.text, p.text_dim
	C_TAB_BG, C_TAB_ACTIVE = p.tab_bg, p.tab_active
	C_BTN_FACE, C_BTN_BORDER, C_BTN_HOVER = p.button_face, p.button_border, p.button_hover
	C_HEAD_BG, C_ROW_ALT = p.header_bg, p.row_alt
	C_TIP_BG, C_TIP_BORDER = p.tooltip_bg, p.tooltip_border
	C_SPLITTER_HOT, C_TAG_PREVIEW, C_SECTION_HEAD = p.splitter_hot, p.tag_preview, p.section_head
	C_ZOOM_SELECTION = p.zoom_selection
}

// True when every C_* variable holds the value of the active palette.
palette_is_applied :: proc() -> bool {
	p := palette_active
	return C_BG == p.bg && C_PANEL == p.panel && C_BORDER == p.border && C_BORDER_SOFT == p.border_soft &&
		C_LANE_BG == p.lane_bg && C_LANE_GRID == p.lane_grid && C_LANE_TXT == p.lane_text &&
		C_TXT == p.text && C_DIM == p.text_dim && C_TAB_BG == p.tab_bg && C_TAB_ACTIVE == p.tab_active &&
		C_BTN_FACE == p.button_face && C_BTN_BORDER == p.button_border && C_BTN_HOVER == p.button_hover &&
		C_HEAD_BG == p.header_bg && C_ROW_ALT == p.row_alt && C_TIP_BG == p.tooltip_bg &&
		C_TIP_BORDER == p.tooltip_border && C_SPLITTER_HOT == p.splitter_hot &&
		C_TAG_PREVIEW == p.tag_preview && C_SECTION_HEAD == p.section_head &&
		C_ZOOM_SELECTION == p.zoom_selection
}
