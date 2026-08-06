//! M2: scanline rasterizer (ours — Ruffle has no software renderer). Active
//! edge table, quadratic bezier flattening, even-odd + nonzero winding,
//! XRGB8888 target. AA: none in v1; 4x coverage pass in M7.
