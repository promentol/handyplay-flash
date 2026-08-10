#!/bin/sh
# Build MTASC (the AS2 compiler ruffle's own CONTRIBUTING recommends) from
# source. The 2015 sources need camlp4's stream syntax and Motion-Twin's
# swflib/extc, which live on in HaxeFoundation/ocamllibs.
set -eux
# The 2015 sources predate OCaml's immutable strings. Debian's 4.13 is
# built with -force-safe-string, so the flag that would restore the old
# model is unavailable and the six sites that mutate a string are patched
# to Bytes instead. They are all in extc's zlib wrapper; mtasc and swflib
# themselves need no changes.
cd /build
git clone -q --depth 1 https://github.com/ncannasse/mtasc mtasc
# The TIP of ocamllibs, not a 2015 revision: the old one predates OCaml's
# immutable strings and fights Debian's extlib, while the tip was carried
# forward for both. What the tip costs instead is layout drift, which the
# `ls` guards below absorb.
git clone -q --depth 1 https://github.com/HaxeFoundation/ocamllibs ocamllibs
# MTASC's Makefile expects the tree it was written against: sources beside
# ocaml/{extc,swflib}.
mkdir -p ocaml
cp -r ocamllibs/extc ocaml/extc
cp -r ocamllibs/swflib ocaml/swflib
# `MultiArray` lived inside extlib in 2015 and was dropped from it later;
# Debian's extlib no longer has it, so take that one file from the tip of
# ocamllibs, where it survives as a leftover.
cp -r ocamllibs/extlib-leftovers ocaml/leftovers
cp -r mtasc ocaml/mtasc
cd ocaml/extc
python3 - <<'PATCH'
import re
src = open('extc.ml').read()
# The C stubs take a pointer either way; the OCaml side has to say `bytes`
# for a buffer it writes into.
src = src.replace('dst:string -> dpos:int', 'dst:bytes -> dpos:int')
src = src.replace('let tmp = String.create bufsize', 'let tmp = Bytes.create bufsize')
src = src.replace('let acc = String.sub tmp 0 r.z_wrote :: acc',
                  'let acc = Bytes.sub_string tmp 0 r.z_wrote :: acc')
src = src.replace('let big = String.create !total', 'let big = Bytes.create !total')
src = src.replace('String.unsafe_blit s 0 big p l', 'Bytes.blit_string s 0 big p l')
src = src.replace("""	) !total strings);
	big""", """	) !total strings);
	Bytes.unsafe_to_string big""")
# `input_zip` / `output_zip` are a whole buffered-IO wrapper that nothing
# in mtasc or swflib calls (they want only zip, unzip and
# executable_path), and porting them off mutable strings would be the
# bulk of the work. Cut them.
cut = src.index('let input_zip')
# `SwfParser.init` wants a streaming inflate/deflate pair, and mtasc
# really does use them: it writes a COMPRESSED (CWS) movie for SWF 6 and
# up. The originals are a hand-rolled buffered IO over mutable strings;
# these do the same job by buffering whole and calling zip/unzip once,
# which is fine for files of this size.
src = src[:cut] + '''
let input_zip ?(bufsize=65536) (ch : IO.input) : IO.input =
\tignore bufsize;
\tIO.input_string (unzip (IO.read_all ch))

let output_zip ?(bufsize=65536) ?(level=9) (ch : 'a IO.output) : unit IO.output =
\tignore bufsize; ignore level;
\tlet buf = Buffer.create 65536 in
\tIO.create_out
\t\t~write:(fun c -> Buffer.add_char buf c)
\t\t~output:(fun s p l -> Buffer.add_subbytes buf s p l; l)
\t\t~flush:(fun () -> ())
\t\t~close:(fun () -> ignore (IO.nwrite_string ch (zip (Buffer.contents buf))))
'''
open('extc.ml','w').write(src)
PATCH
ocamlc extc_stubs.c
ocamlfind ocamlopt -package extlib -a -o extc.cmxa -cclib ../extc/extc_stubs.o -cclib -lz $(ls extc.mli 2>/dev/null) extc.ml
cd ../leftovers
# `UTF8` and `UChar` went the same way as MultiArray.
ocamlfind ocamlopt -package extlib -c uChar.mli uChar.ml uTF8.mli uTF8.ml multiArray.mli multiArray.ml
cd ../swflib
# swf.ml refers to As3, so the AS3 modules have to be in the archive even
# though an AS2 compiler never emits them.
ocamlfind ocamlopt -package extlib -a -o swflib.cmxa -I .. -I ../extc -I ../leftovers \
    ../leftovers/multiArray.cmx as3.mli as3code.ml as3parse.ml as3hl.mli as3hlparse.ml png.mli png.ml \
    swf.ml actionScript.ml swfParser.ml
cd ../mtasc
# `SwfZip` was folded into `Swf` upstream; the init call moves with it.
sed -i 's/SwfParser.init SwfZip.inflate SwfZip.deflate/SwfParser.init Extc.input_zip Extc.output_zip/' genSwf.ml
ocamllex lexer.mll
ocamlopt -c expr.ml lexer.ml
ocamlopt -c -pp camlp4o parser.ml
ocamlfind ocamlopt -package extlib -c -I .. -I ../extc -I ../swflib -I ../leftovers typer.ml class.ml plugin.ml genSwf.ml main.ml
ocamlfind ocamlopt -package extlib -linkpkg -o mtasc -cclib -lz extLib.cmxa \
    ../leftovers/uChar.cmx ../leftovers/uTF8.cmx \
    ../extc/extc.cmxa ../swflib/swflib.cmxa \
    expr.cmx lexer.cmx parser.cmx typer.cmx class.cmx plugin.cmx genSwf.cmx main.cmx
install -m755 mtasc /usr/local/bin/mtasc
mkdir -p /usr/local/share/mtasc
cp -r std std8 /usr/local/share/mtasc/
