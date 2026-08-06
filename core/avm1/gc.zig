//! M3: object table + mark-sweep (ADR D2). Objects are u32 handles into a slot
//! table; roots = stack/scopes/registers/constant pools/display list/globals.
//! Save-state = table walk (stable ids), like exen-core.
