//! Which tree a bare unit name means.
//!
//! The only real logic in this tool, and the reason it is a program. The rest is argument parsing
//! and execing a command somebody else supplied; this is a decision, it is made from a table
//! known at build time, and getting it wrong means acting on the wrong machine's idea of a unit.
//!
//! The order is deliberate and is not "closest match":
//!
//!   1. the caller's own tree. A person typing `initctl restart mako` means the mako in their
//!      session, and having to say so with `--user` every time is the thing this tool exists to
//!      stop.
//!   2. the system's.
//!   3. the only candidate, if there is exactly one.
//!   4. otherwise refuse, naming the choice. Acting on whichever supervisor answered first would
//!      make the tool do different things depending on timing.
//!
//! In shell this was a function which could not return a value - it set a variable instead,
//! because the first version printed the answer, was therefore called in `$(...)`, and its
//! refusal `exit`ed the subshell rather than the script. `initctl` reported "no unit named ..."
//! and then exited 0. That is what a `Result` is.

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Entry {
    pub tree: String,
    pub unit: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Unknown {
        unit: String,
        want: Option<String>,
    },
    Ambiguous {
        unit: String,
        trees: Vec<String>,
    },
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Unknown { unit, want } => {
                write!(f, "initctl: no unit named '{unit}'")?;
                if let Some(want) = want {
                    write!(f, " in {want}")?;
                }
                Ok(())
            }
            Error::Ambiguous { unit, trees } => write!(
                f,
                "initctl: '{unit}' is in: {} - name one with --user",
                trees.join(" ")
            ),
        }
    }
}

/// `me` is the caller's own name, which is `id -un` - the tree they own, if they own one.
pub fn resolve(
    index: &[Entry],
    unit: &str,
    want: Option<&str>,
    me: &str,
) -> Result<String, Error> {
    let candidates: Vec<&str> = index
        .iter()
        .filter(|e| e.unit == unit)
        .filter(|e| want.is_none_or(|w| e.tree == w))
        .map(|e| e.tree.as_str())
        .collect();

    if candidates.is_empty() {
        return Err(Error::Unknown {
            unit: unit.to_string(),
            want: want.map(str::to_string),
        });
    }

    for preferred in [me, "system"] {
        if candidates.contains(&preferred) {
            return Ok(preferred.to_string());
        }
    }

    if let [only] = candidates.as_slice() {
        return Ok(only.to_string());
    }

    Err(Error::Ambiguous {
        unit: unit.to_string(),
        trees: candidates.iter().map(|t| t.to_string()).collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index() -> Vec<Entry> {
        [
            ("system", "shared"),
            ("system", "sshd"),
            ("alice", "shared"),
            ("alice", "agent"),
            ("bob", "agent"),
        ]
        .into_iter()
        .map(|(tree, unit)| Entry {
            tree: tree.to_string(),
            unit: unit.to_string(),
        })
        .collect()
    }

    #[test]
    fn unqualified_prefers_the_callers_own_tree() {
        assert_eq!(resolve(&index(), "shared", None, "alice").unwrap(), "alice");
    }

    #[test]
    fn and_the_system_tree_for_a_caller_who_owns_none() {
        // root owns no tree, so the system's is what an unqualified name means. The alternative
        // is a tool which answers about somebody else's units when asked without qualification.
        assert_eq!(resolve(&index(), "shared", None, "root").unwrap(), "system");
    }

    #[test]
    fn a_sole_candidate_wins_without_a_preference() {
        assert_eq!(resolve(&index(), "agent", None, "alice").unwrap(), "alice");
    }

    #[test]
    fn two_user_trees_and_no_preference_is_refused() {
        let err = resolve(&index(), "agent", None, "root").unwrap_err();

        match &err {
            Error::Ambiguous { trees, .. } => {
                assert!(trees.contains(&"alice".to_string()));
                assert!(trees.contains(&"bob".to_string()));
            }
            other => panic!("expected ambiguity, got {other:?}"),
        }

        assert!(err.to_string().contains("--user"));
    }

    #[test]
    fn naming_a_tree_resolves_it() {
        assert_eq!(
            resolve(&index(), "agent", Some("bob"), "root").unwrap(),
            "bob"
        );
    }

    #[test]
    fn naming_a_tree_overrides_the_preference_order() {
        // the case the flag exists for: `shared` is in the system tree and alice's, and without
        // this the system's would win for root whatever was asked.
        assert_eq!(
            resolve(&index(), "shared", Some("alice"), "root").unwrap(),
            "alice"
        );
    }

    #[test]
    fn a_name_absent_from_the_named_tree_is_unknown_in_that_tree() {
        let err = resolve(&index(), "shared", Some("bob"), "root").unwrap_err();

        assert_eq!(
            err,
            Error::Unknown {
                unit: "shared".to_string(),
                want: Some("bob".to_string()),
            }
        );
        assert!(err.to_string().contains("in bob"));
    }

    #[test]
    fn an_unknown_name_is_unknown_everywhere() {
        assert_eq!(
            resolve(&index(), "nope", None, "root").unwrap_err(),
            Error::Unknown {
                unit: "nope".to_string(),
                want: None,
            }
        );
    }

    #[test]
    fn the_system_tree_can_be_forced_by_name() {
        // `--system` is `--user system` with a nicer spelling, which is worth pinning: the tree
        // named `system` is an ordinary entry in the index and nothing special-cases it here.
        assert_eq!(
            resolve(&index(), "shared", Some("system"), "alice").unwrap(),
            "system"
        );
    }
}
