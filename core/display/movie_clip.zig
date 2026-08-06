//! M2: timeline. Ports Ruffle semantics exactly: run_frame fires Load (first
//! frame, INSTEAD of EnterFrame, before tags); determine_next_frame (Same =>
//! implicit stop, past-end => loop to 1); run_goto rewinds + aggregates
//! per-depth deltas, suppresses DoAction on the replayed target frame.
