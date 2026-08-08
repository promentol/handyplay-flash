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
| 0 | End | 1 | M1 | parse | terminates tag stream |
| 1 | ShowFrame | 1 | M1/M2 | parse | frame boundary |
| 4 | PlaceObject | 1 | M1/M2 | parse | positional only |
| 26 | PlaceObject2 | 3 | M1/M2 | parse | **the workhorse**: move/character/matrix/cxform/ratio/name/clipDepth/ClipActions |
| 70 | PlaceObject3 | 8 | M1/M7 | parse | filters oos initially; ClassName condition inverted (errata) |
| 5 | RemoveObject | 1 | M1/M2 | parse | id + depth |
| 28 | RemoveObject2 | 3 | M1/M2 | parse | depth only |
| 9 | SetBackgroundColor | 1 | M1/M2 | parse | |
| 12 | DoAction | 3 | M1/M3 | parse | queued, not inline |
| 59 | DoInitAction | 6 | M1/M4 | exec | runs ONCE at PRELOAD, before frame 1 — not on the timeline (ruffle handles it in `preload`), which is what lets an `#initclip` register a class for PlaceObject tags EARLIER in the same frame |
| 43 | FrameLabel | 3 | M1 | parse | v6+ anchor byte |
| 15 | StartSound | 1 | M1/M6 | parse | |
| 89 | StartSound2 | 9 | — | oos | class-name sounds (AVM2-era) |
| 18 | SoundStreamHead | 1 | M1/M6 | parse | |
| 45 | SoundStreamHead2 | 3 | M1/M6 | parse | |
| 19 | SoundStreamBlock | 1 | M1/M6 | parse | frame-synced audio |
| 56 | ExportAssets | 5 | M1/M4 | parse | name → id (attachMovie) |
| 57 | ImportAssets | 5 | — | oos | multi-movie |
| 71 | ImportAssets2 | 8 | — | oos | |
| 24 | Protect | 2 | M1 | parse | skip (2 undocumented bytes before MD5) |
| 65 | ScriptLimits | 7 | M1/M3 | parse | recursion + timeout |
| 69 | FileAttributes | 8 | M1/M4 | exec | **AS3 bit ⇒ reject**; UseNetwork picks `System.security.sandboxType` |
| 77 | Metadata | 8 | M1 | parse | skip |
| 86 | DefineSceneAndFrameLabelData | 9 | — | oos | AVM2 |
| 40/41/63 | NameCharacter/ProductInfo/DebugId | — | M1 | parse | undocumented; skip by length |

## Definition tags

| Code | Tag | SWF | Milestone | Status | Notes |
|---:|---|---:|---|---|---|
| 2 | DefineShape | 1 | M1/M2 | parse | |
| 22 | DefineShape2 | 2 | M1/M2 | parse | >255 styles |
| 32 | DefineShape3 | 3 | M1/M2 | parse | RGBA |
| 83 | DefineShape4 | 8 | M1/M2 | parse | line caps/joins, focal gradients, winding bit |
| 39 | DefineSprite | 3 | M1/M2 | parse | nested tag stream — recurse preload |
| 6 | DefineBits | 1 | M1/M4 | parse | JPEG needing tag 8 tables |
| 8 | JPEGTables | 1 | M1/M4 | parse | shared encoding tables |
| 21 | DefineBitsJPEG2 | 2 | M1/M4 | parse | self-contained (v8+ also PNG/GIF) |
| 35 | DefineBitsJPEG3 | 3 | M1/M4 | parse | + zlib alpha plane |
| 90 | DefineBitsJPEG4 | 10 | — | oos | deblocking param |
| 20 | DefineBitsLossless | 2 | M1/M4 | parse | zlib; colormap/PIX15/PIX24 |
| 36 | DefineBitsLossless2 | 3 | M1/M4 | parse | + alpha |
| 7 | DefineButton | 1 | M1/M4 | done | instantiated as a CONTAINER (display/button.zig): state children + a separate hit-area list |
| 34 | DefineButton2 | 3 | M1/M4 | done | ButtonCondAction dispatch, incl. keyPress; the actions run on the button's PARENT timeline |
| 23 | DefineButtonCxform | 2 | M1/M4 | parse | decoder in button.zig; preload wiring still open; may hold MULTIPLE cxforms (errata) |
| 17 | DefineButtonSound | 2 | M6 | todo | decoder with sound work |
| 10 | DefineFont | 1 | M1/M4 | done | glyph shapes only; its NAME and style come from the DefineFontInfo beside it |
| 48 | DefineFont2 | 3 | M1/M4 | done | layout/kerning/wide codes; resolved by NAME + bold/italic |
| 75 | DefineFont3 | 8 | M1/M4 | done | 20× glyph resolution (/20480) |
| 91 | DefineFont4 | 10 | — | oos | CFF |
| 13 | DefineFontInfo | 1 | M1/M4 | done | glyph→codepoint map, plus the face name/bold/italic a DefineFont1 has nowhere else |
| 62 | DefineFontInfo2 | 6 | M1/M4 | done | |
| 73 | FontAlignZones | 8 | M1 | parse | parse-skip |
| 74 | CsmTextSettings | 8 | M1/M4 | exec | the field's `antiAliasType`/`gridFitType`/thickness/sharpness; the tag may sit on EITHER side of its DefineEditText |
| 88 | DefineFontName | 9 | M1 | parse | parse-skip (a display name, not the one lookup uses) |
| 11 | DefineText | 1 | M1/M4 | done | sticky TextRecord state; rendered and hit-tested per glyph |
| 33 | DefineText2 | 3 | M1/M4 | done | RGBA |
| 37 | DefineEditText | 4 | M1/M4 | done | a full instance: spans, HTML, layout, selection, input, two-way `variable` binding. Device fonts (a face the movie does not embed) still resolve to nothing — M7 |
| 14 | DefineSound | 1 | M1/M6 | parse | PCM/ADPCM/MP3 |
| 46 | DefineMorphShape | 3 | M7 | todo | raw body captured by preload |
| 84 | DefineMorphShape2 | 8 | M7 | todo | raw body captured by preload |
| 60/61 | DefineVideoStream/VideoFrame | 6 | — | oos | video |
| 78 | DefineScalingGrid | 8 | — | oos | 9-slice |
| 87 | DefineBinaryData | 9 | — | oos | AVM2 |
