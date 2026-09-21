//! Kero's headless services. The GUI and remote bridge are clients, never PTY owners.
pub mod gateway;
pub mod host;
pub mod images;
pub mod protocol;
pub mod runtime;
pub mod session;
pub mod ssh;
