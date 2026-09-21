//! Canonical, renderer-independent terminal state owned by the daemon.
//!
//! Checkpoints describe bounded terminal state, not a tail of PTY output. The
//! caller takes them under the same lock as parsing and output sequencing.
// Share the renderer-neutral protocol implementation and its MIT attribution.
#[allow(dead_code)]
#[path = "../../Vendor/alacritty-bridge/src/kitty_graphics.rs"]
mod kitty_graphics;
#[allow(dead_code)]
#[path = "../../Vendor/alacritty-bridge/src/kitty_graphics_tracking.rs"]
mod kitty_graphics_tracking;
use alacritty_terminal::{
    event::{Event, EventListener, WindowSize},
    grid::{Cursor, Dimensions, Grid},
    index::{Column, Line},
    term::{
        Config, Osc52, Term, TermMode,
        cell::{Cell, Flags},
    },
    vte::ansi::{self, CharsetIndex, Color, CursorShape, Rgb, StandardCharset},
};
use kitty_graphics::{
    KittyGraphicsInterceptor, KittyGraphicsItem, KittyGraphicsScreen, KittyGraphicsSize,
    KittyGraphicsState,
};
use kitty_graphics_tracking::{
    KittyGraphicsCursorTracker, advance_cursor, advance_text, finish_sync,
};
use std::sync::{Arc, Mutex};

const HISTORY_CELLS: usize = 500_000;
const MAX_CHECKPOINT: usize = 32 * 1024 * 1024;

#[derive(Clone, Default)]
struct Replies(Arc<Mutex<Vec<Event>>>);
impl EventListener for Replies {
    fn send_event(&self, event: Event) {
        // Clipboard/notification side effects are never performed by the
        // canonical parser. Queries are answered here even without a GUI.
        if matches!(
            event,
            Event::PtyWrite(_) | Event::ColorRequest(..) | Event::TextAreaSizeRequest(_)
        ) {
            let mut replies = self.0.lock().unwrap();
            if replies.len() < 4096 {
                replies.push(event);
            }
        }
    }
}

