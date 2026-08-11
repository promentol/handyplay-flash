// 2048, laid out landscape for a handheld — 640x480, the panel in the
// RG35XX / RG40XX / RG28XX / RG353 / RG405M line.
//
// There is not one shape, bitmap or font in the SWF: the board, the
// tiles and the chrome are all drawing-API calls, and every glyph is a
// dynamic text field in the device font. That is on purpose — mtasc
// compiles code and nothing else, so a movie it builds from scratch has
// no library to attach from, and this is what AS2 can do unaided.
//
// The model is sixteen cells holding tile OBJECTS rather than numbers,
// because the animation needs identity: a tile that slides three cells
// and a tile that merges into it are different things on screen, and
// only a reference tells them apart once the values are equal.
//
// WHY THE KEYS ARE WRITTEN AS BARE NUMBERS, and why there is no WASD:
// the libretro core SURVEYS this bytecode for the key codes a movie
// reads and binds the RetroPad to what it finds (core/key_survey.zig).
// Only a literal argument to `Key.isDown` is legible to that walk — a
// code fetched from an array reads as a remappable scheme and the pad
// falls back to a guess — and the set below is chosen so every button
// lands somewhere sensible:
//
//   37/38/39/40  the D-pad, verbatim
//   90  'Z'      first candidate for `action_a`      -> A  = undo
//   32  Space    first candidate the `select` role
//                finds once 13 is absent             -> B  = restart
//   82  'R'      claimed by no role, so it falls to
//                the first spare button              -> L2 = restart
//
// and, as much to the point, what is NOT read: nothing from the `pause`
// list (P, Esc, 19, 13), so START keeps opening the frontend's own menu
// instead of reaching the game, and no 'W', which is a `soft_right`
// candidate and would quietly turn the R shoulder into a second Up.
//
// Compiled with tools/as2 (mtasc), rendered by handyplay-flash.
class Test {
	// --- layout, in pixels -------------------------------------------------
	// The board is a square as tall as the panel allows; the HUD takes the
	// column landscape leaves over. Everything below is derived, so
	// retargeting to another handheld is these two numbers and the
	// -header the compiler is given.
	static var W:Number = 640;
	static var H:Number = 480;
	static var N:Number = 4;
	static var GAP:Number = 10;
	static var TILE:Number = 98;
	static var BOARD:Number = 442;           // N*TILE + (N+1)*GAP
	static var BY:Number = 19;               // (H - BOARD) / 2
	static var BX:Number = 182;              // W - 16 - BOARD
	static var HX:Number = 16;               // HUD column
	static var HW:Number = 150;              // BX - 2*16

	// --- palette (the original's, which is why it looks like it) -----------
	static var BG:Number = 0xFAF8EF;
	static var BOARD_BG:Number = 0xBBADA0;
	static var CELL:Number = 0xCDC1B4;
	static var DARK:Number = 0x776E65;
	static var LIGHT:Number = 0xF9F6F2;
	static var MUTED:Number = 0x9A8F84;
	static var COLOURS:Array = [0xEEE4DA, 0xEDE0C8, 0xF2B179, 0xF59563,
	                            0xF67C5F, 0xF65E3B, 0xEDCF72, 0xEDCC61,
	                            0xEDC850, 0xEDC53F, 0xEDC22E];
	static var HUGE_COLOUR:Number = 0x3C3A32; // 4096 and beyond

	// --- animation and feel, in frames (the movie runs at 60) --------------
	static var SLIDE:Number = 7;
	static var POP:Number = 8;
	static var GROW:Number = 8;
	// Held-direction repeat. The first move is on the press; the pause
	// before the second is what stops a D-pad tap from spending two.
	static var HOLD_FIRST:Number = 16;
	static var HOLD_NEXT:Number = 7;
	static var SAY_FOR:Number = 150;         // how long a message stays up
	static var ARM_FOR:Number = 120;         // how long "press again" waits

	// --- state -------------------------------------------------------------
	static var cells:Array;          // N*N entries, a tile object or null
	static var moving:Array;         // tiles taking part in the current slide
	static var nextCells:Array;      // where the slide lands
	static var gain:Number;          // score the slide is about to award
	static var score:Number;
	static var best:Number = 0;
	static var sliding:Boolean;
	static var anim:Number;
	static var queued:Number;        // one buffered direction, -1 for none
	static var seq:Number = 0;       // tile depth counter, never reused
	static var over:Boolean;
	static var won:Boolean;

