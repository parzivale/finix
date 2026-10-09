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
//   2. start the payload - a compositor, a shell, whatever the session is.
//   3. run `--session-env` until it succeeds. Succeeding is readiness; what it prints is what
//      the session has to tell the tree about itself, a wayland socket's name being the case
//      that matters. The payload cannot do this for itself: it is this process's child, so
//      nothing it exports reaches back here.
//   4. start the supervisor, which inherits all of that and passes it to every unit it runs.
//      That inheritance is the entire mechanism.
//   5. wait for the payload. When it exits the session is over, so the tree goes with it.

use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{self, Write};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread::sleep;
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

fn warn(args: std::fmt::Arguments) {
    let mut err = io::stderr();
    let _ = writeln!(err, "session-launch: {args}");
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
            users,
        })
    }
}

struct Args {
    user: String,
    /// an executable, run with no arguments. A shell command would need a shell; the contract
    /// asks for a program, and a caller with something to say in shell says it in a script.
    session_env: Option<PathBuf>,
    payload: Vec<OsString>,
}

fn usage(message: &str) -> ! {
    warn!("{message}");
    std::process::exit(2);
}

fn parse_args() -> Args {
    let mut user = None;
    let mut session_env = None;
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
            "--" => {
                payload.extend(args);
                break;
            }
            other => usage(&format!("unrecognised argument {other}")),
        }
    }

    let Some(user) = user else {
        usage("--user is required")
    };
    if payload.is_empty() {
        usage("nothing to run");
    }

    Args {
        user,
        session_env,
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

    let mut waited = 0u32;
    while waited < STOP_GRACE {
        if let Ok(Some(_)) = child.try_wait() {
            return;
        }
        sleep(POLL);
        waited += 1;
    }

    warn!("the supervisor for {name} did not stop; killing it");
    let _ = child.kill();
    let _ = child.wait();
}

fn main() {
    let args = parse_args();

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

    let payload_argv0 = args.payload[0].to_string_lossy().into_owned();
    let mut payload = match Command::new(&args.payload[0])
        .args(&args.payload[1..])
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            warn!("could not run {payload_argv0}: {error}");
            std::process::exit(1);
        }
    };

    if let Some(probe) = &args.session_env {
        if let Err(status) = await_session(probe, &mut payload, &payload_argv0) {
            std::process::exit(status);
        }
    }

    // after the readiness check, for the same reason the variables are before the payload: a
    // value the payload publishes on becoming ready is in this environment by now, and the
    // supervisor is what passes it on to the tree.
    let mut supervisor = user.and_then(|user| match command(&user.supervisor).spawn() {
        Ok(child) => Some(child),
        Err(error) => {
            warn!("could not start the supervisor for {}: {error}", args.user);
            None
        }
    });

    let status = await_payload(&mut payload, supervisor.as_mut(), &args.user);

    // the session is over, so the tree goes with it. This is the half a supervisor started at
    // boot cannot do at all: nothing tells it a session ended, so its units keep running with
    // nothing to serve.
    if let (Some(user), Some(child)) = (user, supervisor.as_mut()) {
        stop_supervisor(&config, user, &args.user, child);
    }

    std::process::exit(status);
}
