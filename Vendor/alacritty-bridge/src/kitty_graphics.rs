//! Renderer-neutral Kitty graphics protocol support.
//!
//! Adapted from Termy's implementation at
//! https://github.com/lassejlv/termy/tree/d094009217c278701abdecf906dc1903e6b01bc5
//! under the MIT license in `../TERMY_LICENSE`.

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use flate2::read::ZlibDecoder;
use std::{
    collections::{HashMap, VecDeque},
    fs::File,
    io::{Cursor, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::Arc,
};

const MAX_IMAGE_BYTES: usize = 128 * 1024 * 1024;
const MAX_COMMAND_BYTES: usize = MAX_IMAGE_BYTES * 2;
const MAX_DIMENSION: u32 = 32_768;
const MAX_PIXELS: u64 = (MAX_IMAGE_BYTES / 4) as u64;

#[derive(Clone, Copy, Debug)]
pub(crate) struct KittyGraphicsSize {
    pub(crate) columns: usize,
    pub(crate) rows: usize,
    pub(crate) cell_width: f32,
    pub(crate) cell_height: f32,
}

#[derive(Clone, Debug)]
pub(crate) struct KittyGraphicsCommand {
    control: Vec<(char, String)>,
    payload: Vec<u8>,
    oversized: bool,
}

impl KittyGraphicsCommand {
    /// Remote streams may carry pixels, never paths in the renderer's
    /// filesystem. Reject unknown/malformed media too, rather than relying
    /// on another emulator's interpretation of them.
    pub(crate) fn is_inline(&self) -> bool {
        !self.oversized
            && self.control.iter().all(|(key, value)| {
                key.is_ascii_alphabetic()
                    && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"+-".contains(&byte))
                    && (*key != 't' || value == "d")
            })
            // Never re-emit embedded control sequences for another emulator
            // to reinterpret as a new command outside our validation.
            && self.payload.iter().all(|byte| byte.is_ascii_alphanumeric() || b"+/=".contains(byte))
    }

    pub(crate) fn encode(&self, output: &mut Vec<u8>) {
        output.extend_from_slice(b"\x1b_G");
        for (index, (key, value)) in self.control.iter().enumerate() {
            if index != 0 {
                output.push(b',');
            }
            output.push(*key as u8);
            output.push(b'=');
            output.extend_from_slice(value.as_bytes());
        }
        output.push(b';');
        output.extend_from_slice(&self.payload);
        output.extend_from_slice(b"\x1b\\");
    }

    fn parse(bytes: Vec<u8>, oversized: bool) -> Self {
        let separator = bytes.iter().position(|byte| *byte == b';');
        let (control, payload) = match separator {
            Some(index) => (&bytes[..index], bytes[index + 1..].to_vec()),
            None => (bytes.as_slice(), Vec::new()),
        };
        let control = String::from_utf8_lossy(control)
            .split(',')
            .filter_map(|field| {
                let (key, value) = field.split_once('=')?;
                let mut chars = key.chars();
                let key = chars.next()?;
                (chars.next().is_none() && key.is_ascii()).then(|| (key, value.to_owned()))
            })
            .collect();
        Self {
            control,
            payload,
            oversized,
        }
    }

    fn value(&self, key: char) -> Option<&str> {
        self.control
            .iter()
            .rev()
            .find_map(|(candidate, value)| (*candidate == key).then_some(value.as_str()))
    }

    fn char_value(&self, key: char) -> Option<char> {
        let mut chars = self.value(key)?.chars();
        let value = chars.next()?;
        chars.next().is_none().then_some(value)
    }

    fn u32_value(&self, key: char) -> Option<u32> {
        self.value(key)?.parse().ok()
    }

    fn i32_value(&self, key: char) -> Option<i32> {
        self.value(key)?.parse().ok()
    }
}

#[derive(Clone, Debug)]
pub(crate) enum KittyGraphicsItem {
    Text(Vec<u8>),
    Command(KittyGraphicsCommand),
}

#[derive(Clone, Copy, Debug, Default)]
enum InterceptorState {
    #[default]
    Ground,
    Escape,
    ApcStart {
        c1: bool,
    },
    OtherApc,
    OtherApcEscape,
    Kitty,
    KittyEscape,
}

#[derive(Default)]
pub(crate) struct KittyGraphicsInterceptor {
    state: InterceptorState,
    command: Vec<u8>,
    oversized: bool,
    utf8_continuations: u8,
    drop_other_apc: bool,
    command_limit: usize,
}

