// what a login session runs instead of running its payload directly
//
// The shell this replaces is in the history of modules/providers/services/users.nix. It was the
// largest piece of generated shell left in the contract, and the reason to replace it is not
// speed - it runs once per login - but that everything it handled was shell, and so everything
// it handled could run. A supervisor was a command line a shell evaluated; it is an argv that is
// executed here, so a redirection or a pipe among those values is a literal argument. A session
// variable was exported from inside double quotes, which expanded it - and a value containing a
// command substitution would have run that too.
//
// Variables are still substituted, because two real ones cannot be anything else:
// `SSH_AUTH_SOCK` is `$XDG_RUNTIME_DIR/ssh-agent`, whose runtime directory holds a uid nobody
// pinned, and `XDG_CONFIG_DIRS` extends itself the way environment.d(5) allows. What does it is
// `expand` below - four forms, none of which is a subshell, so a command substitution in a value
// is text. That is the difference worth having: no shell runs at any point in a session's life,
// so a value in this configuration cannot execute anything.
//
// The configuration is a directory of files rather than a parsed format, which is what keeps
// this dependency-free. Nix writes it; the layout is documented in users.nix beside the code
// that writes it, and read by `Config::load` below.
//
// What it does, in order, and the order is the whole design:
//
//   1. set the user's session variables, before the payload exists. The payload spawns a
//      session's applications, so anything it is not told it cannot pass on.
//   2. start the session bus, unless the session already has one. Before the payload for the
//      same reason as the variables, and because a compositor registers names on it as it
//      starts - one which comes up without a bus does not go looking for it later.
//   3. start the payload - a compositor, a shell, whatever the session is.
//   4. run `--session-env` until it succeeds. Succeeding is readiness; what it prints is what
//      the session has to tell the tree about itself, a wayland socket's name being the case
//      that matters. The payload cannot do this for itself: it is this process's child, so
//      nothing it exports reaches back here.
//   5. start the supervisor, which inherits all of that and passes it to every unit it runs.
//      That inheritance is the entire mechanism.
//   6. wait for the payload. When it exits the session is over, so the tree goes with it, and
//      the bus after the tree: the units are what was talking on it.

use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{self, BufRead, BufReader, PipeWriter, Write};
use std::os::unix::net::UnixDatagram;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::Mutex;
use std::thread::{self, sleep, JoinHandle};
use std::time::Duration;

/// where the generated configuration lives. Not a flag: `sessionLauncher` is interpolated
/// directly into greetd configuration and into tests, as one path with no arguments, and it
/// stays that way.
const CONFIG_DIR: &str = "/etc/finix/session-launch";

const POLL: Duration = Duration::from_millis(100);

/// how long the payload may take to become ready before this says so. Not a deadline - the wait
/// below is unbounded, because the payload is this process's own child and so the wait ends when
/// it exits whether or not it was ever ready. A machine stuck here would otherwise have no way
/// to say why.
const READY_REPORT_AFTER: u32 = 300;

/// how long a supervisor has to stop before SIGKILL. The launcher's half of the bound the
/// contract promises: whatever `stop` does or fails to do, a session ends.
const STOP_GRACE: u32 = 50;

/// where `--log` sends the session's output: syslog's socket, spoken to directly. A datagram per
/// line is the whole protocol, and std has the socket, so this stays dependency-free where
/// finix-rc reaches for libc's syslog(3).
const SYSLOG_SOCKET: &str = "/dev/log";

/// facility `user`, severity `info`. One priority for both streams, because by the time they
/// reach the relay they are one pipe: a compositor's stderr is where it logs, not where it
/// reports errors.
const SYSLOG_PRIORITY: u8 = 14;

/// how long teardown waits for the relay to drain. What a payload says as it dies - the reason it
/// died - is the line most worth having, and the last one to arrive.
const DRAIN_GRACE: u32 = 10;

/// the writing end of the `--log` relay, once there is one. `warn` writes here too, so a session
/// that logs says everything in one place, this program's own complaints included.
static LOG: Mutex<Option<PipeWriter>> = Mutex::new(None);

fn warn(args: std::fmt::Arguments) {
    let line = format!("session-launch: {args}\n");

    if let Ok(log) = LOG.lock() {
        if let Some(mut writer) = log.as_ref() {
            let _ = writer.write_all(line.as_bytes());
            return;
        }
    }

    let _ = io::stderr().write_all(line.as_bytes());
}

