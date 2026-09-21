use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use uuid::Uuid;

pub const VERSION: u32 = 1;
pub const MAX_FRAME: usize = 8 * 1024 * 1024;
pub const CONTROL: u8 = 1;
pub const OUTPUT: u8 = 2;
pub const INPUT: u8 = 3;
/// Checkpoint chunks: u64 sequence, u8 final flag, then VT state bytes.
/// These are never counted as PTY output or echoed back to the daemon.
pub const CHECKPOINT: u8 = 4;

/// Explicit identities prevent reconnecting a saved pane to a replacement daemon.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionKey {
    pub host: Uuid,
    pub instance: Uuid,
    pub session: Uuid,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Size {
    pub columns: u16,
    pub rows: u16,
    #[serde(default)]
    pub cell_width: u16,
    #[serde(default)]
    pub cell_height: u16,
}
impl Size {
    pub fn validate(self) -> io::Result<Self> {
        if self.columns == 0 || self.rows == 0 || self.columns > 1000 || self.rows > 1000 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid terminal dimensions",
            ));
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Launch {
    pub session: Uuid,
    pub directory: String,
    pub program: String,
    pub arguments: Vec<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    #[serde(default, deserialize_with = "deserialize_colors")]
    pub colors: BTreeMap<usize, [u8; 3]>,
    #[serde(default)]
    pub cursor_style: Option<u8>,
    #[serde(default)]
    pub history: Option<String>,
    pub size: Size,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    Hello {
        version: u32,
    },
    Create {
        launch: Launch,
    },
    Attach {
        key: SessionKey,
    },
    AttachSized {
        key: SessionKey,
        size: Size,
    },
    Resize {
        key: SessionKey,
        size: Size,
    },
    Checkpoint {
        key: SessionKey,
    },
    Colors {
        key: SessionKey,
        #[serde(deserialize_with = "deserialize_colors")]
        colors: std::collections::BTreeMap<usize, [u8; 3]>,
        #[serde(default)]
        cursor_style: Option<u8>,
    },
    Detach,
    Terminate {
        key: SessionKey,
    },
    List,
    UploadImage {
        key: SessionKey,
        data: String,
    },
    Paste {
        key: SessionKey,
        text: String,
    },
    Watch {
        paths: Vec<crate::host::HostPath>,
    },
    Host {
        request: crate::host::HostRequest,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub key: SessionKey,
    pub pid: u32,
    pub directory: String,
    pub size: Size,
    pub alive: bool,
    pub sequence: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    Hello {
        version: u32,
        host: Uuid,
        instance: Uuid,
        capabilities: Vec<String>,
    },
    Created {
        session: SessionInfo,
    },
    Attached {
        session: SessionInfo,
    },
    Directory {
        path: String,
    },
    Resized {
        size: Size,
    },
    Detached,
    Watching,
    Changed {
        paths: Vec<crate::host::HostPath>,
    },
    Terminated,
    ImageUploaded {
        path: String,
        sha256: String,
    },
    Sessions {
        sessions: Vec<SessionInfo>,
    },
    Exited {
        code: u32,
    },
    Host {
        response: crate::host::HostResponse,
    },
    Error {
        code: String,
        message: String,
    },
}

/// tty7 framing at the pinned revision; the Kero dialect uses different kinds
/// and is intentionally not compatible with tty7's socket namespace. Enforce a
/// smaller limit *before* allocation, including for untrusted SSH peers.
pub fn read_frame(reader: &mut impl Read) -> io::Result<(u8, Vec<u8>)> {
    let mut header = [0; 5];
    reader.read_exact(&mut header)?;
    let len = u32::from_le_bytes(header[..4].try_into().unwrap()) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    let mut data = vec![0; len];
    reader.read_exact(&mut data)?;
    Ok((header[4], data))
}
pub fn write_frame(writer: &mut impl Write, kind: u8, bytes: &[u8]) -> io::Result<()> {
    if bytes.len() > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    tty7_core::daemon::protocol::write_frame(writer, kind, bytes)
}

#[derive(Clone, Debug)]
pub struct Frame(pub u8, pub Vec<u8>);
impl Frame {
    pub fn event(event: Event) -> Self {
        Self(
            CONTROL,
            serde_json::to_vec(&event).expect("event serialization"),
        )
    }
}

// Internally tagged requests are deserialized through serde's Content map,
// where numeric JSON object keys remain strings rather than usize keys.
fn deserialize_colors<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<BTreeMap<usize, [u8; 3]>, D::Error> {
    let map = BTreeMap::<String, [u8; 3]>::deserialize(deserializer)?;
    map.into_iter()
        .map(|(key, value)| {
            let index = key.parse::<usize>().map_err(serde::de::Error::custom)?;
            if index > 258 {
                return Err(serde::de::Error::custom("invalid palette index"));
            }
            Ok((index, value))
        })
        .collect()
}