impl KittyGraphicsInterceptor {
    pub(crate) fn canonical() -> Self {
        Self {
            command_limit: 12 * 1024 * 1024,
            drop_other_apc: true,
            ..Default::default()
        }
    }
    pub(crate) fn checkpoint_pending(&self) -> Result<Vec<u8>, &'static str> {
        if self.oversized {
            return Err("unfinished graphics command exceeds limit");
        }
        let mut bytes = match self.state {
            InterceptorState::Ground => Vec::new(),
            InterceptorState::Escape => b"\x1b".to_vec(),
            InterceptorState::ApcStart { c1: false } => b"\x1b_".to_vec(),
            InterceptorState::ApcStart { c1: true } => vec![0x9f],
            InterceptorState::OtherApc => b"\x1b_X".to_vec(),
            InterceptorState::OtherApcEscape => b"\x1b_X\x1b".to_vec(),
            InterceptorState::Kitty | InterceptorState::KittyEscape => {
                let mut bytes = b"\x1b_G".to_vec();
                bytes.extend_from_slice(&self.command);
                bytes
            }
        };
        if matches!(self.state, InterceptorState::KittyEscape) {
            bytes.push(0x1b);
        }
        Ok(bytes)
    }

    pub(crate) fn remote_filter() -> Self {
        Self {
            drop_other_apc: true,
            ..Self::default()
        }
    }

    pub(crate) fn process(&mut self, bytes: &[u8]) -> Vec<KittyGraphicsItem> {
        let limit = if self.command_limit == 0 {
            MAX_COMMAND_BYTES
        } else {
            self.command_limit
        };
        let mut items = Vec::new();
        let mut text = Vec::with_capacity(bytes.len());
        let flush_text = |items: &mut Vec<KittyGraphicsItem>, text: &mut Vec<u8>| {
            if !text.is_empty() {
                items.push(KittyGraphicsItem::Text(std::mem::take(text)));
            }
        };

        for &byte in bytes {
            match self.state {
                InterceptorState::Ground => {
                    if self.utf8_continuations > 0 && (0x80..=0xbf).contains(&byte) {
                        text.push(byte);
                        self.utf8_continuations -= 1;
                        continue;
                    }
                    self.utf8_continuations = 0;
                    match byte {
                        0x1b => self.state = InterceptorState::Escape,
                        0x9f => self.state = InterceptorState::ApcStart { c1: true },
                        _ => {
                            text.push(byte);
                            self.utf8_continuations = match byte {
                                0xc2..=0xdf => 1,
                                0xe0..=0xef => 2,
                                0xf0..=0xf4 => 3,
                                _ => 0,
                            };
                        }
                    }
                }
                InterceptorState::Escape => {
                    if byte == b'_' {
                        self.state = InterceptorState::ApcStart { c1: false };
                    } else if byte == 0x1b {
                        text.push(0x1b);
                    } else {
                        text.extend_from_slice(&[0x1b, byte]);
                        self.state = InterceptorState::Ground;
                    }
                }
                InterceptorState::ApcStart { c1 } => {
                    if byte == b'G' {
                        flush_text(&mut items, &mut text);
                        self.command.clear();
                        self.oversized = false;
                        self.state = InterceptorState::Kitty;
                    } else {
                        if !self.drop_other_apc {
                            if c1 {
                                text.push(0x9f);
                            } else {
                                text.extend_from_slice(b"\x1b_");
                            }
                            text.push(byte);
                        }
                        self.state = InterceptorState::OtherApc;
                    }
                }
                InterceptorState::OtherApc => {
                    if !self.drop_other_apc {
                        text.push(byte);
                    }
                    if byte == 0x9c {
                        self.state = InterceptorState::Ground;
                    } else if byte == 0x1b {
                        self.state = InterceptorState::OtherApcEscape;
                    }
                }
                InterceptorState::OtherApcEscape => {
                    if !self.drop_other_apc {
                        text.push(byte);
                    }
                    if byte == b'\\' || byte == 0x9c {
                        self.state = InterceptorState::Ground;
                    } else if byte != 0x1b {
                        self.state = InterceptorState::OtherApc;
                    }
                }
                InterceptorState::Kitty => {
                    if byte == 0x1b {
                        self.state = InterceptorState::KittyEscape;
                    } else if byte == 0x9c {
                        flush_text(&mut items, &mut text);
                        items.push(KittyGraphicsItem::Command(KittyGraphicsCommand::parse(
                            std::mem::take(&mut self.command),
                            self.oversized,
                        )));
                        self.state = InterceptorState::Ground;
                    } else if self.command.len() < limit {
                        self.command.push(byte);
                    } else {
                        self.oversized = true;
                    }
                }
                InterceptorState::KittyEscape => {
                    if byte == b'\\' {
                        flush_text(&mut items, &mut text);
                        items.push(KittyGraphicsItem::Command(KittyGraphicsCommand::parse(
                            std::mem::take(&mut self.command),
                            self.oversized,
                        )));
                        self.state = InterceptorState::Ground;
                    } else {
                        if self.command.len() + 2 <= limit {
                            self.command.extend_from_slice(&[0x1b, byte]);
                        } else {
                            self.oversized = true;
                        }
                        self.state = InterceptorState::Kitty;
                    }
                }
            }
        }
        flush_text(&mut items, &mut text);
        items
    }
}

#[derive(Clone, Debug)]
struct StoredImage {
    png: Arc<[u8]>,
    width: u32,
    height: u32,
    byte_len: usize,
    generation: u64,
}

#[derive(Clone, Debug)]
struct Placement {
    placement_serial: u64,
    screen: KittyGraphicsScreen,
    image_id: u32,
    placement_id: u32,
    anchor_line: i64,
    column: usize,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    display_columns: u32,
    display_rows: u32,
    occupied_columns: u32,
    occupied_rows: u32,
    x_offset: u32,
    y_offset: u32,
    z_index: i32,
}

#[derive(Clone, Debug)]
struct PendingUpload {
    command: KittyGraphicsCommand,
    decoded: Vec<u8>,
    context: PlacementContext,
}

#[derive(Clone, Copy, Debug)]
struct PlacementContext {
    cursor_column: usize,
    cursor_row: usize,
    history_size: usize,
    size: KittyGraphicsSize,
    screen: KittyGraphicsScreen,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) enum KittyGraphicsScreen {
    #[default]
    Primary,
    Alternate,
}

