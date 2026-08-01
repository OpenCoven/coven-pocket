#[cfg(test)]
mod tests {
    use super::*;
    use claurst_core::{Goal, GoalStatus};

    fn engine_goal(
        status: GoalStatus,
        turns_used: u32,
        tokens_used: u64,
        token_budget: Option<u64>,
    ) -> Goal {
        Goal {
            id: "goal".to_string(),
            session_id: "session".to_string(),
            objective: "finish".to_string(),
            status,
            token_budget,
            tokens_used,
            time_used_secs: 12,
            turns_used,
            created_at_ms: 1,
            updated_at_ms: 2,
        }
    }

    fn test_goal_storage(label: &str) -> GoalStorage {
        let path = std::env::current_dir()
            .unwrap()
            .join("target")
            .join(format!(
                "coven-pocket-goals-{label}-{}",
                uuid::Uuid::new_v4()
            ));
        std::fs::create_dir_all(&path).unwrap();
        GoalStorage::open(&path.to_string_lossy()).unwrap()
    }

    #[test]
    fn snapshot_preserves_engine_goal_fields() {
        let goal = engine_goal(GoalStatus::Active, 4, 900, Some(1_000));
        let snapshot = GoalSnapshot::from(goal);
        assert_eq!(snapshot.status, PocketGoalStatus::Active);
        assert_eq!(snapshot.turns_used, 4);
        assert_eq!(snapshot.tokens_used, 900);
        assert_eq!(snapshot.token_budget, Some(1_000));
    }

    #[test]
    fn resume_rejects_terminal_and_runaway_goals() {
        assert!(
            validate_resume(&engine_goal(GoalStatus::BudgetLimited, 2, 100, Some(100))).is_err()
        );
        assert!(validate_resume(&engine_goal(
            GoalStatus::Paused,
            claurst_core::MAX_GOAL_TURNS,
            100,
            None,
        ))
        .is_err());
    }

    #[tokio::test]
    async fn resume_durably_reactivates_a_paused_goal() {
        let storage = test_goal_storage("resume");
        storage
            .with_store(|store| {
                store.set_goal("session", "finish", None)?;
                store.pause_active_goal("session")
            })
            .unwrap();

        let snapshot = resume(storage, "session".to_string()).await.unwrap();
        assert_eq!(snapshot.status, PocketGoalStatus::Active);
    }

    #[tokio::test]
    async fn reconcile_pauses_every_interrupted_active_goal() {
        let storage = test_goal_storage("reconcile");
        storage
            .with_store(|store| {
                store.set_goal("first", "one", None)?;
                store.set_goal("second", "two", None)?;
                Ok(())
            })
            .unwrap();

        let snapshots = reconcile(storage).await.unwrap();
        assert_eq!(snapshots.len(), 2);
        assert!(snapshots
            .iter()
            .all(|snapshot| snapshot.status == PocketGoalStatus::Paused));
    }
}
use claurst_core::{Goal, GoalError, GoalStatus};