macro_rules! warn {
    ($($arg:tt)*) => { warn(format_args!($($arg)*)) };
}

/// what the system knows about one user's tree.
struct UserConfig {
    /// the argv which supervises her units, run as her, inside her session
    supervisor: Vec<String>,
    /// what stops it, where signalling the process above would not. See `supervisor.stop`.
    stop: Option<Vec<String>>,
    /// her session's environment, set before the payload. Ordered so that two runs of the same
    /// configuration set them in the same order.
    variables: BTreeMap<String, String>,
}

struct Config {
    /// the signal which asks a supervisor to stop - `supervisor.stopSignal`, one name for the
    /// implementation rather than one per user.
    stop_signal: String,
    /// `kill`, by store path. std can send SIGKILL and nothing else, so a named signal is one
    /// exec, and the path comes from the configuration rather than from a PATH this process
    /// cannot vouch for.
    kill: PathBuf,
    /// the session bus daemon, as an argv this adds its own flags to, or None on a machine
    /// without dbus. From the configuration rather than PATH for the same reason `kill` is.
    bus: Option<Vec<String>>,
    users: BTreeMap<String, UserConfig>,
}

/// a file's contents with the trailing newline removed, or None if it is not there. A missing
/// value is distinguishable from an empty one, which is what a directory of files buys.
fn read_field(path: &Path) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    Some(text.trim_end_matches('\n').to_string())
}

/// an argv: one argument per line, so that an argument with a space in it is still one argument
/// and nothing has to be quoted. A line-per-argument format cannot carry a newline inside one,
/// which no store path and no option value in this contract has.
fn read_argv(path: &Path) -> Option<Vec<String>> {
    let text = read_field(path)?;
    let argv: Vec<String> = text.lines().map(str::to_string).collect();
    if argv.is_empty() {
        None
    } else {
        Some(argv)
    }
}

impl Config {
    fn load(dir: &Path) -> io::Result<Config> {
        let stop_signal = read_field(&dir.join("stop-signal")).unwrap_or_else(|| "TERM".into());
        let kill = PathBuf::from(
            read_field(&dir.join("kill"))
                .unwrap_or_else(|| "/run/current-system/sw/bin/kill".into()),
        );

        let mut users = BTreeMap::new();
        let users_dir = dir.join("users");
        if users_dir.is_dir() {
            for entry in fs::read_dir(&users_dir)? {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                let path = entry.path();

                // a user with no supervisor is not an error here: the tree may be declared with
                // no implementation able to run it, which the contract refuses at evaluation.
                let Some(supervisor) = read_argv(&path.join("supervisor")) else {
                    continue;
                };

                let mut variables = BTreeMap::new();
                if let Some(text) = read_field(&path.join("variables")) {
                    for line in text.lines() {
                        // NAME=VALUE, split on the first `=` only: a value may contain them.
                        if let Some((name, value)) = line.split_once('=') {
                            variables.insert(name.to_string(), value.to_string());
                        }
                    }
                }

                users.insert(
                    name,
                    UserConfig {
                        supervisor,
                        stop: read_argv(&path.join("stop")),
                        variables,
                    },
                );
            }
        }

        Ok(Config {
            stop_signal,
            kill,
            bus: read_argv(&dir.join("bus")),
            users,
        })
    }
}

struct Args {
    user: String,
    /// an executable, run with no arguments. A shell command would need a shell; the contract
    /// asks for a program, and a caller with something to say in shell says it in a script.
    session_env: Option<PathBuf>,
    /// the syslog tag to relay the session's output under, or None to leave it where it was.
    log: Option<String>,
    payload: Vec<OsString>,
}

/// the user this process runs as, by name - what `--user` defaults to.
///
/// Optional because a session entry cannot know it: a `.desktop` file a greeter offers is one
/// file for everyone who logs in, so a launcher which had to be told the name could not be what
/// that file runs. From the real uid and /etc/passwd rather than `$USER`, which is whatever the
/// caller left in the environment - under `setpriv --reuid`, the previous user's.
fn current_user() -> Option<String> {
    let status = fs::read_to_string("/proc/self/status").ok()?;
    let uid = status
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))?
        .split_whitespace()
        .next()?
        .to_string();

    fs::read_to_string("/etc/passwd")
        .ok()?
        .lines()
        .find_map(|line| {
            let mut fields = line.split(':');
            let name = fields.next()?;
            (fields.nth(1)? == uid).then(|| name.to_string())
        })
}

