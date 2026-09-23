//! PTY ownership adapted from tty7-core daemon/pane.rs at the pinned revision.
//! Apache-2.0 attribution: see ../Vendor/tty7-core/{LICENSE,KERO-VENDOR.md}.
//!
//! Kero deliberately detaches only a *sustained* slow subscriber instead of
//! applying tty7's output gate to the PTY reader: a parked GUI must never stop
//! a background job, but ordinary rendering bursts must not tear off the pane.
use crate::protocol::*;
use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use std::collections::HashMap;
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::{Duration, Instant};
use uuid::Uuid;

const MAX_INPUT: usize = 64 * 1024;
const PTY_READ_BYTES: usize = 64 * 1024;
/// A terminal checkpoint itself is bounded at 32 MiB. The extra headroom
/// covers attached/checkpoint/event framing so a legal max-state checkpoint
/// cannot be mistaken for a runaway renderer queue.
const OUTPUT_QUEUE_BYTES: usize = 40 * 1024 * 1024;
const OUTPUT_HIGH_WATER_BYTES: usize = 8 * 1024 * 1024;
const OUTPUT_COALESCE_BYTES: usize = 1024 * 1024;
const SLOW_CONSUMER_GRACE: Duration = Duration::from_secs(10);
const SLOW_CONSUMER_CHECK: Duration = Duration::from_millis(100);

const INPUT_QUEUE_BYTES: usize = 2 * 1024 * 1024;
#[derive(Default)]
struct InputQueue {
    state: Mutex<(Vec<u8>, bool)>,
    ready: Condvar,
}
impl InputQueue {
    fn send(&self, bytes: &[u8]) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        anyhow::ensure!(
            !state.1 && state.0.len().saturating_add(bytes.len()) <= INPUT_QUEUE_BYTES,
            "input queue full or closed"
        );
        state.0.extend_from_slice(bytes);
        self.ready.notify_one();
        Ok(())
    }
    fn receive(&self) -> Option<Vec<u8>> {
        let mut state = self.state.lock().unwrap();
        while state.0.is_empty() && !state.1 {
            state = self.ready.wait(state).unwrap();
        }
        if state.1 {
            None
        } else {
            Some(std::mem::take(&mut state.0))
        }
    }
    fn close(&self) {
        let mut state = self.state.lock().unwrap();
        state.1 = true;
        state.0.clear();
        self.ready.notify_all();
    }
}
#[cfg(test)]
mod input_tests {
    use super::*;
    #[test]
    fn byte_budget_coalesces_keystroke_frames_without_dropping_or_reordering() {
        let queue = InputQueue::default();
        let bytes: Vec<u8> = (0..8192).map(|i| (i % 251) as u8).collect();
        for byte in &bytes {
            queue.send(&[*byte]).unwrap();
        }
        assert_eq!(queue.receive().unwrap(), bytes);
        queue.send(&vec![0; INPUT_QUEUE_BYTES]).unwrap();
        assert!(queue.send(&[1]).is_err());
        assert_eq!(queue.receive().unwrap().len(), INPUT_QUEUE_BYTES);
        queue.close();
        assert!(queue.receive().is_none());
        assert!(queue.send(&[1]).is_err());
    }
}

/// A bounded queue for one attached renderer. Unlike a frame-count channel,
/// this measures bytes and merges contiguous terminal output. A short GUI
/// stall therefore absorbs an image/redraw burst instead of disconnecting;
/// only a subscriber that stays above the high-water mark is detached, so a
/// background job never waits on the GUI.
pub(crate) struct OutputQueue {
    state: Mutex<OutputQueueState>,
    ready: Condvar,
}

struct OutputQueueState {
    frames: VecDeque<Frame>,
    bytes: usize,
    slow_since: Option<Instant>,
    closed: bool,
    capacity: usize,
    high_water: usize,
    coalesce_limit: usize,
    grace: Duration,
}

impl OutputQueue {
    fn terminal() -> Arc<Self> {
        Self::new(
            OUTPUT_QUEUE_BYTES,
            OUTPUT_HIGH_WATER_BYTES,
            OUTPUT_COALESCE_BYTES,
            SLOW_CONSUMER_GRACE,
        )
    }

