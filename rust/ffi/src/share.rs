//! Redaction pass for shared transcripts.
//!
//! Session transcripts routinely contain pasted keys, tool output that
//! echoes environment variables, and diffs touching credential files. The
//! app refuses to upload a transcript that has not been through
//! [`redact_secrets`]; the pass is deliberately aggressive — for sharing,
//! a false positive costs a `[REDACTED]` marker, a false negative leaks a
//! credential to a public URL.

use std::sync::LazyLock;

use regex::Regex;

/// One redaction rule: what leaked, and how it was matched.
struct Rule {
    label: &'static str,
    pattern: &'static str,
    /// Replacement template (`$1`-style groups keep non-secret context).
    replacement: &'static str,
}

/// Ordered: multiline blocks and context-keeping rules run before the
/// generic assignment catch-all so specific labels win.
const RULES: &[Rule] = &[
    Rule {
        label: "private key block",
        pattern: r"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
        replacement: "[REDACTED:private key]",
    },
    Rule {
        label: "URL credentials",
        pattern: r"://[^/\s:@]+:[^@/\s]+@",
        replacement: "://[REDACTED]@",
    },
    Rule {
        label: "authorization header",
        pattern: r"(?i)\b(authorization\s*:\s*(?:bearer|basic|token)\s+)[^\s]+",
        replacement: "$1[REDACTED]",
    },
    Rule {
        label: "GitHub token",
        pattern: r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})",
        replacement: "[REDACTED:github token]",
    },
    Rule {
        label: "API key",
        pattern: r"\bsk-[A-Za-z0-9_-]{16,}",
        replacement: "[REDACTED:api key]",
    },
    Rule {
        label: "AWS access key",
        pattern: r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
        replacement: "[REDACTED:aws key]",
    },
    Rule {
        label: "Slack token",
        pattern: r"\bxox[baprs]-[A-Za-z0-9-]{10,}",
        replacement: "[REDACTED:slack token]",
    },
    Rule {
        label: "Google API key",
        pattern: r"\bAIza[0-9A-Za-z_-]{35}\b",
        replacement: "[REDACTED:google key]",
    },
    Rule {
        label: "JWT",
        pattern: r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
        replacement: "[REDACTED:jwt]",
    },
    Rule {
        label: "credential assignment",
        pattern: r#"(?i)\b((?:api[_-]?key|access[_-]?key|secret[_-]?key|client[_-]?secret|auth[_-]?token|api[_-]?token|secret|token|password|passwd)\s*[:=]\s*)("[^"]{8,}"|'[^']{8,}'|[A-Za-z0-9_\-./+=]{12,})"#,
        replacement: "$1[REDACTED]",
    },
];

static COMPILED: LazyLock<Result<Vec<(&'static Rule, Regex)>, String>> = LazyLock::new(|| {
    RULES
        .iter()
        .map(|rule| {
            Regex::new(rule.pattern)
                .map(|regex| (rule, regex))
                .map_err(|err| format!("redaction rule '{}' failed to compile: {err}", rule.label))
        })
        .collect()
});

/// What a redaction pass found in one label category.
#[derive(Debug, PartialEq, Eq, uniffi::Record)]
pub struct RedactionFinding {
    pub label: String,
    pub count: u32,
}

/// A transcript scrubbed for sharing, plus what was removed.
#[derive(Debug, uniffi::Record)]
pub struct RedactionResult {
    pub redacted: String,
    pub findings: Vec<RedactionFinding>,
}