	// One step of undo: the sixteen values and the score, taken the moment
	// before a move is applied.
	static var undoVals:Array;
	static var undoScore:Number;
	static var canUndo:Boolean;

	static var down:Array;           // this frame's pad state
	static var hold:Array;           // frames each key has been held
	static var latch:Array;          // a press the listener saw this frame
	static var keys:Object;          // the listener itself, kept from the GC
	static var armed:Number;         // restart asked for, awaiting the second press
	static var sayT:Number;          // frames left on the current message

	// The title card. The board is dealt behind it and frozen, so the
	// opening two tiles pop in the moment it clears rather than being
	// already there.
	static var intro:Boolean;
	static var introT:Number;

	static var tiles:MovieClip;
	static var veil:MovieClip;
	static var introClip:MovieClip;
	static var scoreFld:TextField;
	static var bestFld:TextField;
	static var promptFld:TextField;
	static var msgFld:TextField;
	static var dragX:Number;
	static var dragY:Number;
	static var dragging:Boolean;

	// --- drawing helpers ---------------------------------------------------

	// A rounded rectangle. The corner control point sits ON the corner,
	// which over a quarter turn is a hair inside a true arc and closer
	// than the antialiasing can show.
	static function roundRect(mc:MovieClip, x:Number, y:Number,
	                          w:Number, h:Number, r:Number):Void {
		mc.moveTo(x + r, y);
		mc.lineTo(x + w - r, y);
		mc.curveTo(x + w, y, x + w, y + r);
		mc.lineTo(x + w, y + h - r);
		mc.curveTo(x + w, y + h, x + w - r, y + h);
		mc.lineTo(x + r, y + h);
		mc.curveTo(x, y + h, x, y + h - r);
		mc.lineTo(x, y + r);
		mc.curveTo(x, y, x + r, y);
	}

	static function fillRound(mc:MovieClip, x:Number, y:Number,
	                          w:Number, h:Number, r:Number,
	                          colour:Number, alpha:Number):Void {
		mc.beginFill(colour, alpha);
		roundRect(mc, x, y, w, h, r);
		mc.endFill();
	}

	// Text is re-formatted on every change: assigning `.text` drops the
	// field back to its default format, so the TextFormat has to follow
	// the string every single time.
	static function style(tf:TextField, txt:String, size:Number,
	                      colour:Number, bold:Boolean, align:String):Void {
		tf.text = txt;
		var fmt:TextFormat = new TextFormat();
		fmt.font = "_sans";
		fmt.size = size;
		fmt.color = colour;
		fmt.bold = bold;
		fmt.align = align;
		tf.setTextFormat(fmt);
	}

	static function label(parent:MovieClip, name:String, depth:Number,
	                      x:Number, y:Number, w:Number, h:Number,
	                      txt:String, size:Number, colour:Number,
	                      bold:Boolean, align:String):TextField {
		// mtasc's headers say createTextField returns Void — true before
		// Flash 8 — so the field is picked up by name afterwards.
		parent.createTextField(name, depth, x, y, w, h);
		var tf:TextField = parent[name];
		tf.selectable = false;
		style(tf, txt, size, colour, bold, align);
		return tf;
	}

	// --- geometry ----------------------------------------------------------

	// Tiles are registered at their CENTRE so that a scale pulse grows
	// both ways; the cell helpers therefore return centres too.
	static function cellX(i:Number):Number {
		return BX + GAP + (i % N) * (TILE + GAP) + TILE / 2;
	}

	static function cellY(i:Number):Number {
		return BY + GAP + Math.floor(i / N) * (TILE + GAP) + TILE / 2;
	}

	// The cells of one row or column, ordered from the edge the move
	// pushes TOWARDS. Compaction then only ever fills forwards.
	static function lineFor(dir:Number, k:Number):Array {
		var a:Array = [];
		var i:Number;
		for (i = 0; i < N; i++) {
			if (dir == 0) a.push(k * N + i);                 // left
			else if (dir == 1) a.push(k * N + (N - 1 - i));  // right
			else if (dir == 2) a.push(i * N + k);            // up
			else a.push((N - 1 - i) * N + k);                // down
		}
		return a;
	}

