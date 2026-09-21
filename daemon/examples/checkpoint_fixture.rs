//! Export real canonical checkpoints for renderer conformance checks.
use kero_terminal_state::TerminalState;
fn main() -> anyhow::Result<()> {
    let args: Vec<_> = std::env::args().collect();
    let cols = args[1].parse()?;
    let rows = args[2].parse()?;
    let directory = std::path::Path::new(&args[3]);
    std::fs::create_dir_all(directory)?;
    let scenarios:Vec<(&str,Vec<u8>,Vec<u8>)>=vec![
        ("kitty-cursor", b"before\r\n\x1b_Ga=T,f=32,s=1,v=1,i=44,p=9,c=3,r=2;/wAA/w==\x1b\\".to_vec(),b"after".to_vec()),
        ("kitty-inline",b"image\r\n\x1b_Ga=T,f=32,s=1,v=1,i=42,p=7,c=3,r=2,C=1;/wAA/w==\x1b\\".to_vec(),b"after".to_vec()),
        ("kitty-split",b"\x1b[?1049h\x1b[4;5H\x1b_Ga=T,f=32,s=1,v=1,i=43,p=8,c=3,r=2,C=1,m=1;AP8A\x1b\\\x1b_Gm=0;/w".to_vec(),b"==\x1b\\tail".to_vec()),
        ("primary",b"shell> \x1b[31mred\x1b[0m\r\n\x1b[?1h\x1b[?2004h".to_vec(),"中文 e\u{301}\r\nnext".as_bytes().to_vec()),
        ("alternate","primary 中文\r\n\x1b[?1049h\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[3;14r\x1b[?6h\x1b[4;7H\x1b[32mTUI中文\x1b[6;9H\x1b[4 q".as_bytes().to_vec(),b"next\r\n\x1b[?1049lmore".to_vec()),
        ("split-csi",b"\x1b[?1049h\x1b[2;8H\x1b[38;2;12;".to_vec(),b"34;56mcolored\x1b[0m".to_vec()),
        ("split-utf8",[b"UTF8:".as_slice(),&[0xe4,0xb8]].concat(),[&[0xad][..],"文!".as_bytes()].concat()),
        ("repeat",b"Z\x1b[2J\x1b[5;9H\x1b[".to_vec(),b"4brepeated".to_vec()),
        ("saved-cursor",b"\x1b[3;4H\x1b[31m\x1b7\x1b[8;11H\x1b[32mnow".to_vec(),b"\x1b8saved".to_vec()),
        ("history",(0..50000).map(|i|format!("line {i:05} 中文\r\n")).collect::<String>().into_bytes(),b"after-history\r\n".to_vec()),
        ("synchronized",b"before\x1b[?2026hbuffered".to_vec(),b"-complete\x1b[?2026l".to_vec()),
    ];
    let mut names = Vec::new();
    for (name, initial, next) in scenarios {
        let initial = [b"\x1b[2 q".as_slice(), initial.as_slice()].concat();
        let mut state = TerminalState::new(cols, rows, 8, 16);
        state.feed(&initial);
        std::fs::write(directory.join(format!("{name}.initial")), initial)?;
        std::fs::write(
            directory.join(format!("{name}.checkpoint")),
            state.checkpoint().map_err(anyhow::Error::msg)?,
        )?;
        std::fs::write(directory.join(format!("{name}.next")), next)?;
        names.push(name);
    }
    std::fs::write(directory.join("names.json"), serde_json::to_vec(&names)?)?;
    Ok(())
}
