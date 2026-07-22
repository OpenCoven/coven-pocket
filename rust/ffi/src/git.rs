//! On-device git workspaces backed by libgit2.
//!
//! Repositories live under an app-provided root directory, one folder per
//! workspace. All functions here are blocking; the FFI layer wraps them in
//! `spawn_blocking` so the UI thread never waits on disk or network.
//!
//! Scope matches the roadmap MVP: clone, list, delete, pull (fast-forward
//! only), stage-all commit, push, and branch switching. Anything that needs
//! merge-conflict resolution is deliberately excluded — the app tells the
//! user to resolve on a desktop rather than growing a conflict UI.

use std::path::{Path, PathBuf};

use git2::build::{CheckoutBuilder, RepoBuilder};
use git2::{
    BranchType, Cred, CredentialType, FetchOptions, IndexAddOption, PushOptions, RemoteCallbacks,
    Repository, Signature, StatusOptions,
};

use crate::PocketError;

/// Credentials for remote operations. All fields optional: anonymous HTTPS
/// clones need none, PAT flows fill `username`/`token`, SSH remotes fill the
/// key fields. Secrets stay in the iOS Keychain on the Swift side and only
/// transit here per call.
#[derive(uniffi::Record, Clone, Default)]
pub struct GitCredentials {
    #[uniffi(default = None)]
    pub username: Option<String>,
    /// HTTPS password or personal access token.
    #[uniffi(default = None)]
    pub token: Option<String>,
    /// PEM-encoded private key for SSH remotes.
    #[uniffi(default = None)]
    pub ssh_private_key: Option<String>,
    #[uniffi(default = None)]
    pub ssh_passphrase: Option<String>,
}

/// One cloned repository under the workspaces root.
#[derive(uniffi::Record, Debug)]
pub struct GitWorkspaceSummary {
    pub name: String,
    /// Absolute path — hand this to `start_chat` as the workspace dir.
    pub path: String,
    /// Current branch shorthand, or a short commit id when detached.
    pub branch: String,
    pub remote_url: Option<String>,
    /// Changed paths (worktree + index, untracked included).
    pub dirty_count: u32,
    /// Commits ahead of / behind upstream; zeros when no upstream is set.
    pub ahead: u32,
    pub behind: u32,
}

fn git_err(err: impl std::fmt::Display) -> PocketError {
    PocketError::Engine {
        message: format!("git: {err}"),
    }
}

/// Workspace names become path components; keep them boring so they can
/// never escape the root (no separators, no leading dot, short).
pub(crate) fn validate_workspace_name(name: &str) -> Result<(), PocketError> {
    let ok_chars = name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    if name.is_empty() || name.len() > 64 || !ok_chars || name.starts_with('.') {
        return Err(git_err(format!("invalid workspace name: {name:?}")));
    }
    Ok(())
}

/// Derive a workspace name from a remote URL (`.../coven-pocket.git` →
/// `coven-pocket`), sanitized through the same validation gate.
pub(crate) fn name_from_url(url: &str) -> Result<String, PocketError> {
    let tail = url
        .trim_end_matches('/')
        .rsplit(['/', ':'])
        .next()
        .unwrap_or("");
    let name = tail.trim_end_matches(".git").to_string();
    validate_workspace_name(&name)?;
    Ok(name)
}

fn workspace_path(root: &str, name: &str) -> Result<PathBuf, PocketError> {
    validate_workspace_name(name)?;
    Ok(Path::new(root).join(name))
}

fn open_workspace(root: &str, name: &str) -> Result<Repository, PocketError> {
    let path = workspace_path(root, name)?;
    Repository::open(&path).map_err(git_err)
}