	// --- tiles -------------------------------------------------------------

	// 2 -> 0, 4 -> 1, 8 -> 2 … the index into COLOURS.
	static function rank(v:Number):Number {
		var k:Number = 0;
		var n:Number = v;
		while (n > 2) {
			n = n / 2;
			k++;
		}
		return k;
	}

	static function paint(t:Object):Void {
		var mc:MovieClip = MovieClip(t.mc);
		mc.clear();                       // graphics only; the field stays
		var r:Number = rank(t.v);
		var colour:Number = (r < COLOURS.length) ? COLOURS[r] : HUGE_COLOUR;
		var half:Number = TILE / 2;
		fillRound(mc, -half, -half, TILE, TILE, 8, colour, 100);

		var s:String = String(t.v);
		var size:Number = 46;
		if (s.length == 3) size = 38;
		else if (s.length == 4) size = 30;
		else if (s.length > 4) size = 24;

		var tf:TextField = mc.lbl;
		style(tf, s, size, (r < 2) ? DARK : LIGHT, true, "center");
		// Centre the line on the tile: textHeight is the drawn height and
		// the field carries a 2px gutter above it.
		tf._y = -tf.textHeight / 2 - 2;
	}

	static function makeTile(idx:Number, v:Number):Object {
		seq++;
		var mc:MovieClip = tiles.createEmptyMovieClip("t" + seq, seq);
		mc.createTextField("lbl", 1, -TILE / 2, 0, TILE, 72);
		var t:Object = {v: v, i: idx, ti: idx, nv: v, into: null,
		                mc: mc, pop: 0, grow: 0,
		                sx: 0, sy: 0, dx: 0, dy: 0};
		paint(t);
		mc._x = cellX(idx);
		mc._y = cellY(idx);
		return t;
	}

	static function spawn():Void {
		var free:Array = [];
		var i:Number;
		for (i = 0; i < N * N; i++) if (cells[i] == null) free.push(i);
		if (free.length == 0) return;
		var idx:Number = free[Math.floor(Math.random() * free.length)];
		var t:Object = makeTile(idx, (Math.random() < 0.9) ? 2 : 4);
		t.grow = GROW;
		t.mc._xscale = 0;
		t.mc._yscale = 0;
		cells[idx] = t;
	}

	// --- the move ----------------------------------------------------------

	// Plans the whole move without touching the screen: every tile gets a
	// target cell `ti`, a value it will hold `nv`, and — if it is the one
	// that disappears — the tile it merges `into`. The slide then just
	// interpolates, and finish() applies the plan.
	static function doMove(dir:Number):Void {
		var i:Number;
		var next:Array = [];
		for (i = 0; i < N * N; i++) next.push(null);

		var live:Array = [];
		for (i = 0; i < N * N; i++) if (cells[i] != null) live.push(cells[i]);

		var moved:Boolean = false;
		var earned:Number = 0;
		var k:Number;
		var j:Number;
		for (k = 0; k < N; k++) {
			var line:Array = lineFor(dir, k);
			var slot:Number = 0;
			// The last tile placed, while it can still absorb one more.
			var open:Object = null;
			for (j = 0; j < N; j++) {
				var t:Object = cells[line[j]];
				if (t == null) continue;
				t.into = null;
				if (open != null && open.nv == t.v) {
					t.ti = open.ti;
					t.into = open;
					open.nv = open.v * 2;
					earned += open.nv;
					open = null;      // a tile merges at most once per move
					moved = true;
				} else {
					t.ti = line[slot];
					t.nv = t.v;
					next[t.ti] = t;
					slot++;
					open = t;
					if (t.ti != t.i) moved = true;
				}
			}
		}
		if (!moved) return;

		// Nothing above touched `cells` or `score`, so the snapshot taken
		// here is still the position before the move.
		snapshot();
		disarm();

		for (i = 0; i < live.length; i++) {
			var m:Object = live[i];
			// Snap any pulse still running — the slide owns the transform
			// from here, and a half-finished scale would ride along.
			m.pop = 0;
			m.grow = 0;
			m.mc._xscale = 100;
			m.mc._yscale = 100;
			m.mc._alpha = 100;
			m.sx = m.mc._x;
			m.sy = m.mc._y;
			m.dx = cellX(m.ti);
			m.dy = cellY(m.ti);
		}
		moving = live;
		nextCells = next;
		gain = earned;
		anim = 0;
		sliding = true;
	}

