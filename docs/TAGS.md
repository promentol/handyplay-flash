# SWF tag coverage matrix

Status: `todo` → `parse` (decoded to structs) → `exec` (wired into
timeline/library) → `done` (rendered/played + corpus-verified) · `oos` = out of
scope. Update this file at the end of every milestone — it is the public
progress report.

Scope: AVM1-era content, SWF v4–v8. `FileAttributes.ActionScript3` ⇒ the file
is rejected (`error.Avm2Unsupported`).

## Control tags

| Code | Tag | SWF | Milestone | Status | Notes |
|---:|---|---:|---|---|---|
| 0 | End | 1 | M1 | todo | terminates tag stream |
| 1 | ShowFrame | 1 | M1/M2 | todo | frame boundary |
| 4 | PlaceObject | 1 | M1/M2 | todo | positional only |
| 26 | PlaceObject2 | 3 | M1/M2 | todo | **the workhorse**: move/character/matrix/cxform/ratio/name/clipDepth/ClipActions |
| 70 | PlaceObject3 | 8 | M1/M7 | todo | filters oos initially; ClassName condition inverted (errata) |
| 5 | RemoveObject | 1 | M1/M2 | todo | id + depth |
| 28 | RemoveObject2 | 3 | M1/M2 | todo | depth only |
| 9 | SetBackgroundColor | 1 | M1/M2 | todo | |
| 12 | DoAction | 3 | M1/M3 | todo | queued, not inline |
| 59 | DoInitAction | 6 | M1/M4 | todo | once, Initialize priority |
| 43 | FrameLabel | 3 | M1 | todo | v6+ anchor byte |
| 15 | StartSound | 1 | M1/M6 | todo | |
| 89 | StartSound2 | 9 | — | oos | class-name sounds (AVM2-era) |
| 18 | SoundStreamHead | 1 | M1/M6 | todo | |
| 45 | SoundStreamHead2 | 3 | M1/M6 | todo | |
| 19 | SoundStreamBlock | 1 | M1/M6 | todo | frame-synced audio |
| 56 | ExportAssets | 5 | M1/M4 | todo | name → id (attachMovie) |
| 57 | ImportAssets | 5 | — | oos | multi-movie |
| 71 | ImportAssets2 | 8 | — | oos | |
| 24 | Protect | 2 | M1 | todo | skip (2 undocumented bytes before MD5) |
| 65 | ScriptLimits | 7 | M1/M3 | todo | recursion + timeout |
| 69 | FileAttributes | 8 | M1 | todo | **AS3 bit ⇒ reject** |
| 77 | Metadata | 8 | M1 | todo | skip |
| 86 | DefineSceneAndFrameLabelData | 9 | — | oos | AVM2 |
| 40/41/63 | NameCharacter/ProductInfo/DebugId | — | M1 | todo | undocumented; skip by length |

## Definition tags

| Code | Tag | SWF | Milestone | Status | Notes |
|---:|---|---:|---|---|---|
| 2 | DefineShape | 1 | M1/M2 | todo | |
| 22 | DefineShape2 | 2 | M1/M2 | todo | >255 styles |
| 32 | DefineShape3 | 3 | M1/M2 | todo | RGBA |
| 83 | DefineShape4 | 8 | M1/M2 | todo | line caps/joins, focal gradients, winding bit |
| 39 | DefineSprite | 3 | M1/M2 | todo | nested tag stream — recurse preload |
| 6 | DefineBits | 1 | M1/M4 | todo | JPEG needing tag 8 tables |
| 8 | JPEGTables | 1 | M1/M4 | todo | shared encoding tables |
| 21 | DefineBitsJPEG2 | 2 | M1/M4 | todo | self-contained (v8+ also PNG/GIF) |
| 35 | DefineBitsJPEG3 | 3 | M1/M4 | todo | + zlib alpha plane |
| 90 | DefineBitsJPEG4 | 10 | — | oos | deblocking param |
| 20 | DefineBitsLossless | 2 | M1/M4 | todo | zlib; colormap/PIX15/PIX24 |
| 36 | DefineBitsLossless2 | 3 | M1/M4 | todo | + alpha |
| 7 | DefineButton | 1 | M1/M4 | todo | |
| 34 | DefineButton2 | 3 | M1/M4 | todo | ButtonCondAction |
| 23 | DefineButtonCxform | 2 | M1/M4 | todo | may hold MULTIPLE cxforms (errata) |
| 17 | DefineButtonSound | 2 | M1/M6 | todo | |
| 10 | DefineFont | 1 | M1/M4 | todo | glyph shapes only |
| 48 | DefineFont2 | 3 | M1/M4 | todo | layout/kerning/wide codes |
| 75 | DefineFont3 | 8 | M1/M4 | todo | 20× glyph resolution (/20480) |
| 91 | DefineFont4 | 10 | — | oos | CFF |
| 13 | DefineFontInfo | 1 | M1/M4 | todo | glyph→codepoint map |
| 62 | DefineFontInfo2 | 6 | M1/M4 | todo | |
| 73/74/88 | FontAlignZones/CsmTextSettings/DefineFontName | 8+ | M1 | todo | parse-skip |
| 11 | DefineText | 1 | M1/M4 | todo | sticky TextRecord state |
| 33 | DefineText2 | 3 | M1/M4 | todo | RGBA |
| 37 | DefineEditText | 4 | M1/M7 | todo | `variable` binds to AVM1 var |
| 14 | DefineSound | 1 | M1/M6 | todo | PCM/ADPCM/MP3 |
| 46 | DefineMorphShape | 3 | M7 | todo | |
| 84 | DefineMorphShape2 | 8 | M7 | todo | |
| 60/61 | DefineVideoStream/VideoFrame | 6 | — | oos | video |
| 78 | DefineScalingGrid | 8 | — | oos | 9-slice |
| 87 | DefineBinaryData | 9 | — | oos | AVM2 |
