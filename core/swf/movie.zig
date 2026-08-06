//! M1: SwfMovie — owns the decompressed body for the process lifetime; every
//! other struct stores slices into it. Two-pass preload: definition tags ->
//! display/library.zig dictionary; control tags indexed per frame.