	static function finish():Void {
		var i:Number;
		for (i = 0; i < moving.length; i++) {
			var t:Object = moving[i];
			t.mc._x = t.dx;
			t.mc._y = t.dy;
			if (t.into != null) {
				t.mc.removeMovieClip();
			} else {
				t.i = t.ti;
				if (t.nv != t.v) {
					t.v = t.nv;
					paint(t);
					t.pop = POP;
					if (t.v >= 2048 && !won) {
						won = true;
						say("2048! Keep going.");
					}
				}
			}
		}
		cells = nextCells;
		score += gain;
		if (score > best) best = score;
		showScore();
		spawn();
		sliding = false;
		anim = 0;
		if (stuck()) {
			over = true;
			showOver();
		}
	}

	static function stuck():Boolean {
		var r:Number;
		var c:Number;
		for (r = 0; r < N * N; r++) if (cells[r] == null) return false;
		for (r = 0; r < N; r++) {
			for (c = 0; c < N; c++) {
				var v:Number = cells[r * N + c].v;
				if (c + 1 < N && cells[r * N + c + 1].v == v) return false;
				if (r + 1 < N && cells[(r + 1) * N + c].v == v) return false;
			}
		}
		return true;
	}

	// --- undo --------------------------------------------------------------

	static function snapshot():Void {
		undoVals = [];
		var i:Number;
		for (i = 0; i < N * N; i++) {
			undoVals.push((cells[i] == null) ? 0 : cells[i].v);
		}
		undoScore = score;
		canUndo = true;
	}

	// One step back, and only one: the snapshot is spent on use, so undo
	// cannot walk a whole game backwards.
	static function undo():Void {
		if (!canUndo) {
			say("Nothing to undo.");
			return;
		}
		var i:Number;
		tiles.removeMovieClip();
		tiles = _root.createEmptyMovieClip("tiles", 20);
		cells = [];
		for (i = 0; i < N * N; i++) cells.push(null);
		for (i = 0; i < N * N; i++) {
			var v:Number = undoVals[i];
			if (v > 0) cells[i] = makeTile(i, v);
		}
		score = undoScore;
		showScore();
		canUndo = false;
		sliding = false;
		queued = -1;
		hideOver();
		say("Undone.");
	}

	// --- frame -------------------------------------------------------------

	static function tick():Void {
		var i:Number;
		readPad();

		if (intro) {
			// The prompt breathes, so a still screen still reads as one
			// that is waiting for you.
			introT++;
			promptFld._alpha = 60 + 40 * Math.sin(introT * 0.09);
			return;
		}

		if (sayT > 0) {
			sayT--;
			if (sayT == 0) say("");
		}
		if (armed > 0) {
			armed--;
			if (armed == 0) say("");
		}

		if (sliding) {
			anim++;
			var u:Number = anim / SLIDE;
			if (u > 1) u = 1;
			var p:Number = 1 - (1 - u) * (1 - u) * (1 - u);   // ease out
			for (i = 0; i < moving.length; i++) {
				var t:Object = moving[i];
				t.mc._x = t.sx + (t.dx - t.sx) * p;
				t.mc._y = t.sy + (t.dy - t.sy) * p;
			}
			if (anim >= SLIDE) finish();
			return;
		}

		for (i = 0; i < N * N; i++) {
			var c:Object = cells[i];
			if (c == null) continue;
			if (c.pop > 0) {
				c.pop--;
				var pu:Number = 1 - c.pop / POP;
				var s:Number = 100 + 15 * Math.sin(Math.PI * pu);
				c.mc._xscale = s;
				c.mc._yscale = s;
			} else if (c.grow > 0) {
				c.grow--;
				var gu:Number = 1 - c.grow / GROW;
				var g:Number = 100 * (gu * gu * (3 - 2 * gu));   // smoothstep
				c.mc._xscale = g;
				c.mc._yscale = g;
				c.mc._alpha = 40 + 60 * gu;
			}
		}

		if (over && veil != null && veil._alpha < 100) {
			veil._alpha = Math.min(100, veil._alpha + 9);
		}

		if (queued >= 0) {
			var d:Number = queued;
			queued = -1;
			if (!over) doMove(d);
		}
	}