fn usage(message: &str) -> ! {
    warn!("{message}");
    std::process::exit(2);
}

fn parse_args() -> Args {
    let mut user = None;
    let mut session_env = None;
    let mut log = None;
    let mut payload = Vec::new();

    let mut args = env::args_os().skip(1);
    while let Some(arg) = args.next() {
        match arg.to_string_lossy().as_ref() {
            "--user" => {
                user = Some(match args.next() {
                    Some(v) => v.to_string_lossy().into_owned(),
                    None => usage("--user needs a value"),
                })
            }
            "--session-env" => {
                session_env = Some(match args.next() {
                    Some(v) => PathBuf::from(v),
                    None => usage("--session-env needs a value"),
                })
            }
            "--log" => {
                log = Some(match args.next() {
                    Some(v) => v.to_string_lossy().into_owned(),
                    None => usage("--log needs a tag"),
                })
            }
            "--" => {
                payload.extend(args);
                break;
            }
            other => usage(&format!("unrecognised argument {other}")),
        }
    }

    let Some(user) = user.or_else(current_user) else {
        usage("--user was not given, and the current uid has no entry in /etc/passwd")
    };
    if payload.is_empty() {
        usage("nothing to run");
    }

    Args {
        user,
        session_env,
        log,
        payload,
    }
}

/// a command from an argv. The first element is the program; there is no shell, so a redirection
/// substitute variable references in a session variable's value.
///
/// Not a shell, and the difference is the point. Four forms are recognised - `$NAME`,
/// `${NAME}`, `${NAME:+text}` and `${NAME:-text}` - and nothing else means anything. A `$`
/// which does not begin one of them is a literal `$`, so a value containing `$(hostname)` or a
/// backtick is that text and not a command: there is no subshell here to run one, which is the
/// property the shell version could not offer.
///
/// This exists because two real values need it. `SSH_AUTH_SOCK` is
/// `$XDG_RUNTIME_DIR/ssh-agent`, which cannot be computed at build time - the runtime directory
/// holds a uid, and a configuration which does not pin one has no uid to write down. And
/// `XDG_CONFIG_DIRS` is a store path plus `${XDG_CONFIG_DIRS:+:$XDG_CONFIG_DIRS}`, which is how
/// environment.d(5) spells "extend this, if there is anything to extend".
///
/// `:+` and `:-` are the same two the shell has: `:+` substitutes its text when the variable is
/// set and non-empty, `:-` when it is not. The text is substituted in turn, which is what makes
/// the `XDG_CONFIG_DIRS` form work - the thing being appended is itself a reference.
///
/// Unset is empty, as in a shell. A reference to a variable this pass has already set sees the
/// new value, because they are set one at a time in the order Nix wrote them - the same
/// sequential behaviour the exports had.
fn expand(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i] != b'$' {
            // not a reference. Pushed by byte index rather than by char because the only thing
            // being matched is ASCII, and a multi-byte character cannot contain one of these.
            let start = i;
            while i < bytes.len() && bytes[i] != b'$' {
                i += 1;
            }
            out.push_str(&input[start..i]);
            continue;
        }

        // `${...}`
        if let Some(b'{') = bytes.get(i + 1) {
            if let Some(end) = input[i + 2..].find('}') {
                let body = &input[i + 2..i + 2 + end];
                i = i + 3 + end;

                let (name, alternate) = match body.find(":+") {
                    Some(at) => (&body[..at], Some((true, &body[at + 2..]))),
                    None => match body.find(":-") {
                        Some(at) => (&body[..at], Some((false, &body[at + 2..]))),
                        None => (body, None),
                    },
                };

                if !is_name(name) {
                    // not a reference after all, so it is the text it looks like
                    out.push_str("${");
                    out.push_str(body);
                    out.push('}');
                    continue;
                }

                let value = env::var(name).unwrap_or_default();
                match alternate {
                    Some((when_set, text)) => {
                        if when_set == !value.is_empty() {
                            out.push_str(&expand(text));
                        }
                    }
                    None => out.push_str(&value),
                }
                continue;
            }

            // an unclosed `${`, which is text
            out.push('$');
            i += 1;
            continue;
        }

        // `$NAME`
        let start = i + 1;
        let mut end = start;
        while end < bytes.len() && is_name_byte(bytes[end], end == start) {
            end += 1;
        }

        if end == start {
            // a bare `$`: literal, which is what makes `$(hostname)` text rather than a command
            out.push('$');
            i += 1;
            continue;
        }

        out.push_str(&env::var(&input[start..end]).unwrap_or_default());
        i = end;
    }

    out
}