/// Credential callback covering the three flows we support: SSH key from
/// memory, HTTPS user+token, and libgit2's default (credential helpers —
/// effectively nothing on iOS, but harmless).
fn remote_callbacks(creds: &GitCredentials) -> RemoteCallbacks<'_> {
    let mut callbacks = RemoteCallbacks::new();
    callbacks.credentials(move |_url, username_from_url, allowed| {
        if allowed.contains(CredentialType::SSH_KEY) {
            if let Some(key) = creds.ssh_private_key.as_deref() {
                let user = username_from_url.unwrap_or("git");
                return Cred::ssh_key_from_memory(user, None, key, creds.ssh_passphrase.as_deref());
            }
        }
        if allowed.contains(CredentialType::USER_PASS_PLAINTEXT) {
            if let Some(token) = creds.token.as_deref() {
                let user = creds
                    .username
                    .as_deref()
                    .or(username_from_url)
                    .unwrap_or("git");
                return Cred::userpass_plaintext(user, token);
            }
        }
        if allowed.contains(CredentialType::DEFAULT) {
            return Cred::default();
        }
        Err(git2::Error::from_str(
            "remote wants credentials that are not configured",
        ))
    });
    callbacks
}

fn fetch_options(creds: &GitCredentials) -> FetchOptions<'_> {
    let mut options = FetchOptions::new();
    options.remote_callbacks(remote_callbacks(creds));
    options
}

/// Current branch shorthand; falls back to the unborn HEAD target on a fresh
/// repo and to a short commit id when detached.
fn current_branch(repo: &Repository) -> String {
    match repo.head() {
        Ok(head) if head.is_branch() => head.shorthand().unwrap_or("HEAD").to_string(),
        Ok(head) => head
            .target()
            .map(|oid| oid.to_string()[..7].to_string())
            .unwrap_or_else(|| "HEAD".to_string()),
        Err(_) => repo
            .find_reference("HEAD")
            .ok()
            .and_then(|r| r.symbolic_target().ok().flatten().map(|s| s.to_string()))
            .and_then(|t| t.strip_prefix("refs/heads/").map(str::to_string))
            .unwrap_or_else(|| "main".to_string()),
    }
}

fn summarize(repo: &Repository, name: &str) -> GitWorkspaceSummary {
    let branch = current_branch(repo);
    let remote_url = repo
        .find_remote("origin")
        .ok()
        .and_then(|r| r.url().ok().map(str::to_string));
    let dirty_count = repo
        .statuses(Some(
            StatusOptions::new()
                .include_untracked(true)
                .recurse_untracked_dirs(true),
        ))
        .map(|s| s.len() as u32)
        .unwrap_or(0);
    let (ahead, behind) = ahead_behind(repo).unwrap_or((0, 0));
    GitWorkspaceSummary {
        name: name.to_string(),
        path: repo
            .workdir()
            .unwrap_or_else(|| repo.path())
            .display()
            .to_string(),
        branch,
        remote_url,
        dirty_count,
        ahead,
        behind,
    }
}

fn ahead_behind(repo: &Repository) -> Option<(u32, u32)> {
    let head = repo.head().ok()?;
    let local = head.target()?;
    let branch = repo
        .find_branch(head.shorthand().ok()?, BranchType::Local)
        .ok()?;
    let upstream = branch.upstream().ok()?.get().target()?;
    let (a, b) = repo.graph_ahead_behind(local, upstream).ok()?;
    Some((a as u32, b as u32))
}

/// Clone `url` under the root. `name` defaults to the repo name in the URL.
pub(crate) fn clone(
    root: &str,
    url: &str,
    name: Option<String>,
    creds: &GitCredentials,
) -> Result<GitWorkspaceSummary, PocketError> {
    let name = match name {
        Some(n) => {
            validate_workspace_name(&n)?;
            n
        }
        None => name_from_url(url)?,
    };
    let path = workspace_path(root, &name)?;
    if path.exists() {
        return Err(git_err(format!("workspace {name:?} already exists")));
    }
    std::fs::create_dir_all(root).map_err(git_err)?;
    let repo = RepoBuilder::new()
        .fetch_options(fetch_options(creds))
        .clone(url, &path)
        .map_err(|e| {
            // A failed clone leaves a partial directory behind; remove it so
            // a retry with fixed credentials is not blocked by "exists".
            let _ = std::fs::remove_dir_all(&path);
            git_err(e)
        })?;
    Ok(summarize(&repo, &name))
}