    fn new(
        capacity: usize,
        high_water: usize,
        coalesce_limit: usize,
        grace: Duration,
    ) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(OutputQueueState {
                frames: VecDeque::new(),
                bytes: 0,
                slow_since: None,
                closed: false,
                capacity,
                high_water,
                coalesce_limit,
                grace,
            }),
            ready: Condvar::new(),
        })
    }

    fn send(&self, frame: Frame) -> bool {
        let payload_bytes = frame.1.len();
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return false;
        }

        // Terminal output payloads start with the sequence *after* those
        // bytes. A frame is contiguous when its end sequence equals the prior
        // end plus only the new bytes; merging keeps stream order while
        // avoiding a syscall and MainActor hop for every tiny PTY read.
        if frame.0 == OUTPUT
            && state.frames.back().is_some_and(|last| {
                last.0 == OUTPUT
                    && last.1.len() <= state.coalesce_limit
                    && frame.1.len() <= state.coalesce_limit
                    && last.1.len() + frame.1.len() - 8 <= state.coalesce_limit
            })
        {
            let last = state.frames.back_mut().unwrap();
            let previous_header = u64::from_le_bytes(last.1[..8].try_into().unwrap());
            let next_header = u64::from_le_bytes(frame.1[..8].try_into().unwrap());
            if next_header == previous_header + (frame.1.len() - 8) as u64 {
                last.1.extend_from_slice(&frame.1[8..]);
                // The incoming header already covers the newly appended bytes
                // as well as everything already in the merged frame.
                last.1[..8].copy_from_slice(&next_header.to_le_bytes());
                state.bytes += payload_bytes;
            } else {
                state.frames.push_back(frame);
                state.bytes += payload_bytes;
            }
        } else {
            state.frames.push_back(frame);
            state.bytes += payload_bytes;
        }

        if state.bytes >= state.high_water {
            let slow_since = *state.slow_since.get_or_insert(Instant::now());
            if state.bytes > state.capacity || slow_since.elapsed() >= state.grace {
                state.closed = true;
                state.frames.clear();
                state.bytes = 0;
                drop(state);
                self.ready.notify_all();
                return false;
            }
        } else {
            state.slow_since = None;
        }

        self.ready.notify_one();
        true
    }

    pub(crate) fn receive(&self) -> Option<Frame> {
        let mut state = self.state.lock().unwrap();
        loop {
            // A producer can stop immediately after filling the queue. The
            // writer still has to enforce the grace period; otherwise a stalled
            // GUI could pin a finished session's outbox forever.
            if let Some(slow_since) = state.slow_since
                && slow_since.elapsed() >= state.grace
            {
                state.closed = true;
                state.frames.clear();
                state.bytes = 0;
                drop(state);
                self.ready.notify_all();
                return None;
            }
            if let Some(frame) = state.frames.pop_front() {
                state.bytes = state.bytes.saturating_sub(frame.1.len());
                if state.bytes < state.high_water {
                    state.slow_since = None;
                }
                return Some(frame);
            }
            if state.closed {
                return None;
            }
            (state, _) = self.ready.wait_timeout(state, SLOW_CONSUMER_CHECK).unwrap();
        }
    }

    fn close(&self) {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return;
        }
        state.closed = true;
        state.frames.clear();
        state.bytes = 0;
        drop(state);
        self.ready.notify_all();
    }
}

struct Subscriber {
    frames: Arc<OutputQueue>,
    socket: UnixStream,
}
impl Subscriber {
    fn send(&self, frame: Frame) -> bool {
        if self.frames.send(frame) {
            return true;
        }
        // Shutdown also wakes a writer blocked on a peer that stopped reading.
        let _ = self.socket.shutdown(Shutdown::Both);
        false
    }
    fn close(&self) {
        self.frames.close();
        let _ = self.socket.shutdown(Shutdown::Both);
    }
}

#[cfg(test)]
mod output_queue_tests {
    use super::*;

    fn output(start: u64, bytes: usize) -> Frame {
        let mut payload = start.to_le_bytes().to_vec();
        payload.extend(std::iter::repeat_n(0xa5, bytes));
        Frame(OUTPUT, payload)
    }