fn is_name_byte(b: u8, first: bool) -> bool {
    b == b'_' || b.is_ascii_alphabetic() || (!first && b.is_ascii_digit())
}

fn is_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .enumerate()
            .all(|(i, b)| is_name_byte(b, i == 0))
}

/// or a pipe in a configuration value is a literal argument rather than something that happens.
fn command(argv: &[String]) -> Command {
    let mut c = Command::new(&argv[0]);
    c.args(&argv[1..]);
    c
}

/// the status a process exited with, as a shell would report it: a signal becomes 128 + n.
fn status_code(status: ExitStatus) -> i32 {
    status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}

/// run `--session-env` until it succeeds, exporting what it printed.
///
/// Returns Err with the payload's status if the payload exits first, which is not a failure of
/// this program: a session whose compositor died before it was usable exits with the
/// compositor's status.
fn await_session(probe: &Path, payload: &mut Child, payload_argv0: &str) -> Result<(), i32> {
    let mut waited = 0u32;

    loop {
        let output = Command::new(probe).stderr(Stdio::null()).output();

        if let Ok(output) = output {
            if output.status.success() {
                // one NAME=VALUE per line, set one at a time: a value may contain spaces, and
                // the shell this replaces had to be careful not to split them into arguments.
                for line in String::from_utf8_lossy(&output.stdout).lines() {
                    if let Some((name, value)) = line.split_once('=') {
                        env::set_var(name, value);
                    }
                }
                return Ok(());
            }
        }

        if let Ok(Some(status)) = payload.try_wait() {
            warn!("{payload_argv0} exited before the session was ready");
            return Err(status_code(status));
        }

        sleep(POLL);
        waited += 1;

        if waited == READY_REPORT_AFTER {
            warn!("still waiting for the session after 30s");
        }
    }
}

/// wait for the payload, watching the supervisor beside it.
///
/// Polled rather than a blocking wait so that a supervisor which fails is reported when it
/// happens. That report used to be each backend's own business - a line the systemd module's
/// wrapper printed - and it was the only evidence there was when that backend's user manager
/// could not start. Here it is every implementation's, for free.
fn await_payload(payload: &mut Child, supervisor: Option<&mut Child>, user: &str) -> i32 {
    let mut supervisor = supervisor;
    let mut reported = false;

    loop {
        if let Ok(Some(status)) = payload.try_wait() {
            return status_code(status);
        }

        if let Some(child) = supervisor.as_deref_mut() {
            if let Ok(Some(status)) = child.try_wait() {
                if !reported {
                    reported = true;
                    let code = status_code(status);
                    if code != 0 {
                        warn!("the supervisor for {user} exited {code}");
                    }
                }
                // stop looking at it: it is reaped, and the session continues without a tree
                // rather than ending because of one.
                supervisor = None;
            }
        }

        sleep(POLL);
    }
}

/// wait for a child that has been asked to stop, killing it if it takes longer than the grace
/// period. Shared by the supervisor and the bus, which are stopped differently and must both end.
fn reap_within_grace(child: &mut Child, what: &str) {
    let mut waited = 0u32;
    while waited < STOP_GRACE {
        if let Ok(Some(_)) = child.try_wait() {
            return;
        }
        sleep(POLL);
        waited += 1;
    }

    warn!("{what} did not stop; killing it");
    let _ = child.kill();
    let _ = child.wait();
}

/// stop the supervisor, by whichever means the implementation named, and make sure it is gone.
fn stop_supervisor(config: &Config, user: &UserConfig, name: &str, child: &mut Child) {
    if let Ok(Some(_)) = child.try_wait() {
        // already gone, and already reported by `await_payload` if it mattered
        return;
    }

    match &user.stop {
        Some(argv) => {
            let _ = command(argv).status();
        }
        None => {
            let _ = Command::new(&config.kill)
                .arg(format!("-{}", config.stop_signal))
                .arg(child.id().to_string())
                .status();
        }
    }

    reap_within_grace(child, &format!("the supervisor for {name}"));
}