pub struct TerminalState {
    graphics: KittyGraphicsState,
    graphics_parser: KittyGraphicsInterceptor,
    graphics_tracker: KittyGraphicsCursorTracker,
    term: Term<Replies>,
    parser: ansi::Processor,
    replies: Replies,
    size: WindowSize,
    defaults: std::collections::BTreeMap<usize, Rgb>,
    default_cursor: ansi::CursorStyle,
}
struct Size(usize, usize);
impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.1
    }
    fn screen_lines(&self) -> usize {
        self.1
    }
    fn columns(&self) -> usize {
        self.0
    }
}
impl TerminalState {
    pub fn bracketed_paste(&self) -> bool {
        self.term.mode().contains(TermMode::BRACKETED_PASTE)
    }
    pub fn new(columns: u16, rows: u16, cell_width: u16, cell_height: u16) -> Self {
        let replies = Replies::default();
        let config = Config {
            scrolling_history: (HISTORY_CELLS / usize::from(columns)).min(10_000),
            kitty_keyboard: true,
            default_cursor_style: ansi::CursorStyle {
                shape: CursorShape::Block,
                blinking: true,
            },
            osc52: Osc52::Disabled,
            ..Config::default()
        };
        Self {
            graphics: KittyGraphicsState::canonical(),
            graphics_parser: KittyGraphicsInterceptor::canonical(),
            graphics_tracker: KittyGraphicsCursorTracker::default(),
            term: Term::new(config, &Size(columns.into(), rows.into()), replies.clone()),
            parser: ansi::Processor::new(),
            replies,
            defaults: Default::default(),
            default_cursor: ansi::CursorStyle {
                shape: CursorShape::Block,
                blinking: true,
            },
            size: WindowSize {
                num_cols: columns,
                num_lines: rows,
                cell_width,
                cell_height,
            },
        }
    }
    pub fn colors(&mut self, colors: std::collections::BTreeMap<usize, [u8; 3]>) {
        self.defaults = colors
            .into_iter()
            .filter(|(index, _)| *index <= 258)
            .map(|(index, [r, g, b])| (index, Rgb { r, g, b }))
            .collect();
    }
    pub fn cursor_default(&mut self, value: u8) {
        self.default_cursor = ansi::CursorStyle {
            shape: match value {
                3 | 4 => CursorShape::Underline,
                5 | 6 => CursorShape::Beam,
                _ => CursorShape::Block,
            },
            blinking: value % 2 == 1,
        };
        self.resize(
            self.size.num_cols,
            self.size.num_lines,
            self.size.cell_width,
            self.size.cell_height,
        );
    }
    pub fn resize(&mut self, columns: u16, rows: u16, cell_width: u16, cell_height: u16) {
        self.size = WindowSize {
            num_cols: columns,
            num_lines: rows,
            cell_width,
            cell_height,
        };
        self.term.resize(Size(columns.into(), rows.into()));
        // Keep the history allocation bounded when a client makes a very wide
        // terminal; the limit is cells, not just a fixed number of lines.
        self.term.set_options(Config {
            scrolling_history: (HISTORY_CELLS / usize::from(columns)).min(10_000),
            kitty_keyboard: true,
            osc52: Osc52::Disabled,
            default_cursor_style: self.default_cursor,
            ..Config::default()
        });
    }
    /// Returns protocol responses, never user input. The daemon writes these
    /// to the PTY exactly once; renderer emulators have responses disabled.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<u8> {
        let mut replies = Vec::new();
        for item in self.graphics_parser.process(bytes) {
            match item {
                KittyGraphicsItem::Text(text) => {
                    let track = self.graphics.has_placements();
                    advance_text(
                        &mut self.graphics_tracker,
                        &mut self.parser,
                        &mut self.term,
                        &text,
                        track,
                    )
                    .apply_to(&mut self.graphics);
                    replies.extend(self.take_replies());
                }
                KittyGraphicsItem::Command(command) => {
                    if self.parser.sync_bytes_count() > 0 {
                        self.finish_sync();
                    }
                    replies.extend(self.take_replies());
                    let screen = KittyGraphicsScreen::from_alternate_screen(
                        self.term.mode().contains(TermMode::ALT_SCREEN),
                    );
                    let point = self.term.grid().cursor.point;
                    let size = KittyGraphicsSize {
                        columns: self.size.num_cols.into(),
                        rows: self.size.num_lines.into(),
                        cell_width: self.size.cell_width.into(),
                        cell_height: self.size.cell_height.into(),
                    };
                    let result = self.graphics.apply(
                        command,
                        point.column.0,
                        point.line.0.max(0) as usize,
                        self.term.grid().history_size(),
                        size,
                        screen,
                    );
                    if let Some(response) = result.response {
                        replies.extend(response);
                    }
                    if result.cursor_advance_screen == Some(screen) {
                        if let Some((columns, rows)) = result.cursor_advance {
                            let full = self
                                .graphics_tracker
                                .region_covers_full_screen(self.term.grid().screen_lines());
                            let scrolled = advance_cursor(&mut self.term, columns, rows, full);
                            self.graphics.scroll_up_without_history(scrolled, screen);
                        }
                    }
                }
            }
        }
        replies
    }
    fn finish_sync(&mut self) {
        let track = self.graphics.has_placements();
        finish_sync(
            &mut self.graphics_tracker,
            &mut self.parser,
            &mut self.term,
            track,
        )
        .apply_to(&mut self.graphics);
    }
    pub fn tick(&mut self) -> Vec<u8> {
        if self
            .parser
            .sync_timeout()
            .sync_timeout()
            .is_some_and(|deadline| deadline <= std::time::Instant::now())
        {
            self.finish_sync();
        }
        self.take_replies()
    }
    fn take_replies(&mut self) -> Vec<u8> {
        let mut output = Vec::new();
        for event in self.replies.0.lock().unwrap().drain(..) {
            let reply = match event {
                Event::PtyWrite(text) => text,
                Event::ColorRequest(index, format) => {
                    format(self.term.colors()[index].unwrap_or_else(|| {
                        self.defaults
                            .get(&index)
                            .copied()
                            .unwrap_or_else(|| default_color(index))
                    }))
                }
                Event::TextAreaSizeRequest(format) => format(self.size),
                _ => continue,
            };
            output.extend_from_slice(reply.as_bytes());
        }
        output
    }
    /// Visible cells, used to verify semantic restoration independently of
    /// the escape encoding chosen for checkpoints.
    pub fn screen_text(&self) -> String {
        let grid = self.term.grid();
        (0..grid.screen_lines())
            .map(|row| {
                grid[Line(row as i32)][..]
                    .iter()
                    .filter(|cell| !cell.flags.contains(Flags::WIDE_CHAR_SPACER))
                    .map(|cell| cell.c)
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
    /// A cold restart restores primary history only. No application modes,
    /// alternate screen, or unfinished control sequence is carried to a new shell.
    pub fn recovery_history(&self) -> Vec<u8> {
        let primary = if self.term.mode().contains(TermMode::ALT_SCREEN) {
            self.term.inactive_grid()
        } else {
            self.term.grid()
        };
        let mut trimmed = primary.clone();
        trimmed.update_history(500);
        let mut bytes = b"\x1bc".to_vec();
        grid(&mut bytes, &trimmed, None);
        bytes.extend_from_slice(b"\x1b[0m\r\n[Kero: daemon restarted; new shell. Previous tasks were not restarted.]\r\n");
        bytes
    }
    pub fn checkpoint(&self) -> Result<Vec<u8>, &'static str> {
        let tail = self
            .parser
            .checkpoint_pending()
            .ok_or("incomplete terminal sequence exceeds limit")?;
        let mut output = b"\x18\x1bc".to_vec();
        let mode = *self.term.mode();
        // Rebuild the primary screen before entering the alternate screen so
        // an application's later rmcup returns to the original shell prompt.
        let primary = if mode.contains(TermMode::ALT_SCREEN) {
            self.term.inactive_grid()
        } else {
            self.term.grid()
        };
        self.graphics
            .checkpoint_images(&mut output, KittyGraphicsScreen::Primary);
        grid(
            &mut output,
            primary,
            Some((&self.graphics, KittyGraphicsScreen::Primary)),
        );
        cursor(&mut output, &primary.saved_cursor, primary);
        output.extend_from_slice(b"\x1b7");
        cursor(&mut output, &primary.cursor, primary);
        let (active_keys, inactive_keys) = self.term.checkpoint_keyboard_stacks();
        keyboard(
            &mut output,
            if mode.contains(TermMode::ALT_SCREEN) {
                inactive_keys
            } else {
                active_keys
            },
        );
        if mode.contains(TermMode::ALT_SCREEN) {
            output.extend_from_slice(b"\x1b[?1049h\x1b[H\x1b[0m");
            self.graphics
                .checkpoint_images(&mut output, KittyGraphicsScreen::Alternate);
            grid(
                &mut output,
                self.term.grid(),
                Some((&self.graphics, KittyGraphicsScreen::Alternate)),
            );
            keyboard(&mut output, active_keys);
        }
        // Palette references stay references; baking them into RGB would make
        // later OSC palette changes affect new output but not restored cells.
        for index in 0..alacritty_terminal::term::color::COUNT {
            if let Some(rgb) = self.term.colors()[index] {
                let command = match index {
                    0..=255 => format!("4;{index}"),
                    256 => "10".into(),
                    257 => "11".into(),
                    258 => "12".into(),
                    _ => continue,
                };
                push(
                    &mut output,
                    format!(
                        "\x1b]{command};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
                        rgb.r, rgb.g, rgb.b
                    ),
                );
            }
        }
        self.graphics.checkpoint_upload(&mut output);
        let region = self.term.checkpoint_scroll_region();
        push(
            &mut output,
            format!("\x1b[{};{}r", region.start.0 + 1, region.end.0),
        );
        output.extend_from_slice(b"\x1b[3g");
        for (col, enabled) in self.term.checkpoint_tabs().iter().enumerate() {
            if *enabled {
                push(&mut output, format!("\x1b[1;{}H\x1bH", col + 1));
            }
        }
        // Cursor positioning is absolute while DECOM is off. Enable it only
        // after the scroll region and saved cursor have been reconstructed.
        cursor(
            &mut output,
            &self.term.grid().saved_cursor,
            self.term.grid(),
        );
        output.extend_from_slice(b"\x1b7");
        for (flag, number) in [
            (TermMode::APP_CURSOR, 1),
            (TermMode::LINE_WRAP, 7),
            (TermMode::SHOW_CURSOR, 25),
            (TermMode::MOUSE_REPORT_CLICK, 1000),
            (TermMode::MOUSE_DRAG, 1002),
            (TermMode::MOUSE_MOTION, 1003),
            (TermMode::FOCUS_IN_OUT, 1004),
            (TermMode::UTF8_MOUSE, 1005),
            (TermMode::SGR_MOUSE, 1006),
            (TermMode::ALTERNATE_SCROLL, 1007),
            (TermMode::URGENCY_HINTS, 1042),
            (TermMode::BRACKETED_PASTE, 2004),
        ] {
            push(
                &mut output,
                format!(
                    "\x1b[?{number}{}",
                    if mode.contains(flag) { 'h' } else { 'l' }
                ),
            );
        }
        output.extend_from_slice(if mode.contains(TermMode::APP_KEYPAD) {
            b"\x1b="
        } else {
            b"\x1b>"
        });
        if mode.contains(TermMode::ORIGIN) {
            output.extend_from_slice(b"\x1b[?6h");
        }
        let mut position = self.term.grid().cursor.clone();
        if mode.contains(TermMode::ORIGIN) {
            position.point.line.0 -= region.start.0;
        }
        // Repaint a pending-wrap margin using the original grid coordinates.
        cursor_at(
            &mut output,
            &position,
            &self.term.grid().cursor,
            self.term.grid(),
        );
        for (flag, number) in [(TermMode::INSERT, 4), (TermMode::LINE_FEED_NEW_LINE, 20)] {
            push(
                &mut output,
                format!(
                    "\x1b[{number}{}",
                    if mode.contains(flag) { 'h' } else { 'l' }
                ),
            );
        }
        let style = self.term.cursor_style();
        let shape = match style.shape {
            CursorShape::Underline => 3,
            CursorShape::Beam => 5,
            _ => 1,
        } + u8::from(!style.blinking);
        push(&mut output, format!("\x1b[{shape} q"));
        output.extend_from_slice(match self.term.checkpoint_charset() {
            CharsetIndex::G0 => b"\x0f",
            CharsetIndex::G1 => b"\x0e",
            CharsetIndex::G2 => b"\x1bn",
            CharsetIndex::G3 => b"\x1bo",
        });
        let (title, titles) = self.term.checkpoint_titles();
        for saved in titles {
            title_osc(&mut output, saved);
            output.extend_from_slice(b"\x1b[22;0t");
        }
        title_osc(&mut output, title);
        let preceding = self
            .parser
            .checkpoint_preceding()
            .map(|c| c as u32)
            .unwrap_or(0);
        push(
            &mut output,
            format!("\x1b[>997;{};{}z", preceding >> 16, preceding & 65535),
        );
        output.extend_from_slice(&tail);
        output.extend_from_slice(&self.graphics_parser.checkpoint_pending()?);
        if output.len() > MAX_CHECKPOINT {
            return Err("terminal checkpoint exceeds limit");
        }
        Ok(output)
    }
}
fn push(output: &mut Vec<u8>, text: String) {
    output.extend_from_slice(text.as_bytes());
}
fn title_osc(output: &mut Vec<u8>, title: &Option<String>) {
    // A title is metadata, never executable escape bytes from a process.
    let title: String = title
        .as_deref()
        .unwrap_or("")
        .chars()
        .filter(|c| !c.is_control())
        .collect();
    push(output, format!("\x1b]2;{title}\x1b\\"));
}
fn keyboard(output: &mut Vec<u8>, stack: &[ansi::KeyboardModes]) {
    output.extend_from_slice(b"\x1b[<65535u");
    for mode in stack {
        push(output, format!("\x1b[>{}u", mode.bits()));
    }
}
fn sgr(output: &mut Vec<u8>, cell: &Cell) {
    let mut codes = vec!["0".to_owned()];
    for (flag, code) in [
        (Flags::BOLD, "1"),
        (Flags::DIM, "2"),
        (Flags::ITALIC, "3"),
        (Flags::INVERSE, "7"),
        (Flags::HIDDEN, "8"),
        (Flags::STRIKEOUT, "9"),
        (Flags::UNDERLINE, "4"),
        (Flags::DOUBLE_UNDERLINE, "4:2"),
        (Flags::UNDERCURL, "4:3"),
        (Flags::DOTTED_UNDERLINE, "4:4"),
        (Flags::DASHED_UNDERLINE, "4:5"),
    ] {
        if cell.flags.contains(flag) {
            codes.push(code.into());
        }
    }
    for (color, foreground) in [(cell.fg, true), (cell.bg, false)] {
        codes.push(match color {
            Color::Spec(rgb) => format!(
                "{};2;{};{};{}",
                if foreground { 38 } else { 48 },
                rgb.r,
                rgb.g,
                rgb.b
            ),
            Color::Indexed(i) => format!("{};5;{i}", if foreground { 38 } else { 48 }),
            Color::Named(name) if (name as usize) < 8 => {
                format!("{}", (if foreground { 30 } else { 40 }) + name as usize)
            }
            Color::Named(name) if (name as usize) < 16 => format!(
                "{}",
                (if foreground { 90 } else { 100 }) + name as usize - 8
            ),
            _ => if foreground { "39" } else { "49" }.into(),
        });
    }
    if let Some(color) = cell.underline_color() {
        codes.push(match color {
            Color::Spec(rgb) => format!("58;2;{};{};{}", rgb.r, rgb.g, rgb.b),
            Color::Indexed(i) => format!("58;5;{i}"),
            Color::Named(n) => format!("58;5;{}", n as usize),
        });
    }
    push(output, format!("\x1b[{}m", codes.join(";")));
    push(
        output,
        format!(
            "\x1b]8;;{}\x1b\\",
            cell.hyperlink()
                .map(|l| l.uri().to_owned())
                .unwrap_or_default()
        ),
    );
}
fn text(output: &mut Vec<u8>, cell: &Cell) {
    let mut utf8 = [0; 4];
    output.extend_from_slice(cell.c.encode_utf8(&mut utf8).as_bytes());
    for mark in cell.zerowidth().into_iter().flatten() {
        output.extend_from_slice(mark.encode_utf8(&mut utf8).as_bytes());
    }
}
fn grid(
    output: &mut Vec<u8>,
    grid: &Grid<Cell>,
    graphics: Option<(&KittyGraphicsState, KittyGraphicsScreen)>,
) {
    let mut previous: Option<Cell> = None;
    for row in grid.topmost_line().0..=grid.bottommost_line().0 {
        let line = &grid[Line(row)];
        let wrapped = line[Column(grid.columns() - 1)]
            .flags
            .contains(Flags::WRAPLINE);
        let end = if wrapped {
            grid.columns()
        } else {
            line[..]
                .iter()
                .rposition(|cell| cell != &Cell::default())
                .map_or(0, |i| i + 1)
        };
        for column in 0..end {
            let cell = &line[Column(column)];
            if cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }
            if previous.as_ref().is_none_or(|p| {
                p.fg != cell.fg
                    || p.bg != cell.bg
                    || p.flags != cell.flags
                    || p.hyperlink() != cell.hyperlink()
                    || p.underline_color() != cell.underline_color()
            }) {
                sgr(output, cell);
                previous = Some(cell.clone());
            }
            text(output, cell);
        }
        if let Some((graphics, screen)) = graphics {
            let line = i64::from(row) + grid.history_size() as i64;
            graphics.checkpoint_row(
                output,
                screen,
                line,
                (line as usize).min(grid.screen_lines() - 1),
            );
        }
        if !wrapped && row != grid.bottommost_line().0 {
            output.extend_from_slice(b"\x1b[0m\x1b]8;;\x1b\\\r\n");
            previous = None;
        }
    }
    output.extend_from_slice(b"\x1b[0m\x1b]8;;\x1b\\");
}
fn cursor(output: &mut Vec<u8>, cursor: &Cursor<Cell>, grid: &Grid<Cell>) {
    cursor_at(output, cursor, cursor, grid);
}
fn cursor_at(
    output: &mut Vec<u8>,
    position: &Cursor<Cell>,
    actual: &Cursor<Cell>,
    grid: &Grid<Cell>,
) {
    push(
        output,
        format!(
            "\x1b[{};{}H",
            position.point.line.0.max(0) + 1,
            position.point.column.0 + 1
        ),
    );
    if actual.input_needs_wrap {
        let mut col = actual.point.column.0;
        if grid[actual.point.line][Column(col)]
            .flags
            .contains(Flags::WIDE_CHAR_SPACER)
        {
            col = col.saturating_sub(1);
            output.extend_from_slice(b"\x1b[D");
        }
        let cell = &grid[actual.point.line][Column(col)];
        sgr(output, cell);
        text(output, cell);
    }
    sgr(output, &actual.template);
    for (index, byte) in [
        (CharsetIndex::G0, b'('),
        (CharsetIndex::G1, b')'),
        (CharsetIndex::G2, b'*'),
        (CharsetIndex::G3, b'+'),
    ] {
        output.extend_from_slice(&[
            0x1b,
            byte,
            if actual.charsets[index] == StandardCharset::SpecialCharacterAndLineDrawing {
                b'0'
            } else {
                b'B'
            },
        ]);
    }
}
fn default_color(index: usize) -> Rgb {
    const BASE: [u32; 16] = [
        0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5, 0x7f7f7f,
        0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
    ];
    let value = match index {
        0..=15 => BASE[index],
        16..=231 => {
            let i = index - 16;
            let component = |c: usize| if c == 0 { 0 } else { 55 + 40 * c };
            (component(i / 36) << 16 | component(i / 6 % 6) << 8 | component(i % 6)) as u32
        }
        232..=255 => {
            let c = (8 + (index - 232) * 10) as u32;
            c << 16 | c << 8 | c
        }
        257 => 0,
        _ => 0xe5e5e5,
    };
    Rgb {
        r: (value >> 16) as u8,
        g: (value >> 8) as u8,
        b: value as u8,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn same(a: &TerminalState, b: &TerminalState) {
        assert_eq!(
            a.parser.checkpoint_preceding(),
            b.parser.checkpoint_preceding(),
            "REP state"
        );
        assert_eq!(a.term.mode(), b.term.mode(), "mode");
        assert_eq!(a.term.grid().cursor, b.term.grid().cursor, "cursor");
        assert_eq!(
            a.term.checkpoint_scroll_region(),
            b.term.checkpoint_scroll_region()
        );
        assert_eq!(a.term.checkpoint_tabs(), b.term.checkpoint_tabs());
        let grids = [
            (a.term.grid(), b.term.grid()),
            (a.term.inactive_grid(), b.term.inactive_grid()),
        ];
        for (index, (a, b)) in grids.into_iter().enumerate() {
            if index == 1 && !a.screen_lines().eq(&b.screen_lines()) {
                continue;
            }
            assert_eq!(a.topmost_line(), b.topmost_line(), "history {index}");
            for row in a.topmost_line().0..=a.bottommost_line().0 {
                for col in 0..a.columns() {
                    assert_eq!(
                        a[Line(row)][Column(col)],
                        b[Line(row)][Column(col)],
                        "grid {index} row {row} col {col}"
                    );
                }
            }
        }
    }
    fn image_state(state: &TerminalState, screen: KittyGraphicsScreen) -> Vec<String> {
        image_state_at(state, screen, 0)
    }
    fn image_state_at(
        state: &TerminalState,
        screen: KittyGraphicsScreen,
        offset: usize,
    ) -> Vec<String> {
        let grid = if state.term.mode().contains(TermMode::ALT_SCREEN)
            == (screen == KittyGraphicsScreen::Alternate)
        {
            state.term.grid()
        } else {
            state.term.inactive_grid()
        };
        state
            .graphics
            .render_placements(
                grid.history_size(),
                offset,
                grid.screen_lines(),
                grid.columns(),
                screen,
            )
            .iter()
            .map(|p| {
                format!(
                    "{}:{}:{:?}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}",
                    p.image_id,
                    p.placement_id,
                    p.png,
                    p.viewport_row,
                    p.column,
                    p.source_x,
                    p.source_y,
                    p.source_width,
                    p.source_height,
                    p.display_columns,
                    p.display_rows,
                    p.x_offset,
                    p.y_offset
                )
            })
            .collect()
    }
    #[test]
    fn images_and_split_uploads_restore_without_protocol_side_effects() {
        let input = b"primary\r\n\x1b_Ga=T,f=32,s=1,v=1,i=42,p=7,c=2,r=1;/wAA/w==\x1b\\after\r\n\x1b[?1049h\x1b[3;4H\x1b_Ga=T,f=32,s=1,v=1,i=43,p=8,c=3,r=2,m=1;AP8A\x1b\\\x1b_Gm=0;/w==\x1b\\tail";
        for cut in 0..=input.len() {
            let mut a = TerminalState::new(20, 10, 8, 16);
            a.feed(&input[..cut]);
            let mut b = TerminalState::new(20, 10, 8, 16);
            b.feed(&a.checkpoint().unwrap());
            a.feed(&input[cut..]);
            b.feed(&input[cut..]);
            same(&a, &b);
            for screen in [KittyGraphicsScreen::Primary, KittyGraphicsScreen::Alternate] {
                assert_eq!(
                    image_state(&a, screen),
                    image_state(&b, screen),
                    "cut {cut}"
                );
            }
            let query = b"\x1b_Ga=q,f=32,s=1,v=1,i=99;/wAA/w==\x1b\\";
            assert_eq!(a.feed(query), b"\x1b_Gi=99;OK\x1b\\");
        }
    }
    #[test]
    fn chunked_image_uses_final_cursor_after_text_scrolls() {
        let mut a = TerminalState::new(20, 10, 8, 16);
        a.feed(b"\x1b_Ga=T,f=32,s=1,v=1,i=43,c=2,r=1,C=1,m=1;AP8A\x1b\\");
        for _ in 0..20 {
            a.feed(b"between-chunks\r\n");
        }
        let mut b = TerminalState::new(20, 10, 8, 16);
        b.feed(&a.checkpoint().unwrap());
        a.feed(b"\x1b_Gm=0;/w==\x1b\\");
        b.feed(b"\x1b_Gm=0;/w==\x1b\\");
        assert_eq!(
            image_state(&a, KittyGraphicsScreen::Primary),
            image_state(&b, KittyGraphicsScreen::Primary)
        );
        same(&a, &b);
    }
    #[test]
    fn image_anchors_survive_scrollback_and_wrapped_rows() {
        let mut a = TerminalState::new(20, 10, 8, 16);
        a.feed(b"\x1b_Ga=T,f=32,s=1,v=1,i=42,p=7,c=2,r=1;/wAA/w==\x1b\\");
        a.feed(b"12345678901234567890123456789012345678901234567890\r\n");
        for _ in 0..20 {
            a.feed(b"line\r\n");
        }
        a.feed(b"\x1b_Ga=p,i=42,p=8,c=2,r=1;\x1b\\visible");
        let mut b = TerminalState::new(20, 10, 8, 16);
        b.feed(&a.checkpoint().unwrap());
        same(&a, &b);
        for offset in 0..=a.term.grid().history_size() {
            assert_eq!(
                image_state_at(&a, KittyGraphicsScreen::Primary, offset),
                image_state_at(&b, KittyGraphicsScreen::Primary, offset),
                "scrollback offset {offset}"
            );
        }
    }
    #[test]
    fn checkpoint_restores_both_screens_modes_cursor_and_partial_parser() {
        let input = concat!(
            "primary 中文 e\u{301}\r\nsecond\x1b[31mred\x1b[0m",
            "\x1b[?1049h\x1b[2;5r\x1b[3;4Halternate 中",
            "\x1b[?1h\x1b[?2004h\x1b[?1002h\x1b[?1006h",
            "\x1b[3g\x1b[1;3H\x1bH\x1b[3;5H\x1b7\x1b[4;6H",
            "\x1b[38;2;100;150;200m终"
        )
        .as_bytes();
        for cut in 0..=input.len() {
            let mut canonical = TerminalState::new(30, 8, 8, 16);
            canonical.feed(&input[..cut]);
            let mut restored = TerminalState::new(30, 8, 8, 16);
            restored.feed(&canonical.checkpoint().unwrap());
            canonical.feed(&input[cut..]);
            restored.feed(&input[cut..]);
            same(&canonical, &restored);
            canonical.feed(b"\x1b[?1049lAFTER");
            restored.feed(b"\x1b[?1049lAFTER");
            same(&canonical, &restored);
        }
    }
    #[test]
    fn erased_preceding_character_and_split_rep_continue_identically() {
        for text in ["Z", "中", "🦀"] {
            let mut original = TerminalState::new(20, 5, 8, 16);
            original.feed(format!("{text}\x1b[2J\x1b[H\x1b[3").as_bytes());
            let mut restored = TerminalState::new(20, 5, 8, 16);
            restored.feed(&original.checkpoint().unwrap());
            original.feed(b"b");
            restored.feed(b"b");
            same(&original, &restored);
        }
    }
    #[test]
    fn bounded_history_restores_after_output_far_larger_than_checkpoint() {
        let mut canonical = TerminalState::new(40, 10, 8, 16);
        for i in 0..50_000 {
            canonical.feed(format!("line {i:08}\r\n").as_bytes());
        }
        let checkpoint = canonical.checkpoint().unwrap();
        assert!(checkpoint.len() < 800_000);
        let mut restored = TerminalState::new(40, 10, 8, 16);
        restored.feed(&checkpoint);
        same(&canonical, &restored);
        assert_eq!(canonical.feed(b"\x1b[6n"), restored.feed(b"\x1b[6n"));
    }
    #[test]
    fn margin_wrap_origin_charsets_and_saved_cursor_continue_identically() {
        for input in [
            b"12345678".as_slice(),
            b"\x1b[2;4r\x1b[?6h\x1b[2;1Habcdefgh",
            b"\x1b(0lqqk\x1b7\x1b[3;1Hx",
        ] {
            let mut canonical = TerminalState::new(8, 6, 8, 16);
            canonical.feed(input);
            let mut restored = TerminalState::new(8, 6, 8, 16);
            restored.feed(&canonical.checkpoint().unwrap());
            canonical.feed(b"123\x1b8Z");
            restored.feed(b"123\x1b8Z");
            same(&canonical, &restored);
        }
    }
}

#[cfg(test)]
struct TermSize {
    columns: usize,
    screen_lines: usize,
}
#[cfg(test)]
impl Dimensions for TermSize {
    fn total_lines(&self) -> usize {
        self.screen_lines
    }
    fn screen_lines(&self) -> usize {
        self.screen_lines
    }
    fn columns(&self) -> usize {
        self.columns
    }
}