    #[test]
    fn contiguous_output_coalesces_and_preserves_stream_order() {
        let queue = OutputQueue::new(1024, 1024, 1024, Duration::from_secs(1));
        assert!(queue.send(output(100, 100)));
        assert!(queue.send(output(140, 40)));
        assert!(queue.send(output(150, 10)));
        // A different frame kind is a boundary and must never merge.
        assert!(queue.send(Frame::event(Event::Directory { path: "/".into() })));
        assert!(queue.send(output(166, 10)));

        let first = queue.receive().unwrap();
        assert_eq!(first.0, OUTPUT);
        assert_eq!(u64::from_le_bytes(first.1[..8].try_into().unwrap()), 150);
        assert_eq!(first.1.len(), 8 + 150);
        let boundary = queue.receive().unwrap();
        assert_eq!(boundary.0, CONTROL);
        let second = queue.receive().unwrap();
        assert_eq!(u64::from_le_bytes(second.1[..8].try_into().unwrap()), 166);
    }

    #[test]
    fn a_short_burst_may_exceed_the_old_frame_channel_budget() {
        // The old 64 × 16 KiB channel disconnected during bursts around 1 MiB.
        let queue = OutputQueue::new(4 * 1024 * 1024, 1024, 1024, Duration::from_secs(1));
        for index in 0..192 {
            assert!(queue.send(output(index as u64 * 4096, 4096)));
        }
        let mut received = 0;
        for _ in 0..192 {
            assert!(queue.receive().is_some());
            received += 1;
        }
        queue.close();
        assert!(queue.receive().is_none());
        assert_eq!(received, 192);
    }

    #[test]
    fn a_sustained_slow_consumer_is_detached() {
        let queue = OutputQueue::new(1024, 512, 1024, Duration::from_millis(10));
        assert!(queue.send(output(0, 600)));
        std::thread::sleep(Duration::from_millis(20));
        assert!(!queue.send(output(600, 10)));
        assert!(queue.receive().is_none());
    }
}

struct State {
    info: SessionInfo,
    subscribers: HashMap<Uuid, Subscriber>,
    exit_code: Option<u32>,
    terminal: kero_terminal_state::TerminalState,
}

pub struct Session {
    state: Mutex<State>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    input: Arc<InputQueue>,
    child: Arc<Mutex<Box<dyn portable_pty::Child + Send + Sync>>>,
}