/// stdout and stderr for a child: the relay's pipe when `--log` asked for one, and this
/// process's own streams otherwise, which is what a child gets by default.
fn output() -> (Stdio, Stdio) {
    let clone = || {
        LOG.lock()
            .ok()?
            .as_ref()
            .and_then(|writer| writer.try_clone().ok())
            .map(Stdio::from)
    };

    match (clone(), clone()) {
        (Some(out), Some(err)) => (out, err),
        _ => (Stdio::inherit(), Stdio::inherit()),
    }
}

/// SGR sequences removed, and nothing else. A log is not a terminal, and colour arrives as
/// `ESC [ <digits and semicolons> m` - dinit's `[ OK ]` among it - which syslog would keep as
/// noise. Other escapes, an OSC palette sequence say, are not what anything renders colour with,
/// and are left as they came.
fn strip_sgr(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;

    while let Some(at) = rest.find("\x1b[") {
        out.push_str(&rest[..at]);
        let after = &rest[at + 2..];
        let params = after
            .bytes()
            .take_while(|b| b.is_ascii_digit() || *b == b';')
            .count();

        if after.as_bytes().get(params) == Some(&b'm') {
            rest = &after[params + 1..];
        } else {
            out.push_str("\x1b[");
            rest = after;
        }
    }

    out.push_str(rest);
    out
}

/// relay everything written to the returned pipe to syslog, a line per message, under `tag`.
///
/// What it replaces is a session wrapper's `exec > >(sed | logger)`: a shell, two more processes,
/// and a pipeline that existed because greetd gives a session a terminal and keeps nothing it
/// says. Here it is a thread, and the colour is stripped by the same code that sends the line.
///
/// A line that cannot be sent goes to this process's own stderr instead, so a machine with no
/// syslog daemon - or one whose daemon restarted mid-session - loses nothing it would not have
/// lost anyway. A restart is retried once with a fresh connection before falling back.
fn relay(tag: String) -> io::Result<(PipeWriter, JoinHandle<()>)> {
    let (reader, writer) = io::pipe()?;
    let pid = std::process::id();

    let connect = || {
        let socket = UnixDatagram::unbound().ok()?;
        socket.connect(SYSLOG_SOCKET).ok()?;
        Some(socket)
    };

    let handle = thread::spawn(move || {
        let mut socket = connect();
        let mut err = io::stderr();

        for line in BufReader::new(reader).split(b'\n') {
            let Ok(line) = line else { break };
            let text = strip_sgr(&String::from_utf8_lossy(&line));
            let message = format!("<{SYSLOG_PRIORITY}>{tag}[{pid}]: {text}");

            let mut sent = socket
                .as_ref()
                .is_some_and(|s| s.send(message.as_bytes()).is_ok());
            if !sent {
                socket = connect();
                sent = socket
                    .as_ref()
                    .is_some_and(|s| s.send(message.as_bytes()).is_ok());
            }
            if !sent {
                let _ = writeln!(err, "{text}");
            }
        }
    });

    Ok((writer, handle))
}

/// start the session bus, unless the session already has one.
///
/// What `dbus-run-session` did around every session, done here so that a session is one command:
/// a bus is something every graphical session needs and none of them should have to remember.
/// One already in the environment is used as it is - a nested session, or one started under
/// something else that provides a bus - because a second would split the session in two.
///
/// `unix:dir=` rather than a fixed path: the socket is in the session's runtime directory, so it
/// goes when the session does, under a name the daemon picks, so two sessions of one user do not
/// contend for it. What that gives up is being findable by convention - something outside the
/// session cannot guess the address, and learns it the way the session's children do, by
/// inheriting it. That is what dbus-run-session gave, too.
fn start_bus(argv: &[String]) -> Option<Child> {
    if env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some() {
        return None;
    }

    let mut daemon = command(argv);
    daemon.arg("--nofork").arg("--print-address");
    if let Some(dir) = env::var_os("XDG_RUNTIME_DIR") {
        let mut address = OsString::from("--address=unix:dir=");
        address.push(dir);
        daemon.arg(address);
    }

    let (_, err) = output();
    let mut child = match daemon.stdout(Stdio::piped()).stderr(err).spawn() {
        Ok(child) => child,
        Err(error) => {
            warn!("could not start the session bus: {error}");
            return None;
        }
    };

    // the address, on one line, once the daemon is listening - which makes reading it the
    // readiness check as well. Nothing else is ever written there, so the pipe can be dropped.
    let mut address = String::new();
    let read = child
        .stdout
        .take()
        .map(|stdout| BufReader::new(stdout).read_line(&mut address));

    let address = address.trim_end();
    if !matches!(read, Some(Ok(n)) if n > 0) || address.is_empty() {
        warn!("the session bus exited without an address; the session has no bus");
        let _ = child.kill();
        let _ = child.wait();
        return None;
    }

    env::set_var("DBUS_SESSION_BUS_ADDRESS", address);
    Some(child)
}

