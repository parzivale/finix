//! A unit's output, sent where the rest of the system's output goes.
//!
//! The thin backends used to drop it. A unit's stdout and stderr were inherited from rc.init,
//! which inherits from pid 1, so everything a service said landed on the console and was gone as
//! soon as anything else drew on the screen. Daemons which call `syslog(3)` for themselves -
//! dhcpcd, avahi, bluetoothd - were unaffected and looked fine, which is what made the gap easy
//! to miss: the log was full, just never of the daemon being asked about.
//!
//! What that cost: iwd writes to stdout, so on a machine where it was the only thing managing
//! the network, "why did wifi not come back after a suspend" had no evidence at all. finit
//! forwards unit output to syslog and dinit buffers it; these two did neither.
//!
//! Relayed in this process rather than by piping each unit into `logger`. The job is already a
//! program, it already links libc, and a reader thread per stream costs nothing next to a second
//! process per service.

use std::ffi::CString;
use std::io::{BufRead, BufReader, Read};
use std::thread::JoinHandle;

/// The ident `openlog` is given has to outlive every `syslog` call - it keeps the pointer rather
/// than copying the string - so this deliberately leaks one CString. A job process serves exactly
/// one unit and then exits, so that is one small allocation for the life of the process, not a
/// leak that grows.
pub fn open(ident: &str) {
    let Ok(ident) = CString::new(ident) else {
        return;
    };

    let ident = Box::leak(ident.into_boxed_c_str());

    unsafe {
        // LOG_CONS so a message written before syslogd is up still reaches the console, which is
        // where all of this went before. Early units - the ones that run before the log daemon
        // exists - therefore behave exactly as they used to, and everything after it is captured.
        libc::openlog(ident.as_ptr(), libc::LOG_CONS, libc::LOG_DAEMON);
    }
}

/// One line, at the given priority.
///
/// `"%s"` and the text as an argument, never the text as the format. A unit which logs a literal
/// `%s` would otherwise have it interpreted, reading whatever happened to be next on the stack.
pub fn line(priority: libc::c_int, message: &str) {
    let Ok(message) = CString::new(message.replace('\0', "")) else {
        return;
    };

    unsafe {
        libc::syslog(priority, c"%s".as_ptr(), message.as_ptr());
    }
}

/// Read a stream to EOF, one line per message.
///
/// EOF is the child exiting, so the thread ends with it and nothing has to be joined or
/// cancelled - which is what makes this safe to do again on every pass of a respawn loop.
///
/// Lines rather than chunks because syslog is a line protocol; a daemon which writes without a
/// trailing newline has its last partial line delivered when the stream closes.
pub fn relay<R: Read + Send + 'static>(stream: R, priority: libc::c_int) -> JoinHandle<()> {
    std::thread::spawn(move || {
        let reader = BufReader::new(stream);

        // `split(b'\n')` rather than `lines()`: a daemon is not obliged to write UTF-8, and
        // `lines()` ends the whole stream at the first byte that is not. Lossy per line instead,
        // so one bad line costs that line.
        for chunk in reader.split(b'\n') {
            let Ok(chunk) = chunk else { break };
            let text = String::from_utf8_lossy(&chunk);
            let text = text.trim_end_matches('\r');

            if !text.is_empty() {
                line(priority, text);
            }
        }
    })
}