impl Session {
    pub fn spawn(host: Uuid, instance: Uuid, launch: Launch) -> anyhow::Result<Arc<Self>> {
        Self::spawn_restored(host, instance, launch, None)
    }
    pub fn spawn_restored(
        host: Uuid,
        instance: Uuid,
        launch: Launch,
        history: Option<&[u8]>,
    ) -> anyhow::Result<Arc<Self>> {
        launch.size.validate()?;
        anyhow::ensure!(
            std::path::Path::new(&launch.directory).is_absolute(),
            "directory must be absolute"
        );
        anyhow::ensure!(
            std::path::Path::new(&launch.program).is_absolute(),
            "program must be absolute"
        );
        anyhow::ensure!(
            launch.environment.len() <= 256,
            "too many environment entries"
        );
        let pair = native_pty_system().openpty(pty_size(launch.size))?;
        let mut command = CommandBuilder::new(&launch.program);
        command.args(&launch.arguments);
        command.cwd(&launch.directory);
        command.env("TERM", "xterm-256color");
        command.env("TERM_PROGRAM", "Kero");
        for (key, value) in &launch.environment {
            command.env(key, value);
        }
        let mut reader = pair.master.try_clone_reader()?;
        let read_fd = pair
            .master
            .as_raw_fd()
            .ok_or_else(|| anyhow::anyhow!("PTY has no pollable descriptor"))?;
        let mut writer = pair.master.take_writer()?;
        let child = pair.slave.spawn_command(command)?;
        let pid = child
            .process_id()
            .ok_or_else(|| anyhow::anyhow!("PTY child has no pid"))?;
        let child = Arc::new(Mutex::new(child));
        drop(pair.slave);
        // SSH can deliver many one-byte key frames in one network burst. A
        // frame-count bound rejected ordinary fast typing after 32 keys.
        let input = Arc::new(InputQueue::default());
        let input_writer = input.clone();
        let mut terminal = kero_terminal_state::TerminalState::new(
            launch.size.columns,
            launch.size.rows,
            launch.size.cell_width,
            launch.size.cell_height,
        );
        terminal.colors(launch.colors);
        if let Some(style) = launch.cursor_style {
            terminal.cursor_default(style)
        }
        if let Some(history) = history {
            terminal.feed(history);
        }
        let session = Arc::new(Self {
            state: Mutex::new(State {
                info: SessionInfo {
                    key: SessionKey {
                        host,
                        instance,
                        session: launch.session,
                    },
                    pid,
                    directory: launch.directory,
                    size: launch.size,
                    alive: true,
                    sequence: 0,
                },
                subscribers: HashMap::new(),
                exit_code: None,
                terminal,
            }),
            master: Mutex::new(pair.master),
            input,
            child: child.clone(),
        });
        std::thread::spawn(move || {
            while let Some(data) = input_writer.receive() {
                if writer.write_all(&data).is_err() {
                    break;
                }
            }
            input_writer.close();
        });
        let (exited, exit_status) = mpsc::sync_channel(1);
        let process_session = session.clone();
        std::thread::spawn(move || {
            let mut ticks = 0;
            loop {
                ticks += 1;
                let replies = process_session.state.lock().unwrap().terminal.tick();
                if !replies.is_empty() {
                    let _ = process_session.input.send(&replies);
                }
                if ticks % 20 == 0 {
                    process_session.refresh_directory();
                }
                let result = child.lock().unwrap().try_wait();
                match result {
                    Ok(Some(status)) => {
                        process_session.state.lock().unwrap().info.alive = false;
                        process_session.input.close();
                        let _ = exited.send(status.exit_code());
                        break;
                    }
                    Err(_) => {
                        process_session.state.lock().unwrap().info.alive = false;
                        process_session.input.close();
                        let _ = exited.send(1);
                        break;
                    }
                    Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
                }
            }
        });
        let output_session = session.clone();
        std::thread::spawn(move || {
            let mut buffer = [0; PTY_READ_BYTES];
            loop {
                let mut ready = libc::pollfd {
                    fd: read_fd,
                    events: libc::POLLIN,
                    revents: 0,
                };
                if unsafe { libc::poll(&mut ready, 1, 1000) } <= 0 {
                    continue;
                }
                // Read and parse under one lock so a resize/checkpoint can
                // never overtake bytes already read from the PTY.
                let mut state = output_session.state.lock().unwrap();
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => output_session.publish(&mut state, &buffer[..count]),
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
            // Drain PTY output before publishing exit; otherwise the final
            // command's output can arrive after the GUI has destroyed its view.
            let code = exit_status.recv().unwrap_or(1);
            let mut state = output_session.state.lock().unwrap();
            state.info.alive = false;
            state.exit_code = Some(code);
            let frame = Frame::event(Event::Exited { code });
            state
                .subscribers
                .retain(|_, subscriber| subscriber.send(frame.clone()));
        });
        Ok(session)
    }

    fn publish(&self, state: &mut State, bytes: &[u8]) {
        let responses = state.terminal.feed(bytes);
        if !responses.is_empty() {
            let _ = self.input.send(&responses);
        }
        state.info.sequence += bytes.len() as u64;
        let mut payload = state.info.sequence.to_le_bytes().to_vec();
        payload.extend_from_slice(bytes);
        let frame = Frame(OUTPUT, payload);
        state
            .subscribers
            .retain(|_, subscriber| subscriber.send(frame.clone()));
    }

    fn refresh_directory(&self) {
        let mut state = self.state.lock().unwrap();
        if let Some(path) = process_directory(state.info.pid) {
            if path != state.info.directory {
                state.info.directory = path.clone();
                let frame = Frame::event(Event::Directory { path });
                state
                    .subscribers
                    .retain(|_, subscriber| subscriber.send(frame.clone()));
            }
        }
    }
    pub fn colors(
        &self,
        client: Uuid,
        colors: std::collections::BTreeMap<usize, [u8; 3]>,
        cursor_style: Option<u8>,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        anyhow::ensure!(
            state.subscribers.contains_key(&client),
            "session is not attached"
        );
        anyhow::ensure!(colors.len() <= 259, "too many palette entries");
        state.terminal.colors(colors);
        if let Some(style) = cursor_style {
            state.terminal.cursor_default(style)
        }
        Ok(())
    }
    pub fn recovery(&self) -> (SessionInfo, Vec<u8>) {
        let mut state = self.state.lock().unwrap();
        if let Some(directory) = process_directory(state.info.pid) {
            state.info.directory = directory;
        }
        (state.info.clone(), state.terminal.recovery_history())
    }
    pub fn info(&self) -> SessionInfo {
        let mut state = self.state.lock().unwrap();
        if let Some(directory) = process_directory(state.info.pid) {
            state.info.directory = directory;
        }
        state.info.clone()
    }

    /// Checkpoint and subscription share the parser/sequence lock. The first
    /// live output therefore starts exactly after the checkpoint's offset.
    pub(crate) fn attach(
        &self,
        client: Uuid,
        socket: UnixStream,
    ) -> anyhow::Result<Arc<OutputQueue>> {
        self.attach_sized(client, socket, None)
    }

    pub(crate) fn attach_sized(
        &self,
        client: Uuid,
        socket: UnixStream,
        size: Option<Size>,
    ) -> anyhow::Result<Arc<OutputQueue>> {
        let outbox = OutputQueue::terminal();
        let mut state = self.state.lock().unwrap();
        anyhow::ensure!(state.subscribers.is_empty(), "session already controlled");
        if let Some(size) = size {
            size.validate()?;
            self.master.lock().unwrap().resize(pty_size(size))?;
            state
                .terminal
                .resize(size.columns, size.rows, size.cell_width, size.cell_height);
            state.info.size = size;
        }
        let checkpoint = state.terminal.checkpoint().map_err(anyhow::Error::msg)?;
        let subscriber = Subscriber {
            frames: outbox.clone(),
            socket,
        };
        subscriber.send(Frame::event(Event::Attached {
            session: state.info.clone(),
        }));
        let chunks = checkpoint.chunks(1024 * 1024);
        let count = chunks.len();
        for (index, chunk) in chunks.enumerate() {
            let mut payload = state.info.sequence.to_le_bytes().to_vec();
            payload.push(u8::from(index + 1 == count));
            payload.extend_from_slice(chunk);
            anyhow::ensure!(
                subscriber.send(Frame(CHECKPOINT, payload)),
                "checkpoint client disconnected"
            );
        }
        if let Some(code) = state.exit_code {
            subscriber.send(Frame::event(Event::Exited { code }));
        }
        state.subscribers.insert(client, subscriber);
        Ok(outbox)
    }

    pub fn checkpoint(&self, client: Uuid) -> anyhow::Result<()> {
        let state = self.state.lock().unwrap();
        let subscriber = state
            .subscribers
            .get(&client)
            .ok_or_else(|| anyhow::anyhow!("session is not attached"))?;
        let bytes = state.terminal.checkpoint().map_err(anyhow::Error::msg)?;
        let chunks = bytes.chunks(1024 * 1024);
        let count = chunks.len();
        for (index, chunk) in chunks.enumerate() {
            let mut payload = state.info.sequence.to_le_bytes().to_vec();
            payload.push(u8::from(index + 1 == count));
            payload.extend_from_slice(chunk);
            anyhow::ensure!(
                subscriber.send(Frame(CHECKPOINT, payload)),
                "snapshot client disconnected"
            );
        }
        Ok(())
    }

    pub fn detach(&self, client: Uuid) {
        if let Some(subscriber) = self.state.lock().unwrap().subscribers.remove(&client) {
            subscriber.close();
        }
    }
    pub fn finished_and_detached(&self) -> bool {
        let state = self.state.lock().unwrap();
        !state.info.alive && state.subscribers.is_empty()
    }

    pub fn input(&self, client: Uuid, bytes: Vec<u8>) -> anyhow::Result<()> {
        anyhow::ensure!(bytes.len() <= MAX_INPUT, "input frame too large");
        let state = self.state.lock().unwrap();
        anyhow::ensure!(
            state.subscribers.contains_key(&client),
            "session is not attached"
        );
        anyhow::ensure!(state.info.alive, "session exited");
        // A foreground command that never reads stdin cannot grow daemon memory.
        self.input.send(&bytes)
    }

    pub fn paste(&self, client: Uuid, text: &str) -> anyhow::Result<()> {
        anyhow::ensure!(
            text.len() <= MAX_INPUT - 12 && !text.contains('\x1b'),
            "invalid paste"
        );
        let state = self.state.lock().unwrap();
        anyhow::ensure!(
            state.subscribers.contains_key(&client) && state.info.alive,
            "session is not attached"
        );
        let bytes = if state.terminal.bracketed_paste() {
            format!("\x1b[200~{text}\x1b[201~").into_bytes()
        } else {
            text.as_bytes().to_vec()
        };
        self.input.send(&bytes)
    }

    pub fn resize(&self, client: Uuid, size: Size) -> anyhow::Result<()> {
        size.validate()?;
        let mut state = self.state.lock().unwrap();
        anyhow::ensure!(
            state.subscribers.contains_key(&client),
            "session is not attached"
        );
        self.master.lock().unwrap().resize(pty_size(size))?;
        state
            .terminal
            .resize(size.columns, size.rows, size.cell_width, size.cell_height);
        state.info.size = size;
        let frame = Frame::event(Event::Resized { size });
        state
            .subscribers
            .retain(|_, subscriber| subscriber.send(frame.clone()));
        Ok(())
    }

    pub fn terminate(&self) -> anyhow::Result<()> {
        // Hold the child lock through signalling so the reaper cannot release
        // its PID and let a later process inherit a signal intended for this job.
        let mut child = self.child.lock().unwrap();
        if child.try_wait()?.is_some() {
            return Ok(());
        }
        let pid = child
            .process_id()
            .ok_or_else(|| anyhow::anyhow!("missing child pid"))?;
        let descendants = descendants(pid)?;
        let foreground = self
            .master
            .lock()
            .unwrap()
            .as_raw_fd()
            .map(|fd| unsafe { libc::tcgetpgrp(fd) })
            .filter(|pid| *pid > 1);
        unsafe {
            if let Some(group) = foreground {
                libc::kill(-group, libc::SIGHUP);
            }
            libc::kill(-(pid as i32), libc::SIGHUP);
            libc::kill(pid as i32, libc::SIGHUP);
        }
        // Explicit close ends background jobs too, even if a shell ignores HUP.
        // Detached daemon sessions never take this path.
        for target in descendants.into_iter().rev() {
            unsafe {
                libc::kill(target as i32, libc::SIGKILL);
            }
        }
        unsafe {
            if let Some(group) = foreground {
                libc::kill(-group, libc::SIGKILL);
            }
            libc::kill(-(pid as i32), libc::SIGKILL);
            libc::kill(pid as i32, libc::SIGKILL);
        }
        Ok(())
    }
}

fn pty_size(size: Size) -> PtySize {
    PtySize {
        rows: size.rows,
        cols: size.columns,
        pixel_width: size.columns.saturating_mul(size.cell_width),
        pixel_height: size.rows.saturating_mul(size.cell_height),
    }
}

/// Capture only descendants of this daemon-owned child. Never kill by command
/// name, guessed terminal number, or a PID supplied by a GUI client.
fn descendants(root: u32) -> anyhow::Result<Vec<u32>> {
    let output = std::process::Command::new("/bin/ps")
        .args(["-axo", "pid=,ppid="])
        .output()?;
    anyhow::ensure!(output.status.success(), "cannot enumerate terminal jobs");
    let table: Vec<(u32, u32)> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            Some((fields.next()?.parse().ok()?, fields.next()?.parse().ok()?))
        })
        .collect();
    let mut result = vec![root];
    let mut index = 0;
    while index < result.len() {
        let parent = result[index];
        for &(pid, ppid) in &table {
            if ppid == parent && pid > 1 && !result.contains(&pid) {
                result.push(pid);
            }
        }
        index += 1;
    }
    result.remove(0);
    Ok(result)
}

#[cfg(target_os = "linux")]
fn process_directory(pid: u32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/cwd"))
        .ok()
        .map(|p| p.to_string_lossy().into_owned())
}
#[cfg(target_os = "macos")]
fn process_directory(pid: u32) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of_val(&info) as libc::c_int;
    let count = unsafe {
        libc::proc_pidinfo(
            pid as i32,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            size,
        )
    };
    if count != size {
        return None;
    }
    unsafe { std::ffi::CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr() as *const libc::c_char) }
        .to_str()
        .ok()
        .map(str::to_owned)
}