impl KittyGraphicsScreen {
    pub(crate) fn from_alternate_screen(alternate_screen: bool) -> Self {
        if alternate_screen {
            Self::Alternate
        } else {
            Self::Primary
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct KittyGraphicsRenderPlacement {
    pub(crate) placement_serial: u64,
    pub(crate) image_id: u32,
    pub(crate) placement_id: u32,
    pub(crate) png: Arc<[u8]>,
    pub(crate) image_width: u32,
    pub(crate) image_height: u32,
    pub(crate) image_generation: u64,
    pub(crate) viewport_row: i32,
    pub(crate) column: usize,
    pub(crate) source_x: u32,
    pub(crate) source_y: u32,
    pub(crate) source_width: u32,
    pub(crate) source_height: u32,
    pub(crate) display_columns: u32,
    pub(crate) display_rows: u32,
    pub(crate) occupied_columns: u32,
    pub(crate) occupied_rows: u32,
    pub(crate) x_offset: u32,
    pub(crate) y_offset: u32,
    pub(crate) z_index: i32,
}

#[derive(Default)]
pub(crate) struct KittyGraphicsApplyResult {
    pub(crate) response: Option<Vec<u8>>,
    pub(crate) cursor_advance: Option<(u32, u32)>,
    pub(crate) cursor_advance_screen: Option<KittyGraphicsScreen>,
    pub(crate) changed: bool,
}

#[derive(Default)]
pub(crate) struct KittyGraphicsState {
    deny_file_transfers: bool,
    storage_limit: usize,
    images: HashMap<(KittyGraphicsScreen, u32), StoredImage>,
    placements: Vec<Placement>,
    insertion_order: VecDeque<(KittyGraphicsScreen, u32)>,
    pending: Option<PendingUpload>,
    next_anonymous_id: u32,
    stored_bytes: usize,
    next_generation: u64,
    next_placement_serial: u64,
}

#[derive(Default)]
pub(crate) struct KittyGraphicsStore {
    pub(crate) state: KittyGraphicsState,
    pub(crate) revision: u64,
}

impl KittyGraphicsStore {
    pub(crate) fn remote() -> Self {
        Self {
            state: KittyGraphicsState {
                deny_file_transfers: true,
                ..Default::default()
            },
            ..Default::default()
        }
    }

    pub(crate) fn mark_changed(&mut self) {
        self.revision = self.revision.wrapping_add(1).max(1);
    }
}

impl KittyGraphicsState {
    pub(crate) fn canonical() -> Self {
        Self {
            deny_file_transfers: true,
            storage_limit: 8 * 1024 * 1024,
            ..Default::default()
        }
    }
    fn byte_limit(&self) -> usize {
        if self.storage_limit == 0 {
            MAX_IMAGE_BYTES
        } else {
            self.storage_limit
        }
    }
    /// Upload once, then place while reconstructing each screen's rows. All
    /// restored payloads are inline pixels; no filesystem reads or replies.
    pub(crate) fn checkpoint_images(&self, output: &mut Vec<u8>, screen: KittyGraphicsScreen) {
        let mut ids: Vec<_> = self
            .images
            .keys()
            .filter_map(|(s, id)| (*s == screen).then_some(*id))
            .collect();
        ids.sort_unstable();
        for id in ids {
            let image = &self.images[&(screen, id)];
            let encoded = BASE64.encode(&image.png);
            let chunks: Vec<_> = encoded.as_bytes().chunks(4096).collect();
            for (index, chunk) in chunks.iter().enumerate() {
                let more = usize::from(index + 1 < chunks.len());
                if index == 0 {
                    output.extend_from_slice(
                        format!("\x1b_Ga=t,f=100,i={id},q=2,m={more};").as_bytes(),
                    );
                } else {
                    output.extend_from_slice(format!("\x1b_Gm={more};").as_bytes());
                }
                output.extend_from_slice(chunk);
                output.extend_from_slice(b"\x1b\\");
            }
        }
    }
    pub(crate) fn checkpoint_row(
        &self,
        output: &mut Vec<u8>,
        screen: KittyGraphicsScreen,
        line: i64,
        viewport_row: usize,
    ) {
        for p in self
            .placements
            .iter()
            .filter(|p| p.screen == screen && p.anchor_line == line)
        {
            output.extend_from_slice(format!("\x1b7\x1b[{};{}H\x1b_Ga=p,i={},p={},x={},y={},w={},h={},c={},r={},X={},Y={},z={},C=1,q=2;\x1b\\\x1b8",
                viewport_row + 1, p.column + 1, p.image_id, p.placement_id, p.source_x, p.source_y,
                p.source_width, p.source_height, p.display_columns, p.display_rows, p.x_offset, p.y_offset, p.z_index).as_bytes());
        }
    }
    /// The protocol anchors a chunked image when its final chunk arrives.
    /// Rebuild only the buffered upload; subsequent live output supplies its
    /// cursor position, even if text/scrolling occurred between the chunks.
    pub(crate) fn checkpoint_upload(&self, output: &mut Vec<u8>) {
        let Some(pending) = &self.pending else {
            return;
        };
        let mut command = pending.command.clone();
        command.control.retain(|(key, _)| *key != 'm');
        command.control.push(('m', "1".into()));
        let encoded = BASE64.encode(&pending.decoded);
        let mut chunks = encoded.as_bytes().chunks(4096);
        command.payload = chunks.next().unwrap_or_default().to_vec();
        command.encode(output);
        for chunk in chunks {
            output.extend_from_slice(b"\x1b_Gm=1;");
            output.extend_from_slice(chunk);
            output.extend_from_slice(b"\x1b\\");
        }
    }
    pub(crate) fn apply(
        &mut self,
        command: KittyGraphicsCommand,
        cursor_column: usize,
        cursor_row: usize,
        history_size: usize,
        size: KittyGraphicsSize,
        screen: KittyGraphicsScreen,
    ) -> KittyGraphicsApplyResult {
        let context = PlacementContext {
            cursor_column,
            cursor_row,
            history_size,
            size,
            screen,
        };
        if command.oversized {
            let response_command = self
                .pending
                .take()
                .map_or_else(|| command.clone(), |pending| pending.command);
            return self.failure(
                &response_command,
                "EFBIG:image command exceeds storage limit",
            );
        }

        let action = command.char_value('a').unwrap_or('t');
        if action == 'd' {
            return self.delete(
                &command,
                context.cursor_column,
                context.cursor_row,
                context.history_size,
                context.screen,
            );
        }
        if action == 'p' {
            return self.put(command, context);
        }
        if !matches!(action, 't' | 'T' | 'q') {
            return self.failure(&command, "EINVAL:unsupported graphics action");
        }

        let decoded = match BASE64.decode(&command.payload) {
            Ok(decoded) if decoded.len() <= self.byte_limit() => decoded,
            Ok(_) => {
                let response_command = self
                    .pending
                    .take()
                    .map_or_else(|| command.clone(), |pending| pending.command);
                return self.failure(
                    &response_command,
                    "EFBIG:image payload exceeds storage limit",
                );
            }
            Err(_) => {
                let response_command = self
                    .pending
                    .take()
                    .map_or_else(|| command.clone(), |pending| pending.command);
                return self.failure(&response_command, "EINVAL:invalid base64 payload");
            }
        };

        let more = command.u32_value('m').unwrap_or(0) == 1;
        if let Some(mut pending) = self.pending.take() {
            if pending.decoded.len().saturating_add(decoded.len()) > self.byte_limit() {
                return self.failure(
                    &pending.command,
                    "EFBIG:image payload exceeds storage limit",
                );
            }
            pending.decoded.extend_from_slice(&decoded);
            if more {
                self.pending = Some(pending);
                return KittyGraphicsApplyResult::default();
            }
            let mut first = pending.command;
            for (key, value) in command.control {
                if key != 'm' {
                    first.control.push((key, value));
                }
            }
            return self.finish_upload(first, pending.decoded, context);
        }

        if more {
            self.pending = Some(PendingUpload {
                command,
                decoded,
                context,
            });
            return KittyGraphicsApplyResult::default();
        }
        self.finish_upload(command, decoded, context)
    }

    pub(crate) fn render_placements(
        &self,
        history_size: usize,
        display_offset: usize,
        rows: usize,
        columns: usize,
        screen: KittyGraphicsScreen,
    ) -> Vec<KittyGraphicsRenderPlacement> {
        let history_size = i64::try_from(history_size).unwrap_or(i64::MAX);
        let display_offset = i64::try_from(display_offset).unwrap_or(i64::MAX);
        let rows = i64::try_from(rows).unwrap_or(i64::MAX);
        self.placements
            .iter()
            .filter(|placement| placement.screen == screen)
            .filter_map(|placement| {
                let image = self.images.get(&(screen, placement.image_id))?;
                let viewport_row = placement
                    .anchor_line
                    .saturating_sub(history_size)
                    .saturating_add(display_offset);
                let bottom = viewport_row.saturating_add(i64::from(placement.occupied_rows));
                if bottom <= 0
                    || viewport_row >= rows
                    || placement.column >= columns
                    || placement.occupied_columns == 0
                {
                    return None;
                }
                Some(KittyGraphicsRenderPlacement {
                    placement_serial: placement.placement_serial,
                    image_id: placement.image_id,
                    placement_id: placement.placement_id,
                    png: image.png.clone(),
                    image_width: image.width,
                    image_height: image.height,
                    image_generation: image.generation,
                    viewport_row: i32::try_from(viewport_row).unwrap_or(if viewport_row < 0 {
                        i32::MIN
                    } else {
                        i32::MAX
                    }),
                    column: placement.column,
                    source_x: placement.source_x,
                    source_y: placement.source_y,
                    source_width: placement.source_width,
                    source_height: placement.source_height,
                    display_columns: placement.display_columns,
                    display_rows: placement.display_rows,
                    occupied_columns: placement.occupied_columns,
                    occupied_rows: placement.occupied_rows,
                    x_offset: placement.x_offset,
                    y_offset: placement.y_offset,
                    z_index: placement.z_index,
                })
            })
            .collect()
    }

    pub(crate) fn has_placements(&self) -> bool {
        !self.placements.is_empty()
    }

    pub(crate) fn clear_screen(&mut self, screen: KittyGraphicsScreen) -> bool {
        let before = self.placements.len();
        self.placements
            .retain(|placement| placement.screen != screen);
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.context.screen == screen)
        {
            self.pending = None;
        }
        before != self.placements.len()
    }

    pub(crate) fn clear_viewport(
        &mut self,
        screen: KittyGraphicsScreen,
        history_size: usize,
        rows: usize,
        columns: usize,
    ) -> bool {
        if rows == 0 || columns == 0 {
            return false;
        }
        let viewport_start = i64::try_from(history_size).unwrap_or(i64::MAX);
        let viewport_end = viewport_start.saturating_add(i64::try_from(rows).unwrap_or(i64::MAX));
        let before = self.placements.len();
        self.placements.retain(|placement| {
            if placement.screen != screen {
                return true;
            }
            let placement_end = placement
                .anchor_line
                .saturating_add(i64::from(placement.occupied_rows));
            let vertically_visible =
                placement.anchor_line < viewport_end && placement_end > viewport_start;
            let horizontally_visible = placement.column < columns && placement.occupied_columns > 0;
            !(vertically_visible && horizontally_visible)
        });
        before != self.placements.len()
    }

    pub(crate) fn scroll_up_without_history(
        &mut self,
        lines: usize,
        screen: KittyGraphicsScreen,
    ) -> bool {
        if lines == 0
            || !self
                .placements
                .iter()
                .any(|placement| placement.screen == screen)
        {
            return false;
        }
        let lines = i64::try_from(lines).unwrap_or(i64::MAX);
        for placement in self
            .placements
            .iter_mut()
            .filter(|placement| placement.screen == screen)
        {
            placement.anchor_line = placement.anchor_line.saturating_sub(lines);
        }
        self.placements.retain(|placement| {
            placement.screen != screen
                || placement
                    .anchor_line
                    .saturating_add(i64::from(placement.occupied_rows))
                    > 0
        });
        true
    }

    pub(crate) fn preserve_primary_across_partial_history_growth(&mut self, lines: usize) -> bool {
        if lines == 0 {
            return false;
        }
        let lines = i64::try_from(lines).unwrap_or(i64::MAX);
        let mut changed = false;
        for placement in self
            .placements
            .iter_mut()
            .filter(|placement| placement.screen == KittyGraphicsScreen::Primary)
        {
            placement.anchor_line = placement.anchor_line.saturating_add(lines);
            changed = true;
        }
        changed
    }

    fn finish_upload(
        &mut self,
        command: KittyGraphicsCommand,
        decoded: Vec<u8>,
        context: PlacementContext,
    ) -> KittyGraphicsApplyResult {
        let data = match self.resolve_transmission_data(&command, decoded) {
            Ok(data) => data,
            Err(error) => return self.failure(&command, &error),
        };
        let data = match command.char_value('o') {
            None => data,
            Some('z') => match decompress_zlib(&data) {
                Ok(data) => data,
                Err(error) => return self.failure(&command, &error),
            },
            Some(_) => return self.failure(&command, "EINVAL:unsupported compression"),
        };
        let (png, width, height) = match normalize_image(&command, &data) {
            Ok(image) => image,
            Err(error) => return self.failure(&command, &error),
        };

        if command.char_value('a').unwrap_or('t') == 'q' {
            return self.success(&command, false, None, context.screen);
        }

        let requested_id = command.u32_value('i').unwrap_or(0);
        let image_id = if requested_id == 0 {
            self.allocate_anonymous_id(context.screen)
        } else {
            requested_id
        };
        self.remove_image(image_id, context.screen);
        let byte_len = png.len();
        self.next_generation = self.next_generation.wrapping_add(1).max(1);
        self.images.insert(
            (context.screen, image_id),
            StoredImage {
                png: Arc::from(png),
                width,
                height,
                byte_len,
                generation: self.next_generation,
            },
        );
        self.insertion_order.push_back((context.screen, image_id));
        self.stored_bytes = self.stored_bytes.saturating_add(byte_len);
        if !self.enforce_quota(Some((context.screen, image_id))) {
            self.remove_image(image_id, context.screen);
            return self.failure(&command, "ENOSPC:image storage quota exceeded");
        }

        let display = command.char_value('a').unwrap_or('t') == 'T';
        let cursor_advance = if display {
            match self.add_placement(image_id, &command, context) {
                Ok(advance) => advance,
                Err(error) => {
                    self.remove_image(image_id, context.screen);
                    return self.failure(&command, &error);
                }
            }
        } else {
            None
        };
        self.success(&command, true, cursor_advance, context.screen)
    }

    fn put(
        &mut self,
        command: KittyGraphicsCommand,
        context: PlacementContext,
    ) -> KittyGraphicsApplyResult {
        let image_id = command.u32_value('i').unwrap_or(0);
        if image_id == 0 || !self.images.contains_key(&(context.screen, image_id)) {
            return self.failure(&command, "ENOENT:image id not found");
        }
        match self.add_placement(image_id, &command, context) {
            Ok(advance) => self.success(&command, true, advance, context.screen),
            Err(error) => self.failure(&command, &error),
        }
    }

    fn add_placement(
        &mut self,
        image_id: u32,
        command: &KittyGraphicsCommand,
        context: PlacementContext,
    ) -> Result<Option<(u32, u32)>, String> {
        if command.u32_value('U').unwrap_or(0) == 1 {
            return Err("EINVAL:Unicode placeholder placements are not supported".into());
        }
        if self.storage_limit != 0 && self.placements.len() >= 16384 {
            return Err("ENOSPC:image placement quota exceeded".into());
        }
        let image = self
            .images
            .get(&(context.screen, image_id))
            .ok_or_else(|| "ENOENT:image id not found".to_owned())?;
        let source_x = command.u32_value('x').unwrap_or(0).min(image.width);
        let source_y = command.u32_value('y').unwrap_or(0).min(image.height);
        let source_width = command
            .u32_value('w')
            .unwrap_or(image.width.saturating_sub(source_x))
            .min(image.width.saturating_sub(source_x));
        let source_height = command
            .u32_value('h')
            .unwrap_or(image.height.saturating_sub(source_y))
            .min(image.height.saturating_sub(source_y));
        if source_width == 0 || source_height == 0 {
            return Err("EINVAL:empty source rectangle".into());
        }

        let cell_width = context.size.cell_width.max(1.0);
        let cell_height = context.size.cell_height.max(1.0);
        let requested_columns = command.u32_value('c').filter(|value| *value > 0);
        let requested_rows = command.u32_value('r').filter(|value| *value > 0);
        let available_columns = u32::try_from(context.size.columns)
            .unwrap_or(u32::MAX)
            .saturating_sub(u32::try_from(context.cursor_column).unwrap_or(u32::MAX))
            .max(1);
        let available_width = available_columns as f32 * cell_width;

        let mut placed_source_width = source_width;
        let (display_columns, display_rows) = match (requested_columns, requested_rows) {
            (Some(columns), Some(rows)) => (columns, rows),
            (Some(columns), None) => {
                let width = columns as f32 * cell_width;
                let height = width * source_height as f32 / source_width as f32;
                (columns, (height / cell_height).ceil().max(1.0) as u32)
            }
            (None, Some(rows)) => {
                let height = rows as f32 * cell_height;
                let width = height * source_width as f32 / source_height as f32;
                ((width / cell_width).ceil().max(1.0) as u32, rows)
            }
            (None, None) => {
                if source_width as f32 > available_width {
                    placed_source_width = available_width.floor().max(1.0) as u32;
                }
                (
                    ((placed_source_width as f32 / cell_width).ceil().max(1.0) as u32)
                        .min(available_columns),
                    (source_height as f32 / cell_height).ceil().max(1.0) as u32,
                )
            }
        };
        let occupied_columns = display_columns;
        let occupied_rows = display_rows;
        let placement_id = command.u32_value('p').unwrap_or(0);
        if placement_id != 0 {
            self.placements.retain(|placement| {
                placement.screen != context.screen
                    || placement.image_id != image_id
                    || placement.placement_id != placement_id
            });
        }
        self.next_placement_serial = self.next_placement_serial.wrapping_add(1).max(1);
        self.placements.push(Placement {
            placement_serial: self.next_placement_serial,
            screen: context.screen,
            image_id,
            placement_id,
            anchor_line: i64::try_from(context.history_size)
                .unwrap_or(i64::MAX)
                .saturating_add(i64::try_from(context.cursor_row).unwrap_or(i64::MAX)),
            column: context.cursor_column,
            source_x,
            source_y,
            source_width: placed_source_width,
            source_height,
            display_columns,
            display_rows,
            occupied_columns,
            occupied_rows,
            x_offset: command.u32_value('X').unwrap_or(0),
            y_offset: command.u32_value('Y').unwrap_or(0),
            z_index: command.i32_value('z').unwrap_or(0),
        });
        Ok((command.u32_value('C').unwrap_or(0) == 0).then_some((occupied_columns, occupied_rows)))
    }

    fn delete(
        &mut self,
        command: &KittyGraphicsCommand,
        cursor_column: usize,
        cursor_row: usize,
        history_size: usize,
        screen: KittyGraphicsScreen,
    ) -> KittyGraphicsApplyResult {
        self.pending = None;
        let selector = command.char_value('d').unwrap_or('a');
        let free_data = selector.is_ascii_uppercase();
        let selector = selector.to_ascii_lowercase();
        let before = self.placements.len();
        match selector {
            'a' => self
                .placements
                .retain(|placement| placement.screen != screen),
            'i' => {
                let image_id = command.u32_value('i').unwrap_or(0);
                let placement_id = command.u32_value('p').unwrap_or(0);
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || placement.image_id != image_id
                        || (placement_id != 0 && placement.placement_id != placement_id)
                });
                if free_data
                    && !self.placements.iter().any(|placement| {
                        placement.screen == screen && placement.image_id == image_id
                    })
                {
                    self.remove_image(image_id, screen);
                }
            }
            'c' => {
                let line = i64::try_from(history_size)
                    .unwrap_or(i64::MAX)
                    .saturating_add(i64::try_from(cursor_row).unwrap_or(i64::MAX));
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || !placement_contains(placement, line, cursor_column)
                });
            }
            'p' | 'q' => {
                let column = command.u32_value('x').unwrap_or(1).saturating_sub(1) as usize;
                let row = command.u32_value('y').unwrap_or(1).saturating_sub(1) as i64
                    + i64::try_from(history_size).unwrap_or(i64::MAX);
                let z_index = command.i32_value('z');
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || !placement_contains(placement, row, column)
                        || (selector == 'q' && z_index.is_some_and(|z| placement.z_index != z))
                });
            }
            'x' => {
                let column = command.u32_value('x').unwrap_or(1).saturating_sub(1) as usize;
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || column < placement.column
                        || column
                            >= placement
                                .column
                                .saturating_add(placement.occupied_columns as usize)
                });
            }
            'y' => {
                let row = command.u32_value('y').unwrap_or(1).saturating_sub(1) as i64
                    + i64::try_from(history_size).unwrap_or(i64::MAX);
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || row < placement.anchor_line
                        || row
                            >= placement
                                .anchor_line
                                .saturating_add(i64::from(placement.occupied_rows))
                });
            }
            'z' => {
                let z_index = command.i32_value('z').unwrap_or(0);
                self.placements
                    .retain(|placement| placement.screen != screen || placement.z_index != z_index);
            }
            _ => return self.failure(command, "EINVAL:unsupported delete selector"),
        }
        if free_data {
            self.drop_unplaced_images(screen);
        }
        self.success(command, before != self.placements.len(), None, screen)
    }

    fn resolve_transmission_data(
        &self,
        command: &KittyGraphicsCommand,
        decoded: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        // Check the assembled upload as well as individual frames: chunked
        // uploads inherit their transmission medium from the first command.
        if self.deny_file_transfers && !command.is_inline() {
            return Err("ENOTSUP:remote images must use direct transmission".into());
        }
        match command.char_value('t').unwrap_or('d') {
            'd' => Ok(decoded),
            'f' | 't' => {
                let temporary = command.char_value('t') == Some('t');
                let path = PathBuf::from(
                    std::str::from_utf8(&decoded).map_err(|_| "EINVAL:file path is not UTF-8")?,
                );
                let result = read_regular_file(
                    &path,
                    command.u32_value('O').unwrap_or(0) as u64,
                    command
                        .u32_value('S')
                        .filter(|size| *size > 0)
                        .map(u64::from),
                );
                if temporary && temporary_path_can_be_removed(&path) {
                    let _ = std::fs::remove_file(&path);
                }
                result
            }
            's' => Err("ENOTSUP:shared-memory transmission is not supported".into()),
            _ => Err("EINVAL:unsupported transmission medium".into()),
        }
    }

    fn allocate_anonymous_id(&mut self, screen: KittyGraphicsScreen) -> u32 {
        if self.next_anonymous_id == 0 {
            self.next_anonymous_id = u32::MAX;
        }
        while self.images.contains_key(&(screen, self.next_anonymous_id)) {
            self.next_anonymous_id = self.next_anonymous_id.saturating_sub(1).max(1);
        }
        let id = self.next_anonymous_id;
        self.next_anonymous_id = self.next_anonymous_id.saturating_sub(1).max(1);
        id
    }

    fn enforce_quota(&mut self, protected: Option<(KittyGraphicsScreen, u32)>) -> bool {
        while self.stored_bytes > self.byte_limit() {
            let Some(candidate) = self.insertion_order.pop_front() else {
                break;
            };
            if protected == Some(candidate)
                || self
                    .placements
                    .iter()
                    .any(|placement| (placement.screen, placement.image_id) == candidate)
            {
                self.insertion_order.push_back(candidate);
                if self.insertion_order.iter().all(|id| {
                    protected == Some(*id)
                        || self
                            .placements
                            .iter()
                            .any(|placement| (placement.screen, placement.image_id) == *id)
                }) {
                    break;
                }
                continue;
            }
            self.remove_image(candidate.1, candidate.0);
        }
        self.stored_bytes <= self.byte_limit()
    }

    fn drop_unplaced_images(&mut self, screen: KittyGraphicsScreen) {
        let ids: Vec<(KittyGraphicsScreen, u32)> = self
            .images
            .keys()
            .copied()
            .filter(|id| {
                id.0 == screen
                    && !self
                        .placements
                        .iter()
                        .any(|placement| (placement.screen, placement.image_id) == *id)
            })
            .collect();
        for id in ids {
            self.remove_image(id.1, id.0);
        }
    }

    fn remove_image(&mut self, image_id: u32, screen: KittyGraphicsScreen) {
        if let Some(image) = self.images.remove(&(screen, image_id)) {
            self.stored_bytes = self.stored_bytes.saturating_sub(image.byte_len);
        }
        self.placements
            .retain(|placement| placement.screen != screen || placement.image_id != image_id);
        self.insertion_order.retain(|id| *id != (screen, image_id));
    }

    fn success(
        &self,
        command: &KittyGraphicsCommand,
        changed: bool,
        cursor_advance: Option<(u32, u32)>,
        screen: KittyGraphicsScreen,
    ) -> KittyGraphicsApplyResult {
        KittyGraphicsApplyResult {
            response: response(command, true, "OK"),
            cursor_advance,
            cursor_advance_screen: cursor_advance.map(|_| screen),
            changed,
        }
    }

    fn failure(&self, command: &KittyGraphicsCommand, message: &str) -> KittyGraphicsApplyResult {
        KittyGraphicsApplyResult {
            response: response(command, false, message),
            ..KittyGraphicsApplyResult::default()
        }
    }
}