/// Every repository directly under the root, sorted by name. Non-repo
/// directories are skipped rather than erroring.
pub(crate) fn list(root: &str) -> Result<Vec<GitWorkspaceSummary>, PocketError> {
    let mut out = Vec::new();
    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
        Err(e) => return Err(git_err(e)),
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if validate_workspace_name(&name).is_err() {
            continue;
        }
        // Only working trees count as workspaces; a stray bare repo has no
        // files for the agent to operate on and cannot be deleted here.
        if let Ok(repo) = Repository::open(entry.path()) {
            if repo.workdir().is_some() {
                out.push(summarize(&repo, &name));
            }
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

pub(crate) fn delete(root: &str, name: &str) -> Result<(), PocketError> {
    let path = workspace_path(root, name)?;
    if !path.join(".git").exists() {
        return Err(git_err(format!("{name:?} is not a git workspace")));
    }
    std::fs::remove_dir_all(&path).map_err(git_err)
}

/// The checked-out branch name. Remote operations build refspecs from it,
/// so a detached HEAD is an explicit error rather than a confusing one
/// downstream.
fn require_branch(repo: &Repository) -> Result<String, PocketError> {
    let head = repo.head().map_err(git_err)?;
    if !head.is_branch() {
        return Err(git_err(
            "HEAD is detached; switch to a branch before syncing",
        ));
    }
    head.shorthand().map(str::to_string).map_err(git_err)
}

/// Fetch origin and fast-forward the current branch. Diverged histories are
/// an error — merge resolution is out of scope on the phone.
pub(crate) fn pull(
    root: &str,
    name: &str,
    creds: &GitCredentials,
) -> Result<GitWorkspaceSummary, PocketError> {
    let repo = open_workspace(root, name)?;
    let branch_name = require_branch(&repo)?;

    let mut remote = repo.find_remote("origin").map_err(git_err)?;
    remote
        .fetch(&[] as &[&str], Some(&mut fetch_options(creds)), None)
        .map_err(git_err)?;

    let upstream = repo
        .find_branch(&branch_name, BranchType::Local)
        .and_then(|b| b.upstream())
        .map_err(|_| {
            git_err(format!(
                "branch {branch_name:?} has no upstream to pull from"
            ))
        })?;
    let target = upstream
        .get()
        .target()
        .ok_or_else(|| git_err("upstream has no target commit"))?;
    let annotated = repo.find_annotated_commit(target).map_err(git_err)?;

    let (analysis, _) = repo.merge_analysis(&[&annotated]).map_err(git_err)?;
    if analysis.is_up_to_date() {
        return Ok(summarize(&repo, name));
    }
    if !analysis.is_fast_forward() {
        return Err(git_err(format!(
            "branch {branch_name:?} has diverged from origin; resolve on a desktop"
        )));
    }
    let refname = format!("refs/heads/{branch_name}");
    repo.find_reference(&refname)
        .and_then(|mut r| r.set_target(target, "pocket: fast-forward pull"))
        .map_err(git_err)?;
    repo.set_head(&refname).map_err(git_err)?;
    repo.checkout_head(Some(CheckoutBuilder::default().force()))
        .map_err(git_err)?;
    Ok(summarize(&repo, name))
}

/// Stage everything (new, modified, deleted) and commit. Returns the short
/// commit id. Empty worktrees are an error so the UI can say "nothing to
/// commit" instead of minting empty commits.
pub(crate) fn commit_all(
    root: &str,
    name: &str,
    message: &str,
    author_name: &str,
    author_email: &str,
) -> Result<String, PocketError> {
    if message.trim().is_empty() {
        return Err(git_err("commit message is empty"));
    }
    let repo = open_workspace(root, name)?;
    let mut index = repo.index().map_err(git_err)?;
    index
        .add_all(["*"].iter(), IndexAddOption::DEFAULT, None)
        .map_err(git_err)?;
    index.update_all(["*"].iter(), None).map_err(git_err)?;
    index.write().map_err(git_err)?;
    let tree_id = index.write_tree().map_err(git_err)?;
    let tree = repo.find_tree(tree_id).map_err(git_err)?;

    let parent = repo.head().ok().and_then(|h| h.peel_to_commit().ok());
    if let Some(parent) = &parent {
        if parent.tree_id() == tree_id {
            return Err(git_err("nothing to commit"));
        }
    }
    let signature = Signature::now(author_name, author_email).map_err(git_err)?;
    let parents: Vec<_> = parent.iter().collect();
    let oid = repo
        .commit(
            Some("HEAD"),
            &signature,
            &signature,
            message,
            &tree,
            &parents,
        )
        .map_err(git_err)?;
    Ok(oid.to_string()[..7].to_string())
}

/// Push the current branch to origin, setting upstream on first push.
pub(crate) fn push(
    root: &str,
    name: &str,
    creds: &GitCredentials,
) -> Result<GitWorkspaceSummary, PocketError> {
    let repo = open_workspace(root, name)?;
    let branch_name = require_branch(&repo)?;
    let mut remote = repo.find_remote("origin").map_err(git_err)?;
    let mut options = PushOptions::new();
    options.remote_callbacks(remote_callbacks(creds));
    let refspec = format!("refs/heads/{branch_name}:refs/heads/{branch_name}");
    remote
        .push(&[&refspec], Some(&mut options))
        .map_err(git_err)?;

    let mut branch = repo
        .find_branch(&branch_name, BranchType::Local)
        .map_err(git_err)?;
    if branch.upstream().is_err() {
        // First push: track origin/<branch> so ahead/behind and pull work.
        branch
            .set_upstream(Some(&format!("origin/{branch_name}")))
            .map_err(git_err)?;
    }
    Ok(summarize(&repo, name))
}

/// Local branch names, current branch first.
pub(crate) fn branches(root: &str, name: &str) -> Result<Vec<String>, PocketError> {
    let repo = open_workspace(root, name)?;
    let current = current_branch(&repo);
    let mut names: Vec<String> = repo
        .branches(Some(BranchType::Local))
        .map_err(git_err)?
        .filter_map(|b| b.ok())
        .filter_map(|(branch, _)| branch.name().ok().flatten().map(str::to_string))
        .collect();
    names.sort();
    if let Some(pos) = names.iter().position(|n| n == &current) {
        names.remove(pos);
        names.insert(0, current);
    }
    Ok(names)
}

/// Switch branches. With `create`, branch off the current HEAD; otherwise
/// the branch must exist locally or as `origin/<branch>` (a local tracking
/// branch is created for the latter). Refuses to switch a dirty worktree.
pub(crate) fn checkout(
    root: &str,
    name: &str,
    branch: &str,
    create: bool,
) -> Result<GitWorkspaceSummary, PocketError> {
    let repo = open_workspace(root, name)?;
    let dirty = repo
        .statuses(Some(StatusOptions::new().include_untracked(false)))
        .map(|s| !s.is_empty())
        .unwrap_or(false);
    if dirty {
        return Err(git_err(
            "worktree has uncommitted changes; commit before switching branches",
        ));
    }

    if create {
        let head = repo
            .head()
            .and_then(|h| h.peel_to_commit())
            .map_err(git_err)?;
        repo.branch(branch, &head, false).map_err(git_err)?;
    } else if repo.find_branch(branch, BranchType::Local).is_err() {
        let remote = repo
            .find_branch(&format!("origin/{branch}"), BranchType::Remote)
            .map_err(|_| git_err(format!("no local or origin branch named {branch:?}")))?;
        let commit = remote.get().peel_to_commit().map_err(git_err)?;
        let mut local = repo.branch(branch, &commit, false).map_err(git_err)?;
        local
            .set_upstream(Some(&format!("origin/{branch}")))
            .map_err(git_err)?;
    }

    let refname = format!("refs/heads/{branch}");
    repo.set_head(&refname).map_err(git_err)?;
    repo.checkout_head(Some(CheckoutBuilder::default().safe()))
        .map_err(git_err)?;
    Ok(summarize(&repo, name))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> String {
        let dir = std::env::temp_dir().join(format!("pocket-git-{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.display().to_string()
    }

    /// A bare "origin" seeded with one commit on main, for file-path clones.
    fn seeded_origin(root: &str) -> String {
        let bare = Path::new(root).join("origin.git");
        let origin = Repository::init_bare(&bare).unwrap();
        origin.set_head("refs/heads/main").unwrap();
        let seed = Path::new(root).join("seed");
        let repo = Repository::init(&seed).unwrap();
        repo.set_head("refs/heads/main").unwrap();
        std::fs::write(seed.join("README.md"), "# seed\n").unwrap();
        let mut index = repo.index().unwrap();
        index
            .add_all(["*"].iter(), IndexAddOption::DEFAULT, None)
            .unwrap();
        index.write().unwrap();
        let tree = repo.find_tree(index.write_tree().unwrap()).unwrap();
        let sig = Signature::now("Seed", "seed@example.com").unwrap();
        repo.commit(Some("HEAD"), &sig, &sig, "seed", &tree, &[])
            .unwrap();
        repo.remote("origin", bare.to_str().unwrap()).unwrap();
        let mut remote = repo.find_remote("origin").unwrap();
        remote
            .push(&["refs/heads/main:refs/heads/main"], None)
            .unwrap();
        bare.display().to_string()
    }

    fn no_creds() -> GitCredentials {
        GitCredentials::default()
    }

    #[test]
    fn workspace_names_are_validated() {
        for bad in ["", ".hidden", "a/b", "a\\b", "..", "x".repeat(65).as_str()] {
            assert!(validate_workspace_name(bad).is_err(), "accepted {bad:?}");
        }
        for good in ["repo", "my-repo_2.0", "A1"] {
            assert!(validate_workspace_name(good).is_ok(), "rejected {good:?}");
        }
    }

    #[test]
    fn names_derive_from_urls() {
        assert_eq!(
            name_from_url("https://github.com/acme/widget.git").unwrap(),
            "widget"
        );
        assert_eq!(
            name_from_url("git@github.com:acme/widget.git").unwrap(),
            "widget"
        );
        assert_eq!(name_from_url("https://host/thing/").unwrap(), "thing");
        assert!(name_from_url("https://").is_err());
    }

    #[test]
    fn clone_list_commit_push_pull_round_trip() {
        let root = temp_root("round");
        let origin = seeded_origin(&root);
        let workspaces = format!("{root}/workspaces");

        // Clone with a derived name ("origin" from origin.git).
        let summary = clone(&workspaces, &origin, Some("wsa".into()), &no_creds()).unwrap();
        assert_eq!(summary.branch, "main");
        assert_eq!(summary.dirty_count, 0);

        // Dirty count reflects new files; commit clears it.
        std::fs::write(Path::new(&summary.path).join("new.txt"), "hi").unwrap();
        let listed = list(&workspaces).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].dirty_count, 1);
        let id = commit_all(&workspaces, "wsa", "add new.txt", "T", "t@example.com").unwrap();
        assert_eq!(id.len(), 7);
        assert!(commit_all(&workspaces, "wsa", "again", "T", "t@example.com").is_err());

        // Push, then a second clone pulls the commit fast-forward.
        let pushed = push(&workspaces, "wsa", &no_creds()).unwrap();
        assert_eq!((pushed.ahead, pushed.behind), (0, 0));
        let second = clone(&workspaces, &origin, Some("wsb".into()), &no_creds()).unwrap();
        assert!(Path::new(&second.path).join("new.txt").exists());

        // Advance origin from wsa; wsb pulls it.
        std::fs::write(Path::new(&summary.path).join("more.txt"), "x").unwrap();
        commit_all(&workspaces, "wsa", "more", "T", "t@example.com").unwrap();
        push(&workspaces, "wsa", &no_creds()).unwrap();
        let pulled = pull(&workspaces, "wsb", &no_creds()).unwrap();
        assert_eq!(pulled.behind, 0);
        assert!(Path::new(&pulled.path).join("more.txt").exists());
    }

    #[test]
    fn pull_refuses_diverged_history() {
        let root = temp_root("diverge");
        let origin = seeded_origin(&root);
        let workspaces = format!("{root}/workspaces");
        clone(&workspaces, &origin, Some("one".into()), &no_creds()).unwrap();
        clone(&workspaces, &origin, Some("two".into()), &no_creds()).unwrap();

        let one = Path::new(&workspaces).join("one");
        let two = Path::new(&workspaces).join("two");
        std::fs::write(one.join("a.txt"), "a").unwrap();
        commit_all(&workspaces, "one", "a", "T", "t@example.com").unwrap();
        push(&workspaces, "one", &no_creds()).unwrap();
        std::fs::write(two.join("b.txt"), "b").unwrap();
        commit_all(&workspaces, "two", "b", "T", "t@example.com").unwrap();

        let err = pull(&workspaces, "two", &no_creds()).unwrap_err();
        assert!(err.to_string().contains("diverged"), "got: {err}");
    }

    #[test]
    fn branches_and_checkout() {
        let root = temp_root("branch");
        let origin = seeded_origin(&root);
        let workspaces = format!("{root}/workspaces");
        clone(&workspaces, &origin, Some("ws".into()), &no_creds()).unwrap();

        let created = checkout(&workspaces, "ws", "feature", true).unwrap();
        assert_eq!(created.branch, "feature");
        let names = branches(&workspaces, "ws").unwrap();
        assert_eq!(names[0], "feature");
        assert!(names.contains(&"main".to_string()));

        // Dirty worktrees refuse to switch.
        let path = Path::new(&workspaces).join("ws");
        std::fs::write(path.join("README.md"), "edited\n").unwrap();
        assert!(checkout(&workspaces, "ws", "main", false).is_err());
        commit_all(&workspaces, "ws", "edit", "T", "t@example.com").unwrap();
        let back = checkout(&workspaces, "ws", "main", false).unwrap();
        assert_eq!(back.branch, "main");

        assert!(checkout(&workspaces, "ws", "missing", false).is_err());
    }

    #[test]
    fn remote_operations_reject_detached_head() {
        let root = temp_root("detached");
        let origin = seeded_origin(&root);
        let workspaces = format!("{root}/workspaces");
        let summary = clone(&workspaces, &origin, Some("ws".into()), &no_creds()).unwrap();

        let repo = Repository::open(&summary.path).unwrap();
        let head = repo.head().unwrap().target().unwrap();
        repo.set_head_detached(head).unwrap();

        for err in [
            pull(&workspaces, "ws", &no_creds()).unwrap_err(),
            push(&workspaces, "ws", &no_creds()).unwrap_err(),
        ] {
            assert!(err.to_string().contains("detached"), "got: {err}");
        }
    }

    #[test]
    fn list_skips_bare_repositories() {
        let root = temp_root("bare");
        let origin = seeded_origin(&root);
        let workspaces = format!("{root}/workspaces");
        clone(&workspaces, &origin, Some("ws".into()), &no_creds()).unwrap();
        Repository::init_bare(Path::new(&workspaces).join("stray")).unwrap();

        let names: Vec<_> = list(&workspaces)
            .unwrap()
            .into_iter()
            .map(|w| w.name)
            .collect();
        assert_eq!(names, vec!["ws".to_string()]);
    }

    #[test]
    fn delete_removes_only_workspaces() {
        let root = temp_root("delete");
        let origin = seeded_origin(&root);
        let workspaces = format!("{root}/workspaces");
        clone(&workspaces, &origin, Some("gone".into()), &no_creds()).unwrap();
        std::fs::create_dir_all(Path::new(&workspaces).join("plain-dir")).unwrap();

        assert!(delete(&workspaces, "plain-dir").is_err());
        delete(&workspaces, "gone").unwrap();
        assert!(!Path::new(&workspaces).join("gone").exists());
        assert!(list(&workspaces).unwrap().is_empty());
    }
}