	// --- input -------------------------------------------------------------

	// The listener LATCHES a press; the poll below decides what to do
	// with it. Neither half is redundant. A tap shorter than a frame
	// never shows up in `Key.isDown` at all, so the edge has to come
	// from the listener; and a held direction has to repeat at a rate
	// this game picks rather than whatever the host's key repeat is, so
	// the repeat has to come from the poll.
	static function hit(code:Number):Void {
		if (code == 37) latch[0] = true;
		else if (code == 39) latch[1] = true;
		else if (code == 38) latch[2] = true;
		else if (code == 40) latch[3] = true;
		else if (code == 90) latch[4] = true;
		else if (code == 32) latch[5] = true;
		else if (code == 82) latch[6] = true;
	}

	// Seven LITERAL `isDown` calls, which is the only form the core's key
	// survey can read — see the note at the top of the file.
	static function readPad():Void {
		down[0] = Key.isDown(37);        // left
		down[1] = Key.isDown(39);        // right
		down[2] = Key.isDown(38);        // up
		down[3] = Key.isDown(40);        // down
		down[4] = Key.isDown(90);        // Z      -> pad A
		down[5] = Key.isDown(32);        // Space  -> pad B
		down[6] = Key.isDown(82);        // R      -> first spare button

		// EVERY edge is taken before anything is dispatched. `edge` is
		// where the hold and latch bookkeeping happens, so a call skipped
		// under one state would leave that key a frame stale under the
		// next — which is exactly the sort of thing that only shows up as
		// a dropped press once in a while.
		var eLeft:Boolean = edge(0, true);
		var eRight:Boolean = edge(1, true);
		var eUp:Boolean = edge(2, true);
		var eDown:Boolean = edge(3, true);
		var eA:Boolean = edge(4, false);
		var eB:Boolean = edge(5, false);
		var eR:Boolean = edge(6, false);

		if (intro) {
			if (eA || eB || eR) startGame();
			return;
		}

		if (eLeft) push(0);
		if (eRight) push(1);
		if (eUp) push(2);
		if (eDown) push(3);
		if (eA) undo();
		if (eB || eR) restart();
	}

	// At most ONE action per key per frame, whoever asked for it. That
	// cap is what lets both halves run at once: a host that repeats
	// key-downs by itself refills the latch, and dropping it while the
	// key was ALREADY held leaves the schedule below in charge.
	static function edge(i:Number, repeat:Boolean):Boolean {
		var wasHeld:Boolean = hold[i] > 0;
		if (down[i]) hold[i]++;
		else hold[i] = 0;

		var fire:Boolean = latch[i] && !wasHeld;
		latch[i] = false;
		if (repeat && down[i] && hold[i] >= HOLD_FIRST &&
		    ((hold[i] - HOLD_FIRST) % HOLD_NEXT) == 0) fire = true;
		return fire;
	}

	static function push(dir:Number):Void {
		if (over) return;
		disarm();
		// A direction that lands mid-slide is remembered rather than
		// dropped — holding one should feel continuous.
		if (sliding) queued = dir;
		else doMove(dir);
	}

	// Restart is deliberately two presses while a game is live: B is a
	// thumb's width from the D-pad and losing a board to a stray press
	// would be worse than the extra tap.
	static function restart():Void {
		if (over || armed > 0) {
			reset();
			return;
		}
		armed = ARM_FOR;
		say("Press again to restart.");
	}

	static function disarm():Void {
		if (armed > 0) {
			armed = 0;
			say("");
		}
	}

	static function swipe(dx:Number, dy:Number):Void {
		if (over) return;
		var ax:Number = Math.abs(dx);
		var ay:Number = Math.abs(dy);
		if (ax < 24 && ay < 24) return;
		if (ax > ay) push((dx < 0) ? 0 : 1);
		else push((dy < 0) ? 2 : 3);
	}