fn placement_contains(placement: &Placement, line: i64, column: usize) -> bool {
    line >= placement.anchor_line
        && line
            < placement
                .anchor_line
                .saturating_add(i64::from(placement.occupied_rows))
        && column >= placement.column
        && column
            < placement
                .column
                .saturating_add(placement.occupied_columns as usize)
}

fn response(command: &KittyGraphicsCommand, success: bool, message: &str) -> Option<Vec<u8>> {
    let quiet = command.u32_value('q').unwrap_or(0);
    if (success && quiet >= 1) || (!success && quiet >= 2) {
        return None;
    }
    let image_id = command.u32_value('i').or_else(|| command.u32_value('I'))?;
    let mut control = format!("i={image_id}");
    if let Some(placement_id) = command.u32_value('p') {
        control.push_str(&format!(",p={placement_id}"));
    }
    Some(format!("\x1b_G{control};{message}\x1b\\").into_bytes())
}

fn normalize_image(
    command: &KittyGraphicsCommand,
    data: &[u8],
) -> Result<(Vec<u8>, u32, u32), String> {
    match command.u32_value('f').unwrap_or(32) {
        100 => {
            let decoder = png::Decoder::new(Cursor::new(data));
            let mut reader = decoder
                .read_info()
                .map_err(|_| "EINVAL:invalid PNG image".to_owned())?;
            let (width, height) = (reader.info().width, reader.info().height);
            validate_dimensions(width, height, 4)?;
            let decoded_len = reader
                .output_buffer_size()
                .filter(|length| *length <= MAX_IMAGE_BYTES)
                .ok_or_else(|| "EFBIG:decoded PNG exceeds storage limit".to_owned())?;
            let mut decoded = vec![0; decoded_len];
            reader
                .next_frame(&mut decoded)
                .and_then(|_| reader.finish())
                .map_err(|_| "EINVAL:invalid PNG image".to_owned())?;
            Ok((data.to_vec(), width, height))
        }
        format @ (24 | 32) => {
            let width = command.u32_value('s').unwrap_or(0);
            let height = command.u32_value('v').unwrap_or(0);
            let channels = if format == 24 { 3 } else { 4 };
            let expected = validate_dimensions(width, height, channels)?;
            if data.len() != expected {
                return Err("EINVAL:pixel data length does not match dimensions".into());
            }
            let mut png = Vec::new();
            {
                let mut encoder = png::Encoder::new(&mut png, width, height);
                encoder.set_depth(png::BitDepth::Eight);
                encoder.set_color(if channels == 3 {
                    png::ColorType::Rgb
                } else {
                    png::ColorType::Rgba
                });
                encoder
                    .write_header()
                    .and_then(|mut writer| writer.write_image_data(data))
                    .map_err(|_| "EINVAL:failed to encode pixel data".to_owned())?;
            }
            Ok((png, width, height))
        }
        _ => Err("EINVAL:unsupported image format".into()),
    }
}

