//! chy3 — Legacy single-file entry point (re-exports src.main)
//!
//! This file exists for backwards compatibility with the old single-file
//! structure. New code should import from `src.main` directly:
//!
//!   const chy3 = @import("chy3/src/main.zig");
//!
//! or build with the new multi-file layout via `zig build chy3`.

const chy3 = @import("src/main.zig");
pub const main = chy3.main;