use crate::sessions::GoalStorage;
use crate::{run_blocking, PocketError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PocketGoalStatus {
    Active,
    Paused,
    BudgetLimited,
    Complete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum GoalRunStopReason {
    Complete,
    Paused,
    BudgetLimited,
    RunawayGuard,
    Cleared,
    Cancelled,
    RuntimeError,
    StorageError,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct GoalSnapshot {
    pub goal_id: String,
    pub session_id: String,
    pub objective: String,
    pub status: PocketGoalStatus,
    pub token_budget: Option<u64>,
    pub tokens_used: u64,
    pub elapsed_seconds: u64,
    pub turns_used: u32,
    pub max_turns: u32,
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct GoalRunResult {
    pub reason: GoalRunStopReason,
    pub snapshot: Option<GoalSnapshot>,
    pub error_message: Option<String>,
}

#[uniffi::export(with_foreign)]
pub trait GoalProgressDelegate: Send + Sync {
    fn on_goal_snapshot(&self, snapshot: GoalSnapshot);
}

impl From<Goal> for GoalSnapshot {
    fn from(goal: Goal) -> Self {
        Self {
            goal_id: goal.id,
            session_id: goal.session_id,
            objective: goal.objective,
            status: match goal.status {
                GoalStatus::Active => PocketGoalStatus::Active,
                GoalStatus::Paused => PocketGoalStatus::Paused,
                GoalStatus::BudgetLimited => PocketGoalStatus::BudgetLimited,
                GoalStatus::Complete => PocketGoalStatus::Complete,
            },
            token_budget: goal.token_budget,
            tokens_used: goal.tokens_used,
            elapsed_seconds: goal.time_used_secs,
            turns_used: goal.turns_used,
            max_turns: claurst_core::MAX_GOAL_TURNS,
            updated_at_ms: goal.updated_at_ms,
        }
    }
}

fn goal_error(context: &str, error: GoalError) -> PocketError {
    PocketError::Engine {
        message: format!("{context}: {error}"),
    }
}

fn validate_resume(goal: &Goal) -> Result<(), PocketError> {
    if goal.status != GoalStatus::Paused {
        return Err(PocketError::Engine {
            message: "only a paused goal can resume".to_string(),
        });
    }
    if goal.turns_used >= claurst_core::MAX_GOAL_TURNS {
        return Err(PocketError::Engine {
            message: "goal reached the automatic turn limit".to_string(),
        });
    }
    Ok(())
}

pub(crate) async fn load(
    storage: GoalStorage,
    session_id: String,
) -> Result<Option<GoalSnapshot>, PocketError> {
    run_blocking(move || {
        storage
            .with_store(|store| store.try_get_goal(&session_id))
            .map(|goal| goal.map(GoalSnapshot::from))
    })
    .await
}

pub(crate) async fn create(
    storage: GoalStorage,
    session_id: String,
    objective: String,
    token_budget: Option<u64>,
) -> Result<GoalSnapshot, PocketError> {
    if objective.trim().is_empty() {
        return Err(PocketError::Engine {
            message: "goal objective cannot be empty".to_string(),
        });
    }
    if token_budget == Some(0) {
        return Err(PocketError::Engine {
            message: "goal token budget must be greater than zero".to_string(),
        });
    }
    run_blocking(move || {
        storage
            .with_store(|store| store.set_goal(&session_id, &objective, token_budget))
            .map(GoalSnapshot::from)
    })
    .await
}

pub(crate) async fn pause(
    storage: GoalStorage,
    session_id: String,
) -> Result<GoalSnapshot, PocketError> {
    run_blocking(move || {
        storage
            .with_store(|store| {
                store.pause_active_goal(&session_id)?;
                store
                    .try_get_goal(&session_id)?
                    .ok_or(GoalError::NotFound { session_id })
            })
            .map(GoalSnapshot::from)
    })
    .await
}

/// Pause only the goal which was running when the caller began its turn.
/// `None` means that goal was removed or replaced while the turn was in
/// flight; the caller must not mutate the replacement.
pub(crate) async fn pause_owned(
    storage: GoalStorage,
    session_id: String,
    expected_goal_id: String,
) -> Result<Option<GoalSnapshot>, PocketError> {
    run_blocking(move || {
        storage.with_store(|store| {
            match store.pause_active_goal_for_goal(&session_id, &expected_goal_id) {
                Ok(()) => Ok(Some(
                    store
                        .try_get_goal(&session_id)?
                        .map(GoalSnapshot::from)
                        .ok_or(GoalError::NotFound { session_id })?,
                )),
                Err(GoalError::NotFound { .. } | GoalError::Replaced { .. }) => Ok(None),
                Err(error) => Err(error),
            }
        })
    })
    .await
}

pub(crate) async fn resume(
    storage: GoalStorage,
    session_id: String,
) -> Result<GoalSnapshot, PocketError> {
    let current = {
        let storage = storage.clone();
        let session_id = session_id.clone();
        run_blocking(move || {
            storage.with_store(|store| {
                store
                    .try_get_goal(&session_id)?
                    .ok_or(GoalError::NotFound { session_id })
            })
        })
        .await?
    };
    validate_resume(&current)?;
    run_blocking(move || {
        storage
            .with_store(|store| {
                store.resume_paused_goal(&session_id)?;
                store
                    .try_get_goal(&session_id)?
                    .ok_or(GoalError::NotFound { session_id })
            })
            .map(GoalSnapshot::from)
    })
    .await
}

pub(crate) async fn clear(storage: GoalStorage, session_id: String) -> Result<(), PocketError> {
    run_blocking(move || storage.with_store(|store| store.clear_goal(&session_id))).await
}

pub(crate) async fn required_snapshot(
    storage: GoalStorage,
    session_id: String,
) -> Result<GoalSnapshot, PocketError> {
    load(storage, session_id)
        .await?
        .ok_or_else(|| PocketError::Engine {
            message: "goal disappeared while it was running".to_string(),
        })
}

pub(crate) fn run_result(
    reason: claurst_query::StopReason,
    snapshot: Option<GoalSnapshot>,
) -> GoalRunResult {
    let reason = match reason {
        claurst_query::StopReason::GoalComplete => GoalRunStopReason::Complete,
        claurst_query::StopReason::Paused => GoalRunStopReason::Paused,
        claurst_query::StopReason::BudgetLimited => GoalRunStopReason::BudgetLimited,
        claurst_query::StopReason::RunawayGuard { .. } => GoalRunStopReason::RunawayGuard,
        claurst_query::StopReason::Error(_) => GoalRunStopReason::RuntimeError,
    };
    GoalRunResult {
        reason,
        snapshot,
        error_message: None,
    }
}

pub(crate) async fn reconcile(storage: GoalStorage) -> Result<Vec<GoalSnapshot>, PocketError> {
    run_blocking(move || storage.with_store(|store| store.pause_active_goals()))
        .await
        .map(|goals| goals.into_iter().map(GoalSnapshot::from).collect())
}

pub(crate) async fn continue_after_turn(
    storage: GoalStorage,
    session_id: String,
    expected_goal_id: String,
    total_tokens_used: u64,
    elapsed_seconds: u64,
) -> Result<claurst_query::GoalContinuation, PocketError> {
    run_blocking(move || {
        storage.validate()?;
        let path = storage.path()?;
        let result = claurst_query::check_and_continue_goal_at_path_for_goal(
            &path,
            &session_id,
            &expected_goal_id,
            total_tokens_used,
            elapsed_seconds,
        );
        storage.validate()?;
        match result {
            Ok(continuation) => Ok(continuation),
            Err(GoalError::NotFound { .. } | GoalError::Replaced { .. }) => {
                Ok(claurst_query::GoalContinuation::NoGoal)
            }
            Err(error) => Err(goal_error("goal continuation failed", error)),
        }
    })
    .await
}