/// stop the bus, after the tree, and wait for it.
fn stop_bus(config: &Config, child: &mut Child) {
    if let Ok(Some(_)) = child.try_wait() {
        return;
    }

    let _ = Command::new(&config.kill)
        .arg("-TERM")
        .arg(child.id().to_string())
        .status();

    reap_within_grace(child, "the session bus");
}

/// the end of every session, whichever way it ended: the bus goes, the relay is given what is
/// left in the pipe, and the payload's status is this process's.
fn finish(
    config: &Config,
    bus: Option<&mut Child>,
    relay: Option<JoinHandle<()>>,
    status: i32,
) -> ! {
    if let Some(child) = bus {
        stop_bus(config, child);
    }

    if let Some(handle) = relay {
        // the relay ends when every writer has closed. The payload, the supervisor and the bus
        // are gone by now; this is the last copy. Bounded, because something the bus activated
        // can outlive it holding the pipe, and a logout does not wait on that.
        if let Ok(mut log) = LOG.lock() {
            log.take();
        }

        let mut waited = 0u32;
        while !handle.is_finished() && waited < DRAIN_GRACE {
            sleep(POLL);
            waited += 1;
        }
    }

    std::process::exit(status);
}

fn main() {
    let args = parse_args();

    // first, so that everything after it - this program's own warnings included - is said where
    // the session asked for it to be said.
    let relay = args.log.clone().and_then(|tag| match relay(tag) {
        Ok((writer, handle)) => {
            if let Ok(mut log) = LOG.lock() {
                *log = Some(writer);
            }
            Some(handle)
        }
        Err(error) => {
            warn!("could not start the log relay: {error}");
            None
        }
    });

    let config = match Config::load(Path::new(CONFIG_DIR)) {
        Ok(config) => config,
        Err(error) => {
            warn!("could not read {CONFIG_DIR}: {error}");
            std::process::exit(1);
        }
    };

    let user = config.users.get(&args.user);
    if user.is_none() {
        // the same thing the shell said, and not fatal: the session is the point, and a user
        // with no tree declared for her should still get one.
        warn!("no service tree is declared for {}", args.user);
    }

    // before the payload, which is the half that was broken when these were exported by a
    // supervisor started at boot: everything the payload spawns inherits from here.
    if let Some(user) = user {
        for (name, value) in &user.variables {
            env::set_var(name, expand(value));
        }
    }

    let mut bus = config.bus.as_deref().and_then(start_bus);

    let payload_argv0 = args.payload[0].to_string_lossy().into_owned();
    let (out, err) = output();
    let mut payload = match Command::new(&args.payload[0])
        .args(&args.payload[1..])
        .stdout(out)
        .stderr(err)
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            warn!("could not run {payload_argv0}: {error}");
            finish(&config, bus.as_mut(), relay, 1);
        }
    };

    if let Some(probe) = &args.session_env {
        if let Err(status) = await_session(probe, &mut payload, &payload_argv0) {
            finish(&config, bus.as_mut(), relay, status);
        }
    }

    // after the readiness check, for the same reason the variables are before the payload: a
    // value the payload publishes on becoming ready is in this environment by now, and the
    // supervisor is what passes it on to the tree.
    let mut supervisor = user.and_then(|user| {
        let (out, err) = output();
        match command(&user.supervisor).stdout(out).stderr(err).spawn() {
            Ok(child) => Some(child),
            Err(error) => {
                warn!("could not start the supervisor for {}: {error}", args.user);
                None
            }
        }
    });

    let status = await_payload(&mut payload, supervisor.as_mut(), &args.user);

    // the session is over, so the tree goes with it. This is the half a supervisor started at
    // boot cannot do at all: nothing tells it a session ended, so its units keep running with
    // nothing to serve.
    if let (Some(user), Some(child)) = (user, supervisor.as_mut()) {
        stop_supervisor(&config, user, &args.user, child);
    }

    finish(&config, bus.as_mut(), relay, status);
}
