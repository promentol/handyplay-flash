//! M3: one call frame. Linear interpreter loop over an action slice: decode ->
//! dispatch; If/Jump seek the reader; end-of-slice = implicit return; budget
//! check every 2000 actions. base_clip vs target_clip; slash-path resolver.
