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
| 70 | PlaceObject3 | 8 | M1/M7 | parse | filter list DECODED (readable via `MovieClip.filters`) but not applied; ClassName condition inverted (errata) |
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
| 6 | DefineBits | 1 | M1/M4 | done | JPEG needing tag 8 tables; spliced behind them minus EOI/SOI |
| 8 | JPEGTables | 1 | M1/M4 | done | shared encoding tables; one per movie |
| 21 | DefineBitsJPEG2 | 2 | M1/M4 | done | self-contained (v8+ also PNG/GIF — stb sniffs it) |
| 35 | DefineBitsJPEG3 | 3 | M1/M4 | done | + zlib alpha plane; colour is PREMULTIPLIED, each channel clamped to alpha |
| 90 | DefineBitsJPEG4 | 10 | — | oos | deblocking param |
| 20 | DefineBitsLossless | 2 | M1/M4 | done | zlib; colormap rows pad to 4 bytes, PIX15 rows to 2; PIX24 stored ARGB |
| 36 | DefineBitsLossless2 | 3 | M1/M4 | done | + alpha, and the colour is already PREMULTIPLIED by it |
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
| 74 | CsmTextSettings | 8 | M1/M4 | exec | the field's `antiAliasType`/`gridFitType`/thickness/sharpness; the tag may sit on EITHER side of its DefineEditText. The flashtype bit also changes STATIC text's hit test — advanced rendering is hit through the whole box, not glyph by glyph |
| 88 | DefineFontName | 9 | M1 | parse | parse-skip (a display name, not the one lookup uses) |
| 11 | DefineText | 1 | M1/M4 | done | sticky TextRecord state; rendered and hit-tested per glyph |
| 33 | DefineText2 | 3 | M1/M4 | done | RGBA |
| 37 | DefineEditText | 4 | M1/M4 | done | a full instance: spans, HTML, layout, selection, input, two-way `variable` binding. A face the movie does not embed uses the host's TTF when one is registered, and measures zero otherwise |
| 14 | DefineSound | 1 | M1/M6 | parse | PCM/ADPCM/MP3 |
| 46 | DefineMorphShape | 3 | M1/M7 | parse | both style arrays and both edge lists decoded (`swf/morph.zig`); a frame at any ratio is interpolated on demand and HIT-TESTED. Rendering is M7 |
| 84 | DefineMorphShape2 | 8 | M1/M7 | parse | as above, plus edge bounds and the stroke-scaling flags |
| 60/61 | DefineVideoStream/VideoFrame | 6 | — | oos | video. The CONTAINER is not: `core/flv.zig` frames an FLV for `NetStream`, whose script tags reach AVM1 as `onMetaData` |
| 78 | DefineScalingGrid | 8 | — | oos | 9-slice |
| 87 | DefineBinaryData | 9 | — | oos | AVM2 |

## FLV video codecs (M4-L, `core/codecs/`)

`DefineVideoStream` (60) declares the size the frames are STRETCHED into
and the codec; `NetStream` supplies the frames. A video's self-bounds
come from this tag, not from the decoded frame — a component that sizes
itself by dividing by `_width` gets a zero matrix without it.

| codec | name | state |
|---|---|---|
| 2 | Sorenson Spark (H.263) | decodes — I and P frames, Annex J deblocking |
| 3 | Screen video | decodes |
| 4 | VP6 | not implemented |
| 5 | VP6 with alpha | not implemented |
| 6 | Screen video 2 | not implemented |

Sorenson's picture header is H.263's with the GOB number reused as a
version field, a picture size that may be custom in 8 or 16 bits, and a
deblocking flag. Its version 1 also picks the escape-coefficient width
with a flag (7 or 11 bits) where plain H.263 always spends 8.

## PlaceObject3 extras (M4-F)

| field | state |
|---|---|
| `blend_mode` (flag bit 9) | applied — the object is drawn to a layer and the layer composited |
| `cacheAsBitmap` (bit 10) | applied — same layer, origin snapped to a whole pixel |
| filter list (bit 8) | decoded and readable from script; RENDERING is M7 |
| `is_visible` (bit 13) | honoured from SWF 11 |
| `background_color` (bit 14) | parsed, unused |

The blend numbering is Flash's, not HTML5's: 0/1 normal, 2 layer, 3
multiply, 4 screen, 5 lighten, 6 darken, 7 difference, 8 add, 9
subtract, 10 invert, 11 alpha, 12 erase, 13 overlay, 14 hardlight.
`alpha` and `erase` only mean anything against a parent layer — they
change the DESTINATION's alpha and leave its colour alone.