/// Scrub `text` of credential-shaped content. Every finding is replaced
/// with a visible `[REDACTED…]` marker so readers know something was cut.
///
/// Errs only if a redaction rule fails to compile — callers must treat
/// that as "do not share", never as "share unredacted".
pub fn redact_secrets(text: &str) -> Result<RedactionResult, String> {
    let rules = COMPILED.as_ref().map_err(Clone::clone)?;
    let mut redacted = text.to_string();
    let mut findings = Vec::new();
    for (rule, regex) in rules {
        // Count within the replacement pass: one scan per rule.
        let mut count: u32 = 0;
        redacted = regex
            .replace_all(&redacted, |caps: &regex::Captures<'_>| {
                count = count.saturating_add(1);
                let mut expanded = String::new();
                caps.expand(rule.replacement, &mut expanded);
                expanded
            })
            .into_owned();
        if count > 0 {
            findings.push(RedactionFinding {
                label: rule.label.to_string(),
                count,
            });
        }
    }
    Ok(RedactionResult { redacted, findings })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn redact(text: &str) -> String {
        redact_secrets(text).unwrap().redacted
    }

    #[test]
    fn github_tokens_are_redacted() {
        let out = redact("push with ghp_abcdefghijklmnopqrstuvwxyz012345 now");
        assert!(!out.contains("ghp_"), "{out}");
        assert!(out.contains("[REDACTED:github token]"));
        let out = redact("github_pat_11ABCDEFG0123456789_abcdefghij");
        assert!(out.contains("[REDACTED:github token]"), "{out}");
    }

    #[test]
    fn api_keys_and_aws_keys_are_redacted() {
        let out = redact("sk-ant-api03-abcdefghijklmnop and AKIAIOSFODNN7EXAMPLE");
        assert!(!out.contains("sk-ant"), "{out}");
        assert!(out.contains("[REDACTED:api key]"));
        assert!(out.contains("[REDACTED:aws key]"));
    }

    #[test]
    fn pem_blocks_are_redacted_across_lines() {
        let text = "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIabc\ndef==\n-----END RSA PRIVATE KEY-----\nafter";
        let out = redact(text);
        assert!(!out.contains("MIIabc"), "{out}");
        assert!(out.contains("[REDACTED:private key]"));
        assert!(out.starts_with("before\n") && out.ends_with("\nafter"));
    }

    #[test]
    fn url_credentials_keep_the_rest_of_the_url() {
        let out = redact("cloning https://buns:s3cretpass@github.com/o/r.git");
        assert_eq!(out, "cloning https://[REDACTED]@github.com/o/r.git");
    }

    #[test]
    fn authorization_headers_keep_the_header_name() {
        let out = redact("Authorization: Bearer abc.def.longtokenvalue");
        assert!(out.starts_with("Authorization: Bearer [REDACTED]"), "{out}");
    }

    #[test]
    fn credential_assignments_keep_key_and_separator() {
        let out = redact(r#"export API_KEY="super-secret-value-123""#);
        assert!(out.contains("API_KEY="), "{out}");
        assert!(!out.contains("super-secret"), "{out}");
        let out = redact("password: hunter2hunter2hunter2");
        assert!(out.contains("password: [REDACTED]"), "{out}");
    }

    #[test]
    fn jwts_and_vendor_tokens_are_redacted() {
        let out = redact(
            "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dozjgNryP4J3jVmNHl0w5N65OTAslack \
             xoxb-123456789012-abcdefghij AIzaSyA1234567890abcdefghijklmnopqrstuv",
        );
        assert!(out.contains("[REDACTED:jwt]"), "{out}");
        assert!(out.contains("[REDACTED:slack token]"), "{out}");
        assert!(out.contains("[REDACTED:google key]"), "{out}");
    }

    #[test]
    fn benign_prose_and_code_are_untouched() {
        let text = "The tokenizer splits text; call parse_token(input) and \
                    check `let token = next_token(lexer);` for details. \
                    Passwords should rotate every 90 days.";
        let out = redact_secrets(text).unwrap();
        assert_eq!(out.redacted, text);
        assert!(out.findings.is_empty());
    }

    #[test]
    fn findings_carry_labels_and_counts() {
        let result = redact_secrets(
            "ghp_abcdefghijklmnopqrstuvwxyz012345 and ghp_zyxwvutsrqponmlkjihgfedcba543210",
        )
        .unwrap();
        assert_eq!(
            result.findings,
            vec![RedactionFinding {
                label: "GitHub token".into(),
                count: 2
            }]
        );
    }

    #[test]
    fn every_rule_compiles() {
        assert!(COMPILED.as_ref().is_ok(), "{:?}", COMPILED.as_ref().err());
    }
}
