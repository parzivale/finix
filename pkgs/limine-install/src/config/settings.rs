use serde::Deserialize;

/// A value of the module's freeform `settings` attrset. Anything limine's
/// config understands is a key here, so the only structure we can rely on is
/// "one value or a list of them".
#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub(crate) enum Setting {
    One(Scalar),
    Many(Vec<Scalar>),
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub(crate) enum Scalar {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
}

impl Scalar {
    /// How limine.conf spells this value; `None` for a key that should not be
    /// emitted at all.
    pub(crate) fn value(&self) -> Option<String> {
        Some(match self {
            Self::Null => return None,
            Self::Bool(true) => "yes".to_owned(),
            Self::Bool(false) => "no".to_owned(),
            Self::Int(i) => i.to_string(),
            Self::Float(f) => f.to_string(),
            Self::Str(s) => s.clone(),
        })
    }

    pub(crate) fn as_str(&self) -> Option<&str> {
        match self {
            Self::Str(s) => Some(s),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Scalar, Setting};

    fn parse(json: &str) -> Setting {
        serde_json::from_str(json).expect("valid setting")
    }

    #[test]
    fn renders_bools_the_way_limine_spells_them() {
        assert_eq!(Scalar::Bool(true).value().as_deref(), Some("yes"));
        assert_eq!(Scalar::Bool(false).value().as_deref(), Some("no"));
    }

    #[test]
    fn renders_numbers_and_strings_verbatim() {
        assert_eq!(Scalar::Int(5).value().as_deref(), Some("5"));
        assert_eq!(Scalar::Str("no".to_owned()).value().as_deref(), Some("no"));
    }

    /// A key with no value should not reach limine.conf at all.
    #[test]
    fn drops_nulls() {
        assert_eq!(Scalar::Null.value(), None);
    }

    #[test]
    fn distinguishes_one_value_from_a_list() {
        assert!(matches!(parse("5"), Setting::One(Scalar::Int(5))));
        assert!(matches!(parse("true"), Setting::One(Scalar::Bool(true))));
        assert!(matches!(parse(r#""no""#), Setting::One(Scalar::Str(_))));

        let Setting::Many(values) = parse(r#"["/a.png", "/b.png"]"#) else {
            panic!("expected a list");
        };
        assert_eq!(values.len(), 2);
    }

    /// `timeout` is either a count or the string "no", and both have to survive.
    #[test]
    fn keeps_the_timeout_spellings_apart() {
        assert_eq!(
            parse("5").one().and_then(|value| value.value()).as_deref(),
            Some("5")
        );
        assert_eq!(
            parse(r#""no""#)
                .one()
                .and_then(|value| value.value())
                .as_deref(),
            Some("no")
        );
    }

    impl Setting {
        fn one(self) -> Option<Scalar> {
            match self {
                Self::One(value) => Some(value),
                Self::Many(_) => None,
            }
        }
    }
}