fn validate_dimensions(width: u32, height: u32, channels: usize) -> Result<usize, String> {
    if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err("EINVAL:invalid image dimensions".into());
    }
    let pixels = u64::from(width) * u64::from(height);
    if pixels > MAX_PIXELS {
        return Err("EFBIG:image dimensions exceed storage limit".into());
    }
    usize::try_from(pixels)
        .ok()
        .and_then(|pixels| pixels.checked_mul(channels))
        .ok_or_else(|| "EFBIG:image dimensions overflow".into())
}

fn decompress_zlib(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut output = Vec::new();
    ZlibDecoder::new(data)
        .take(MAX_IMAGE_BYTES as u64 + 1)
        .read_to_end(&mut output)
        .map_err(|_| "EINVAL:invalid zlib payload".to_owned())?;
    if output.len() > MAX_IMAGE_BYTES {
        return Err("EFBIG:decompressed image exceeds storage limit".into());
    }
    Ok(output)
}

fn read_regular_file(path: &Path, offset: u64, size: Option<u64>) -> Result<Vec<u8>, String> {
    let mut file = File::open(path).map_err(|_| "ENOENT:unable to open image file".to_owned())?;
    let metadata = file
        .metadata()
        .map_err(|_| "EIO:unable to inspect image file".to_owned())?;
    if !metadata.file_type().is_file() {
        return Err("EINVAL:image path is not a regular file".into());
    }
    if offset > metadata.len() {
        return Err("EINVAL:file offset is past end of file".into());
    }
    let available = metadata.len() - offset;
    let length = size.unwrap_or(available).min(available);
    if length > MAX_IMAGE_BYTES as u64 {
        return Err("EFBIG:image file exceeds storage limit".into());
    }
    file.seek(SeekFrom::Start(offset))
        .map_err(|_| "EIO:unable to seek image file".to_owned())?;
    let mut data = Vec::with_capacity(length as usize);
    file.take(length)
        .read_to_end(&mut data)
        .map_err(|_| "EIO:unable to read image file".to_owned())?;
    Ok(data)
}