	// --- chrome ------------------------------------------------------------

	static function scoreBox(y:Number, caption:String, depth:Number):TextField {
		var mc:MovieClip = _root.createEmptyMovieClip("box" + depth, depth);
		mc._x = HX;
		mc._y = y;
		fillRound(mc, 0, 0, HW, 54, 5, BOARD_BG, 100);
		label(mc, "cap", 1, 0, 7, HW, 20, caption, 12, 0xEEE4DA, true, "center");
		return label(mc, "val", 2, 0, 23, HW, 28, "0", 22, 0xFFFFFF, true, "center");
	}

	static function showScore():Void {
		style(scoreFld, String(score), 22, 0xFFFFFF, true, "center");
		style(bestFld, String(best), 22, 0xFFFFFF, true, "center");
	}

	// The default line, and whatever has just happened instead of it.
	static function say(msg:String):Void {
		var txt:String = msg;
		if (txt == "") {
			if (over) txt = "No moves left.";
			else if (won) txt = "2048! Keep going.";
			else txt = "Merge equal tiles.";
			sayT = 0;
		} else {
			sayT = SAY_FOR;
		}
		style(msgFld, txt, 14, MUTED, false, "center");
	}

	static function legendRow(mc:MovieClip, depth:Number, y:Number,
	                          key:String, what:String):Void {
		label(mc, "k" + depth, depth, 0, y, 54, 20, key, 13, DARK, true, "left");
		label(mc, "v" + depth, depth + 1, 58, y, HW - 58, 20, what, 13, MUTED, false, "left");
	}

	static function chrome():Void {
		var bg:MovieClip = _root.createEmptyMovieClip("bg", 1);
		bg.beginFill(BG, 100);
		bg.moveTo(0, 0);
		bg.lineTo(W, 0);
		bg.lineTo(W, H);
		bg.lineTo(0, H);
		bg.endFill();

		var head:MovieClip = _root.createEmptyMovieClip("head", 2);
		head._x = HX;
		label(head, "title", 1, 0, 8, HW, 62, "2048", 46, DARK, true, "left");

		scoreFld = scoreBox(78, "SCORE", 3);
		bestFld = scoreBox(140, "BEST", 4);

		var legend:MovieClip = _root.createEmptyMovieClip("legend", 5);
		legend._x = HX;
		label(legend, "cap", 1, 0, 212, HW, 18, "CONTROLS", 11, MUTED, true, "left");
		legendRow(legend, 10, 234, "D-pad", "Move");
		legendRow(legend, 20, 258, "A", "Undo");
		legendRow(legend, 30, 282, "B", "Restart");
		label(legend, "kbd", 40, 0, 314, HW, 34,
		      "Keyboard: arrows, Z, Space", 11, MUTED, false, "left");

		var foot:MovieClip = _root.createEmptyMovieClip("foot", 6);
		msgFld = label(foot, "msg", 1, HX, 400, HW, 56, "", 14, MUTED, false, "center");
		msgFld.multiline = true;
		msgFld.wordWrap = true;

		// The board and its sixteen empty wells, one clip, one fill each.
		var board:MovieClip = _root.createEmptyMovieClip("board", 10);
		fillRound(board, BX, BY, BOARD, BOARD, 8, BOARD_BG, 100);
		var i:Number;
		for (i = 0; i < N * N; i++) {
			fillRound(board, cellX(i) - TILE / 2, cellY(i) - TILE / 2,
			          TILE, TILE, 8, CELL, 100);
		}
	}

	static function showOver():Void {
		veil = _root.createEmptyMovieClip("veil", 100);
		fillRound(veil, BX, BY, BOARD, BOARD, 8, 0xEEE4DA, 74);
		label(veil, "big", 1, BX, BY + 148, BOARD, 74, "Game over", 48, DARK, true, "center");
		label(veil, "sub", 2, BX, BY + 234, BOARD, 30,
		      "B to play again, A to undo", 17, DARK, false, "center");
		veil._alpha = 0;
		say("");
	}

	// --- the title card ----------------------------------------------------

	static function showIntro():Void {
		intro = true;
		introT = 0;
		introClip = _root.createEmptyMovieClip("intro", 200);
		var c:MovieClip = introClip;
		c.beginFill(BG, 100);
		c.moveTo(0, 0);
		c.lineTo(W, 0);
		c.lineTo(W, H);
		c.lineTo(0, H);
		c.endFill();

		label(c, "title", 1, 0, 40, W, 110, "2048", 84, DARK, true, "center");
		label(c, "sub", 2, 0, 152, W, 24,
		      "Join the numbers to get to the 2048 tile", 17, MUTED, false, "center");

		// Four real tiles rather than a description of them — the palette
		// is half of what the game looks like.
		var vals:Array = [2, 4, 8, 16];
		var ts:Number = 64;
		var gp:Number = 12;
		var sx:Number = (W - (4 * ts + 3 * gp)) / 2;
		var sy:Number = 190;
		var i:Number;
		for (i = 0; i < 4; i++) {
			var v:Number = vals[i];
			var r:Number = rank(v);
			var x:Number = sx + i * (ts + gp);
			fillRound(c, x, sy, ts, ts, 6, COLOURS[r], 100);
			label(c, "d" + i, 10 + i, x, sy + 15, ts, 40, String(v),
			      28, (r < 2) ? DARK : LIGHT, true, "center");
		}

		introRow(c, 30, 280, "D-pad", "Move");
		introRow(c, 32, 302, "A", "Undo");
		introRow(c, 34, 324, "B", "Restart");

		promptFld = label(c, "go", 40, 0, 366, W, 34,
		                  "PRESS FIRE TO START", 22, DARK, true, "center");
		label(c, "kbd", 41, 0, 404, W, 20,
		      "A on the pad  -  Z or Space at the keyboard",
		      12, MUTED, false, "center");
	}

	// Key right-aligned and action left-aligned about a centre gutter, so
	// the rows line up as a table rather than three centred sentences.
	static function introRow(c:MovieClip, d:Number, y:Number,
	                         key:String, what:String):Void {
		label(c, "k" + d, d, W / 2 - 170, y, 160, 22, key, 15, DARK, true, "right");
		label(c, "v" + d, d + 1, W / 2 + 10, y, 200, 22, what, 15, MUTED, false, "left");
	}

	static function startGame():Void {
		intro = false;
		introClip.removeMovieClip();
		introClip = null;
	}

	static function hideOver():Void {
		if (veil != null) {
			veil.removeMovieClip();
			veil = null;
		}
		over = false;
	}

	// --- lifecycle ---------------------------------------------------------

	static function reset():Void {
		var i:Number;
		if (tiles != null) tiles.removeMovieClip();
		tiles = _root.createEmptyMovieClip("tiles", 20);
		hideOver();
		cells = [];
		for (i = 0; i < N * N; i++) cells.push(null);
		score = 0;
		sliding = false;
		anim = 0;
		queued = -1;
		armed = 0;
		won = false;
		canUndo = false;
		dragging = false;
		showScore();
		say("");
		spawn();
		spawn();
	}

	static function main():Void {
		Stage.scaleMode = "showAll";
		Stage.align = "";
		down = [false, false, false, false, false, false, false];
		hold = [0, 0, 0, 0, 0, 0, 0];
		latch = [false, false, false, false, false, false, false];
		sayT = 0;
		armed = 0;
		chrome();
		reset();
		showIntro();

		keys = new Object();
		keys.onKeyDown = function():Void {
			Test.hit(Key.getCode());
		};
		Key.addListener(keys);

		_root.onEnterFrame = function():Void {
			Test.tick();
		};
		// A drag on the stage works the board too, for the frontends that
		// have a pointer at all. Four lines, and a touchscreen build gets
		// swipes for nothing.
		_root.onMouseDown = function():Void {
			Test.dragX = _root._xmouse;
			Test.dragY = _root._ymouse;
			Test.dragging = true;
		};
		_root.onMouseUp = function():Void {
			if (!Test.dragging) return;
			Test.dragging = false;
			Test.swipe(_root._xmouse - Test.dragX, _root._ymouse - Test.dragY);
		};
	}
}