fn temporary_path_can_be_removed(path: &Path) -> bool {
    if !path.to_string_lossy().contains("tty-graphics-protocol") {
        return false;
    }
    let Ok(canonical) = path.canonicalize() else {
        return false;
    };
    let roots = [
        PathBuf::from("/tmp"),
        PathBuf::from("/private/tmp"),
        std::env::temp_dir(),
    ];
    roots.into_iter().any(|root| {
        root.canonicalize()
            .is_ok_and(|root| canonical.starts_with(root))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn size() -> KittyGraphicsSize {
        KittyGraphicsSize {
            columns: 80,
            rows: 24,
            cell_width: 8.0,
            cell_height: 16.0,
        }
    }

    fn command(control: &str, payload: &[u8]) -> KittyGraphicsCommand {
        let mut bytes = control.as_bytes().to_vec();
        bytes.push(b';');
        bytes.extend_from_slice(BASE64.encode(payload).as_bytes());
        KittyGraphicsCommand::parse(bytes, false)
    }

    #[test]
    fn interceptor_removes_kitty_apc_and_preserves_text() {
        let mut interceptor = KittyGraphicsInterceptor::default();
        let items = interceptor.process(b"before\x1b_Ga=q,i=7;AAAA\x1b\\after");
        assert!(matches!(&items[0], KittyGraphicsItem::Text(text) if text == b"before"));
        assert!(matches!(&items[1], KittyGraphicsItem::Command(_)));
        assert!(matches!(&items[2], KittyGraphicsItem::Text(text) if text == b"after"));
    }

    #[test]
    fn uploads_raw_rgba_and_places_at_cursor() {
        let mut graphics = KittyGraphicsState::default();
        let result = graphics.apply(
            command("a=T,f=32,s=1,v=1,i=7,c=2,r=3", &[1, 2, 3, 255]),
            4,
            5,
            0,
            size(),
            KittyGraphicsScreen::Primary,
        );
        assert!(result.changed);
        assert_eq!(result.cursor_advance, Some((2, 3)));
        let placements = graphics.render_placements(0, 0, 24, 80, KittyGraphicsScreen::Primary);
        assert_eq!(placements.len(), 1);
        assert_eq!(placements[0].column, 4);
        assert_eq!(placements[0].viewport_row, 5);
        assert!(placements[0].png.starts_with(b"\x89PNG"));
    }

    #[test]
    fn assembles_chunked_upload_before_displaying() {
        let mut graphics = KittyGraphicsState::default();
        let first = graphics.apply(
            command("a=T,f=32,s=1,v=1,i=8,m=1", &[1, 2]),
            0,
            0,
            0,
            size(),
            KittyGraphicsScreen::Primary,
        );
        assert!(!first.changed);
        let second = graphics.apply(
            command("m=0", &[3, 255]),
            0,
            0,
            0,
            size(),
            KittyGraphicsScreen::Primary,
        );
        assert!(second.changed);
        assert_eq!(
            graphics
                .render_placements(0, 0, 24, 80, KittyGraphicsScreen::Primary)
                .len(),
            1
        );
    }

    #[test]
    fn interceptor_does_not_treat_utf8_continuation_as_c1_apc() {
        let mut interceptor = KittyGraphicsInterceptor::default();
        assert!(
            matches!(interceptor.process(b"\xf0").as_slice(), [KittyGraphicsItem::Text(text)] if text == b"\xf0")
        );
        let items = interceptor.process(b"\x9f\x94\x8d Resolving\x1b_Ga=q,i=7;AAAA\x1b\\");
        assert!(
            matches!(&items[0], KittyGraphicsItem::Text(text) if text == b"\x9f\x94\x8d Resolving")
        );
        assert!(matches!(&items[1], KittyGraphicsItem::Command(_)));
    }
}
