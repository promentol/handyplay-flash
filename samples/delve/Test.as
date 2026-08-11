// DELVE — a roguelike in ActionScript 2, laid out landscape at 600x400.
//
// Nothing in the SWF but code: the dungeon is filled rectangles from the
// drawing API and every glyph is a dynamic text field in the device
// font. mtasc compiles code and no assets, so this is what AS2 can do
// unaided.
//
// WHY A ROGUELIKE, given this player is FILL-RATE BOUND: the world only
// changes when the player takes a turn, so all the depth — generation,
// field of view, item and monster behaviour — runs once per turn and
// costs nothing at 60Hz. What is drawn is kept deliberately thin on top
// of that:
//
//   * every wall of one colour is ONE path. Four `beginFill` runs cover
//     the whole map (lit wall, remembered wall, lit floor, remembered
//     floor) instead of one per tile.
//   * floors are 3px dots, not filled tiles — Rogue's own '.' — so the
//     painted area is a fraction of the grid.
//   * entity glyphs come from a POOL of text fields that is reused and
//     hidden, never created and destroyed per turn.
//
// KEYS are bare numbers because the libretro core surveys this bytecode
// for them and binds the RetroPad to what it finds (core/key_survey.zig);
// only a literal argument to `Key.isDown` is legible to that walk. The
// set is picked so each button lands on its own role:
//
//   37/38/39/40  the D-pad, verbatim         -> move, and bump to attack
//   90  'Z'      first `action_a` candidate  -> A  = use / descend
//   32  Space    first `select` candidate
//                once 13 is absent           -> B  = wait a turn
//   88  'X'      first `action_b` candidate  -> X  = cycle the pack
//   82  'R'      claimed by no role at all   -> L2 = restart
//
// and what is NOT read matters as much: nothing from the `pause` list
// (P, Esc, 19, Enter) or the `back` list (Esc, Backspace, PageDown, B),
// so START and SELECT are left to the frontend's own menu.
//
// Compiled with tools/as2 (mtasc), rendered by handyplay-flash.
class Test {
	// --- layout, in pixels -------------------------------------------------
	static var W:Number = 600;
	static var H:Number = 400;
	static var TILE:Number = 16;
	static var MAPW:Number = 27;
	static var MAPH:Number = 18;
	static var MAPX:Number = 8;
	static var MAPY:Number = 8;
	static var SIDEX:Number = 448;
	static var SIDEW:Number = 144;
	static var LOGY:Number = 304;
	static var LOGH:Number = 88;
	static var LOGN:Number = 5;              // lines kept on screen

	// --- palette -----------------------------------------------------------
	static var BG:Number = 0x101018;
	static var PANEL:Number = 0x1B1E2A;
	static var EDGE:Number = 0x2A2F40;
	static var WALL:Number = 0x424A63;
	static var WALL_DIM:Number = 0x232634;
	static var FLOOR:Number = 0x5A6178;
	static var FLOOR_DIM:Number = 0x2C303D;
	static var TEXT:Number = 0xCBD0DE;
	static var DIM:Number = 0x6C7488;
	static var HERO:Number = 0xF4EAD5;
	static var HP_OK:Number = 0x7FBF6B;
	static var HP_MID:Number = 0xE2C044;
	static var HP_LOW:Number = 0xD1495B;
	static var STAIR_COL:Number = 0xE8C547;

	// --- the bestiary ------------------------------------------------------
	// Parallel arrays rather than objects: they are read constantly and
	// never written, and this way the table reads as a table.
	static var M_CH:Array = ["r", "g", "k", "o", "s", "T", "W"];
	static var M_NAME:Array = ["rat", "goblin", "kobold", "orc",
	                           "skeleton", "troll", "wraith"];
	static var M_HP:Array = [3, 6, 5, 11, 9, 20, 15];
	static var M_ATK:Array = [2, 3, 4, 6, 7, 9, 11];
	static var M_DEF:Array = [0, 1, 0, 2, 3, 4, 2];
	static var M_COL:Array = [0x9A8C7A, 0x6FBF73, 0xC98A5A, 0x7FA05C,
	                          0xDADADA, 0x5FA37A, 0xB08BD8];
	static var M_MIN:Array = [1, 1, 2, 3, 4, 6, 8];   // first depth it appears

	// --- items -------------------------------------------------------------
	// 0 potion  1 blink  2 fire  3 gold  4 blade  5 mail  6 amulet
	static var POTION:Number = 0;
	static var BLINK:Number = 1;
	static var FIRE:Number = 2;
	static var COIN:Number = 3;
	static var BLADE:Number = 4;
	static var MAIL:Number = 5;
	static var AMULET:Number = 6;
	static var I_CH:Array = ["!", "?", "*", "$", ")", "[", "&"];
	static var I_COL:Array = [0xD1495B, 0x6BA8D8, 0xE07A5F, 0xE8C547,
	                          0xBFC6D8, 0x8FA3C8, 0xF2D06B];
	static var PACK_NAME:Array = ["potion", "blink scroll", "fire scroll"];

	static var AMULET_DEPTH:Number = 8;
	static var FOV_R:Number = 7;

	// --- feel, in frames (the movie runs at 60) ----------------------------
	static var BUMP:Number = 8;              // attack lunge
	static var FLASH:Number = 10;            // a struck thing glows
	static var HOLD_FIRST:Number = 14;       // held-direction repeat
	static var HOLD_NEXT:Number = 6;
	static var ARM_FOR:Number = 120;         // restart confirmation window

	// --- world state -------------------------------------------------------
	static var map:Array;                    // 0 wall, 1 floor, 2 stairs
	static var seen:Array;
	static var vis:Array;
	static var mons:Array;
	static var loot:Array;
	static var rooms:Array;

	static var hx:Number;                    // the hero
	static var hy:Number;
	static var hp:Number;
	static var hpMax:Number;
	static var atk:Number;
	static var def:Number;
	static var gold:Number;
	static var kills:Number;
	static var depth:Number;
	static var pack:Array;                   // counts, indexed by item kind
	static var sel:Number;                   // which pack slot is selected
	static var regen:Number;                 // turns since the last free HP
	static var turns:Number;
	static var dead:Boolean;
	static var hasAmulet:Boolean;

	// --- presentation state ------------------------------------------------
	static var mapDirty:Boolean;
	static var hurt:Number;                  // frames of the red vignette
	static var bumpX:Number;                 // the hero's lunge, in pixels
	static var bumpY:Number;
	static var bumpT:Number;
	static var log:Array;                    // strings, newest last
	static var armed:Number;

	// The title card. The first floor is generated behind it, so clearing
	// it drops you straight into a dungeon that already exists.
	static var intro:Boolean;
	static var introT:Number;
	static var promptFld:TextField;

	static var mapClip:MovieClip;
	static var entClip:MovieClip;
	static var vignette:MovieClip;
	static var veil:MovieClip;
	static var introClip:MovieClip;
	static var pool:Array;                   // reusable glyph fields
	static var used:Number;
	static var logFld:Array;
	static var sideFld:Object;
	static var hpBar:MovieClip;

	static var down:Array;
	static var hold:Array;
	static var latch:Array;
	static var keys:Object;

	// =======================================================================
	// drawing helpers
	// =======================================================================

	static function box(mc:MovieClip, x:Number, y:Number, w:Number, h:Number):Void {
		mc.moveTo(x, y);
		mc.lineTo(x + w, y);
		mc.lineTo(x + w, y + h);
		mc.lineTo(x, y + h);
		mc.lineTo(x, y);
	}

	static function fillBox(mc:MovieClip, x:Number, y:Number, w:Number,
	                        h:Number, colour:Number, alpha:Number):Void {
		mc.beginFill(colour, alpha);
		box(mc, x, y, w, h);
		mc.endFill();
	}

	// Assigning `.text` drops a field back to its default format, so the
	// TextFormat has to follow the string every single time.
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

	static function label(parent:MovieClip, name:String, depthN:Number,
	                      x:Number, y:Number, w:Number, h:Number,
	                      txt:String, size:Number, colour:Number,
	                      bold:Boolean, align:String):TextField {
		// mtasc's headers say createTextField returns Void — true before
		// Flash 8 — so the field is picked up by name afterwards.
		parent.createTextField(name, depthN, x, y, w, h);
		var tf:TextField = parent[name];
		tf.selectable = false;
		style(tf, txt, size, colour, bold, align);
		return tf;
	}

	// =======================================================================
	// the dungeon
	// =======================================================================

	static function at(x:Number, y:Number):Number {
		if (x < 0 || y < 0 || x >= MAPW || y >= MAPH) return 0;
		return map[y * MAPW + x];
	}

	static function walkable(x:Number, y:Number):Boolean {
		return at(x, y) > 0;
	}

	static function rnd(n:Number):Number {
		return Math.floor(Math.random() * n);
	}

	static function carve(x:Number, y:Number, w:Number, h:Number):Void {
		var i:Number;
		var j:Number;
		for (j = y; j < y + h; j++) {
			for (i = x; i < x + w; i++) map[j * MAPW + i] = 1;
		}
	}

	// An L-shaped corridor, the leg order chosen at random so the level
	// does not read as a comb.
	static function corridor(x0:Number, y0:Number, x1:Number, y1:Number):Void {
		var i:Number;
		if (rnd(2) == 0) {
			for (i = Math.min(x0, x1); i <= Math.max(x0, x1); i++) map[y0 * MAPW + i] = 1;
			for (i = Math.min(y0, y1); i <= Math.max(y0, y1); i++) map[i * MAPW + x1] = 1;
		} else {
			for (i = Math.min(y0, y1); i <= Math.max(y0, y1); i++) map[i * MAPW + x0] = 1;
			for (i = Math.min(x0, x1); i <= Math.max(x0, x1); i++) map[y1 * MAPW + i] = 1;
		}
	}

	static function cx(r:Object):Number { return Math.floor(r.x + r.w / 2); }
	static function cy(r:Object):Number { return Math.floor(r.y + r.h / 2); }

	// Rooms placed by rejection, each joined to the one before. Simple,
	// and it cannot produce a disconnected level — which a maze carver
	// left to itself very much can.
	static function genLevel():Void {
		var i:Number;
		var tries:Number;
		do {
			map = [];
			seen = [];
			vis = [];
			for (i = 0; i < MAPW * MAPH; i++) {
				map.push(0);
				seen.push(false);
				vis.push(false);
			}
			rooms = [];
			tries = 0;
			while (rooms.length < 8 && tries < 240) {
				tries++;
				var rw:Number = 4 + rnd(4);
				var rh:Number = 3 + rnd(3);
				var rx:Number = 1 + rnd(MAPW - rw - 2);
				var ry:Number = 1 + rnd(MAPH - rh - 2);
				var ok:Boolean = true;
				for (i = 0; i < rooms.length; i++) {
					var o:Object = rooms[i];
					if (rx <= o.x + o.w && rx + rw >= o.x - 1 &&
					    ry <= o.y + o.h && ry + rh >= o.y - 1) {
						ok = false;
						break;
					}
				}
				if (!ok) continue;
				carve(rx, ry, rw, rh);
				var here:Object = {x: rx, y: ry, w: rw, h: rh};
				if (rooms.length > 0) {
					var prev:Object = rooms[rooms.length - 1];
					corridor(cx(prev), cy(prev), cx(here), cy(here));
				}
				rooms.push(here);
			}
		} while (rooms.length < 3);

		var first:Object = rooms[0];
		hx = cx(first);
		hy = cy(first);

		var last:Object = rooms[rooms.length - 1];
		map[cy(last) * MAPW + cx(last)] = 2;      // the way down

		mons = [];
		loot = [];
		var n:Number = 4 + Math.floor(depth * 1.2);
		for (i = 0; i < n; i++) spawnMonster();
		n = 2 + rnd(3);
		for (i = 0; i < n; i++) dropLoot(rollLoot());
		if (depth == AMULET_DEPTH && !hasAmulet) dropLoot(AMULET);
	}

	// A free floor tile that is not the hero's and not already occupied.
	static function freeSpot():Array {
		var guard:Number = 0;
		while (guard < 500) {
			guard++;
			var x:Number = rnd(MAPW);
			var y:Number = rnd(MAPH);
			if (!walkable(x, y)) continue;
			if (x == hx && y == hy) continue;
			if (Math.abs(x - hx) + Math.abs(y - hy) < 5) continue;
			if (monAt(x, y) != null) continue;
			return [x, y];
		}
		return null;
	}

	static function spawnMonster():Void {
		var spot:Array = freeSpot();
		if (spot == null) return;
		// Choose among everything this deep, biased to the newest arrival.
		var pick:Array = [];
		var i:Number;
		for (i = 0; i < M_CH.length; i++) {
			if (M_MIN[i] <= depth) pick.push(i);
		}
		var k:Number = pick[Math.min(pick.length - 1,
		                             Math.floor(Math.pow(Math.random(), 0.7) * pick.length))];
		var scale:Number = 1 + (depth - 1) * 0.12;
		mons.push({
			x: spot[0], y: spot[1], k: k,
			hp: Math.ceil(M_HP[k] * scale),
			max: Math.ceil(M_HP[k] * scale),
			atk: Math.ceil(M_ATK[k] * scale),
			def: M_DEF[k],
			flash: 0, bx: 0, by: 0, bt: 0
		});
	}

	static function rollLoot():Number {
		var r:Number = rnd(100);
		if (r < 30) return COIN;
		if (r < 55) return POTION;
		if (r < 68) return BLINK;
		if (r < 80) return FIRE;
		if (r < 91) return BLADE;
		return MAIL;
	}

	static function dropLoot(kind:Number):Void {
		var spot:Array = freeSpot();
		if (spot == null) return;
		loot.push({x: spot[0], y: spot[1], k: kind});
	}

	// =======================================================================
	// field of view
	// =======================================================================

	// Bresenham from the hero outwards. A wall ON the target still shows —
	// you can see the wall you cannot see past.
	static function lineClear(x0:Number, y0:Number, x1:Number, y1:Number):Boolean {
		var dx:Number = Math.abs(x1 - x0);
		var dy:Number = -Math.abs(y1 - y0);
		var sx:Number = (x0 < x1) ? 1 : -1;
		var sy:Number = (y0 < y1) ? 1 : -1;
		var err:Number = dx + dy;
		var x:Number = x0;
		var y:Number = y0;
		var guard:Number = 0;
		while (guard < 64) {
			guard++;
			if (x == x1 && y == y1) return true;
			var e2:Number = 2 * err;
			if (e2 >= dy) { err += dy; x += sx; }
			if (e2 <= dx) { err += dx; y += sy; }
			if (x == x1 && y == y1) return true;
			if (at(x, y) == 0) return false;
		}
		return false;
	}

	static function computeFov():Void {
		var i:Number;
		for (i = 0; i < MAPW * MAPH; i++) vis[i] = false;
		var x:Number;
		var y:Number;
		for (y = hy - FOV_R; y <= hy + FOV_R; y++) {
			for (x = hx - FOV_R; x <= hx + FOV_R; x++) {
				if (x < 0 || y < 0 || x >= MAPW || y >= MAPH) continue;
				var dx:Number = x - hx;
				var dy:Number = y - hy;
				if (dx * dx + dy * dy > FOV_R * FOV_R) continue;
				if (!lineClear(hx, hy, x, y)) continue;
				vis[y * MAPW + x] = true;
				seen[y * MAPW + x] = true;
			}
		}
		mapDirty = true;
	}

	static function visible(x:Number, y:Number):Boolean {
		if (x < 0 || y < 0 || x >= MAPW || y >= MAPH) return false;
		return vis[y * MAPW + x];
	}

	// =======================================================================
	// the turn
	// =======================================================================

	static function monAt(x:Number, y:Number):Object {
		var i:Number;
		for (i = 0; i < mons.length; i++) {
			var m:Object = mons[i];
			if (m.x == x && m.y == y) return m;
		}
		return null;
	}

	static function say(msg:String):Void {
		log.push(msg);
		while (log.length > LOGN) log.shift();
		drawLog();
	}

	static function damage(a:Number, d:Number):Number {
		var raw:Number = a + rnd(3) - d;
		return (raw < 1) ? 1 : raw;
	}

	static function heroStep(dx:Number, dy:Number):Void {
		var nx:Number = hx + dx;
		var ny:Number = hy + dy;
		var m:Object = monAt(nx, ny);
		if (m != null) {
			var dmg:Number = damage(atk, m.def);
			m.hp -= dmg;
			m.flash = FLASH;
			bumpX = dx * 5;
			bumpY = dy * 5;
			bumpT = BUMP;
			if (m.hp <= 0) {
				say("You kill the " + M_NAME[m.k] + ".");
				kills++;
				removeMon(m);
			} else {
				say("You hit the " + M_NAME[m.k] + " for " + dmg + ".");
			}
			endTurn();
			return;
		}
		if (!walkable(nx, ny)) return;         // a wall costs no turn
		hx = nx;
		hy = ny;
		pickUp();
		endTurn();
	}

	static function removeMon(m:Object):Void {
		var i:Number;
		for (i = 0; i < mons.length; i++) {
			if (mons[i] == m) {
				mons.splice(i, 1);
				return;
			}
		}
	}

	static function pickUp():Void {
		var i:Number;
		for (i = 0; i < loot.length; i++) {
			var it:Object = loot[i];
			if (it.x != hx || it.y != hy) continue;
			loot.splice(i, 1);
			if (it.k == COIN) {
				var g:Number = 5 + rnd(10 + depth * 3);
				gold += g;
				say("You pick up " + g + " gold.");
			} else if (it.k == BLADE) {
				atk += 1 + rnd(2);
				say("A better blade. Attack is now " + atk + ".");
			} else if (it.k == MAIL) {
				def += 1;
				say("Heavier mail. Defence is now " + def + ".");
			} else if (it.k == AMULET) {
				hasAmulet = true;
				say("THE AMULET IS YOURS. Now get out alive.");
			} else {
				pack[it.k]++;
				say("You pocket a " + PACK_NAME[it.k] + ".");
			}
			return;
		}
	}

	static function usePack():Void {
		if (pack[sel] <= 0) {
			say("You have no " + PACK_NAME[sel] + ".");
			return;
		}
		pack[sel]--;
		if (sel == POTION) {
			var h:Number = 8 + rnd(6);
			hp = Math.min(hpMax, hp + h);
			say("You drink. " + h + " healed.");
		} else if (sel == BLINK) {
			var spot:Array = freeSpot();
			if (spot != null) {
				hx = spot[0];
				hy = spot[1];
				say("The world lurches.");
			} else {
				say("Nothing happens.");
			}
		} else {
			var hitAny:Boolean = false;
			var i:Number;
			for (i = mons.length - 1; i >= 0; i--) {
				var m:Object = mons[i];
				if (!visible(m.x, m.y)) continue;
				hitAny = true;
				m.hp -= 6 + depth;
				m.flash = FLASH;
				if (m.hp <= 0) {
					kills++;
					mons.splice(i, 1);
				}
			}
			say(hitAny ? "Fire roars through the room." : "The fire finds nothing.");
		}
		endTurn();
	}

	static function descend():Void {
		depth++;
		say("You climb down to depth " + depth + ".");
		genLevel();
		computeFov();
		// Descending costs no turn, so `endTurn` never runs and the
		// readout would sit on the old depth until the next step.
		drawSide();
	}

	static function act():Void {
		if (at(hx, hy) == 2) {
			descend();
			return;
		}
		usePack();
	}

	// Everything that is not the hero, once the hero has moved.
	static function monsterTurn():Void {
		var i:Number;
		for (i = 0; i < mons.length; i++) {
			var m:Object = mons[i];
			var dx:Number = hx - m.x;
			var dy:Number = hy - m.y;
			if (Math.abs(dx) + Math.abs(dy) == 1) {
				var dmg:Number = damage(m.atk, def);
				hp -= dmg;
				hurt = 12;
				m.bx = dx * 5;
				m.by = dy * 5;
				m.bt = BUMP;
				say("The " + M_NAME[m.k] + " hits you for " + dmg + ".");
				if (hp <= 0) {
					hp = 0;
					die();
					return;
				}
				continue;
			}
			// It only comes for you if it can see you.
			var far:Number = dx * dx + dy * dy;
			if (far > 100 || !lineClear(m.x, m.y, hx, hy)) continue;
			var sx:Number = (dx == 0) ? 0 : ((dx > 0) ? 1 : -1);
			var sy:Number = (dy == 0) ? 0 : ((dy > 0) ? 1 : -1);
			// Try the dominant axis, then the other, then give up. Enough
			// to round a corner without a pathfinder.
			if (Math.abs(dx) > Math.abs(dy)) {
				if (tryMove(m, sx, 0)) continue;
				if (tryMove(m, 0, sy)) continue;
			} else {
				if (tryMove(m, 0, sy)) continue;
				if (tryMove(m, sx, 0)) continue;
			}
		}
	}

	static function tryMove(m:Object, dx:Number, dy:Number):Boolean {
		if (dx == 0 && dy == 0) return false;
		var nx:Number = m.x + dx;
		var ny:Number = m.y + dy;
		if (!walkable(nx, ny)) return false;
		if (nx == hx && ny == hy) return false;
		if (monAt(nx, ny) != null) return false;
		m.x = nx;
		m.y = ny;
		return true;
	}

	static function endTurn():Void {
		if (dead) return;
		turns++;
		monsterTurn();
		if (dead) return;
		// A trickle of healing, so a cleared floor is worth walking.
		regen++;
		if (regen >= 18 && hp < hpMax) {
			regen = 0;
			hp++;
		}
		computeFov();
		drawSide();
	}

	static function die():Void {
		dead = true;
		say("You die on depth " + depth + ".");
		// `endTurn` bails out the moment this returns, so the readout
		// would keep the HP the killing blow landed on.
		drawSide();
		showEnd();
	}

	static function score():Number {
		return gold + kills * 5 + depth * 25 + (hasAmulet ? 500 : 0);
	}

	// =======================================================================
	// rendering
	// =======================================================================

	// Four paths for the whole floor: lit walls, remembered walls, lit
	// floor dots, remembered floor dots. One `beginFill` each.
	static function drawMap():Void {
		var mc:MovieClip = mapClip;
		mc.clear();
		var i:Number;
		var x:Number;
		var y:Number;
		var pass:Number;
		for (pass = 0; pass < 2; pass++) {
			mc.beginFill((pass == 0) ? WALL_DIM : WALL, 100);
			for (i = 0; i < MAPW * MAPH; i++) {
				if (!seen[i] || map[i] != 0) continue;
				if ((pass == 0) == vis[i]) continue;
				// A wall is only worth drawing if it touches open floor;
				// the solid rock behind it is not part of the room.
				x = i % MAPW;
				y = Math.floor(i / MAPW);
				if (!edgeWall(x, y)) continue;
				box(mc, MAPX + x * TILE, MAPY + y * TILE, TILE - 1, TILE - 1);
			}
			mc.endFill();
		}
		for (pass = 0; pass < 2; pass++) {
			mc.beginFill((pass == 0) ? FLOOR_DIM : FLOOR, 100);
			for (i = 0; i < MAPW * MAPH; i++) {
				if (!seen[i] || map[i] != 1) continue;
				if ((pass == 0) == vis[i]) continue;
				x = i % MAPW;
				y = Math.floor(i / MAPW);
				box(mc, MAPX + x * TILE + TILE / 2 - 1,
				    MAPY + y * TILE + TILE / 2 - 1, 3, 3);
			}
			mc.endFill();
		}
	}

	static function edgeWall(x:Number, y:Number):Boolean {
		var dx:Number;
		var dy:Number;
		for (dy = -1; dy <= 1; dy++) {
			for (dx = -1; dx <= 1; dx++) {
				if (at(x + dx, y + dy) > 0) return true;
			}
		}
		return false;
	}

	// --- the glyph pool ---
	static function beginGlyphs():Void {
		used = 0;
	}

	static function glyph(gx:Number, gy:Number, ox:Number, oy:Number,
	                      ch:String, colour:Number):Void {
		var tf:TextField;
		if (used < pool.length) {
			tf = TextField(pool[used]);
		} else {
			entClip.createTextField("g" + used, used + 1, 0, 0, TILE, TILE + 4);
			tf = entClip["g" + used];
			tf.selectable = false;
			pool.push(tf);
		}
		used++;
		tf._visible = true;
		tf._x = MAPX + gx * TILE + ox;
		tf._y = MAPY + gy * TILE - 2 + oy;
		style(tf, ch, 13, colour, true, "center");
	}

	static function endGlyphs():Void {
		var i:Number;
		for (i = used; i < pool.length; i++) {
			TextField(pool[i])._visible = false;
		}
	}

	static function drawEntities():Void {
		beginGlyphs();
		var i:Number;
		// Loot under foot, then monsters, then the hero on top — the pool
		// is drawn in call order, so that IS the z-order.
		for (i = 0; i < loot.length; i++) {
			var it:Object = loot[i];
			if (!visible(it.x, it.y)) continue;
			glyph(it.x, it.y, 0, 0, I_CH[it.k], I_COL[it.k]);
		}
		if (at(hx, hy) != 2) {
			// The stairs are part of the floor, not an entity, but they
			// are drawn as one so they read at a glance.
			for (i = 0; i < MAPW * MAPH; i++) {
				if (map[i] != 2 || !seen[i]) continue;
				glyph(i % MAPW, Math.floor(i / MAPW), 0, 0, ">",
				      vis[i] ? STAIR_COL : DIM);
			}
		}
		for (i = 0; i < mons.length; i++) {
			var m:Object = mons[i];
			if (!visible(m.x, m.y)) continue;
			var col:Number = (m.flash > 0) ? 0xFFFFFF : M_COL[m.k];
			glyph(m.x, m.y, m.bx, m.by, M_CH[m.k], col);
		}
		glyph(hx, hy, bumpX, bumpY, "@", HERO);
		endGlyphs();
	}

	static function drawLog():Void {
		var i:Number;
		for (i = 0; i < LOGN; i++) {
			var idx:Number = log.length - LOGN + i;
			var txt:String = (idx >= 0) ? String(log[idx]) : "";
			// The newest line is bright and the older ones recede.
			var age:Number = LOGN - 1 - i;
			var col:Number = (age == 0) ? TEXT : ((age == 1) ? 0x9AA1B4 : DIM);
			style(TextField(logFld[i]), txt, 12, col, age == 0, "left");
		}
	}

	static function drawSide():Void {
		style(TextField(sideFld.depth), "DEPTH " + depth, 15, TEXT, true, "left");
		style(TextField(sideFld.hp), hp + " / " + hpMax, 12, TEXT, true, "right");
		style(TextField(sideFld.atk), String(atk), 12, TEXT, true, "right");
		style(TextField(sideFld.def), String(def), 12, TEXT, true, "right");
		style(TextField(sideFld.gold), String(gold), 12, STAIR_COL, true, "right");
		style(TextField(sideFld.kills), String(kills), 12, TEXT, true, "right");

		var frac:Number = hp / hpMax;
		var col:Number = (frac > 0.5) ? HP_OK : ((frac > 0.25) ? HP_MID : HP_LOW);
		hpBar.clear();
		fillBox(hpBar, 0, 0, SIDEW - 16, 6, 0x2A2F40, 100);
		if (frac > 0) fillBox(hpBar, 0, 0, (SIDEW - 16) * frac, 6, col, 100);

		var i:Number;
		for (i = 0; i < 3; i++) {
			var lit:Boolean = (i == sel);
			var have:Boolean = pack[i] > 0;
			var c:Number = have ? (lit ? TEXT : DIM) : 0x4A5064;
			style(TextField(sideFld.pack[i]),
			      (lit ? "> " : "  ") + I_CH[i] + " " + PACK_NAME[i] + "  " + pack[i],
			      11, c, lit, "left");
		}

		var hint:String = (at(hx, hy) == 2) ? "A descends" : "A uses";
		if (hasAmulet) hint = hint + "  &";
		style(TextField(sideFld.hint), hint, 11, DIM, false, "left");
	}

	static function chrome():Void {
		var bg:MovieClip = _root.createEmptyMovieClip("bg", 1);
		fillBox(bg, 0, 0, W, H, BG, 100);
		fillBox(bg, MAPX - 4, MAPY - 4, MAPW * TILE + 8, MAPH * TILE + 8, PANEL, 100);
		fillBox(bg, SIDEX, MAPY - 4, SIDEW, MAPH * TILE + 8, PANEL, 100);
		fillBox(bg, MAPX - 4, LOGY, W - 2 * (MAPX - 4), LOGH, PANEL, 100);

		mapClip = _root.createEmptyMovieClip("map", 10);
		entClip = _root.createEmptyMovieClip("ent", 20);

		// --- the sidebar ---
		var s:MovieClip = _root.createEmptyMovieClip("side", 30);
		s._x = SIDEX + 8;
		s._y = MAPY + 4;
		var w:Number = SIDEW - 16;
		sideFld = {};
		sideFld.depth = label(s, "d", 1, 0, 0, w, 20, "DEPTH 1", 15, TEXT, true, "left");

		hpBar = s.createEmptyMovieClip("bar", 2);
		hpBar._y = 26;

		sideFld.hp = label(s, "hp", 3, 0, 34, w, 16, "", 12, TEXT, true, "right");
		label(s, "hpl", 4, 0, 34, w, 16, "HP", 12, DIM, false, "left");
		sideFld.atk = label(s, "at", 5, 0, 52, w, 16, "", 12, TEXT, true, "right");
		label(s, "atl", 6, 0, 52, w, 16, "Attack", 12, DIM, false, "left");
		sideFld.def = label(s, "df", 7, 0, 70, w, 16, "", 12, TEXT, true, "right");
		label(s, "dfl", 8, 0, 70, w, 16, "Defence", 12, DIM, false, "left");
		sideFld.gold = label(s, "gd", 9, 0, 88, w, 16, "", 12, TEXT, true, "right");
		label(s, "gdl", 10, 0, 88, w, 16, "Gold", 12, DIM, false, "left");
		sideFld.kills = label(s, "kl", 11, 0, 106, w, 16, "", 12, TEXT, true, "right");
		label(s, "kll", 12, 0, 106, w, 16, "Kills", 12, DIM, false, "left");

		label(s, "pk", 13, 0, 134, w, 14, "PACK   X cycles", 10, 0x596079, true, "left");
		sideFld.pack = [];
		var i:Number;
		for (i = 0; i < 3; i++) {
			sideFld.pack.push(label(s, "p" + i, 20 + i, 0, 150 + i * 15, w, 14,
			                        "", 11, DIM, false, "left"));
		}

		sideFld.hint = label(s, "hint", 40, 0, 204, w, 14, "", 11, DIM, false, "left");
		label(s, "k1", 41, 0, 228, w, 14, "D-pad  move / attack", 10, 0x4A5064, false, "left");
		label(s, "k2", 42, 0, 242, w, 14, "B  wait a turn", 10, 0x4A5064, false, "left");
		label(s, "k3", 43, 0, 256, w, 14, "L2  restart", 10, 0x4A5064, false, "left");

		// --- the log ---
		var lg:MovieClip = _root.createEmptyMovieClip("logc", 31);
		logFld = [];
		for (i = 0; i < LOGN; i++) {
			logFld.push(label(lg, "l" + i, i + 1, MAPX + 4, LOGY + 6 + i * 16,
			                  W - 2 * MAPX - 16, 16, "", 12, DIM, false, "left"));
		}

		// A red frame that pulses when something lands a hit — cheaper
		// than tinting the map and easier to read at a glance.
		vignette = _root.createEmptyMovieClip("vig", 40);
		vignette.beginFill(HP_LOW, 100);
		box(vignette, 0, 0, W, H);
		box(vignette, 6, 6, W - 12, H - 12);
		vignette.endFill();
		vignette._alpha = 0;
	}

	// --- the title card ----------------------------------------------------

	static function introRow(c:MovieClip, d:Number, y:Number,
	                         key:String, what:String):Void {
		label(c, "k" + d, d, W / 2 - 170, y, 150, 18, key, 12, TEXT, true, "right");
		label(c, "v" + d, d + 1, W / 2 - 8, y, 220, 18, what, 12, DIM, false, "left");
	}

	static function showIntro():Void {
		intro = true;
		introT = 0;
		introClip = _root.createEmptyMovieClip("intro", 200);
		var c:MovieClip = introClip;
		fillBox(c, 0, 0, W, H, BG, 100);
		fillBox(c, 28, 22, W - 56, H - 44, PANEL, 100);
		fillBox(c, 28, 22, W - 56, 2, EDGE, 100);
		fillBox(c, 28, H - 24, W - 56, 2, EDGE, 100);

		label(c, "title", 1, 0, 44, W, 66, "DELVE", 50, HERO, true, "center");
		label(c, "sub", 2, 0, 106, W, 22,
		      "eight floors down, an amulet", 14, DIM, false, "center");

		// The cast, each in the colour it will actually be wearing.
		var chs:Array = ["@", "r", "g", "o", "s", "T", "W", "&"];
		var cols:Array = [HERO, M_COL[0], M_COL[1], M_COL[3],
		                  M_COL[4], M_COL[5], M_COL[6], I_COL[AMULET]];
		var n:Number = chs.length;
		var sp:Number = 32;
		var x0:Number = (W - (n - 1) * sp) / 2;
		var i:Number;
		for (i = 0; i < n; i++) {
			label(c, "c" + i, 10 + i, x0 + i * sp - 16, 142, 32, 26,
			      String(chs[i]), 20, Number(cols[i]), true, "center");
		}

		introRow(c, 30, 190, "D-pad", "move, and bump to attack");
		introRow(c, 32, 210, "A", "use the selected item, or descend");
		introRow(c, 34, 230, "B", "wait a turn");
		introRow(c, 36, 250, "X", "cycle the pack");

		promptFld = label(c, "go", 50, 0, 292, W, 30,
		                  "PRESS FIRE TO START", 20, HERO, true, "center");
		label(c, "kbd", 51, 0, 326, W, 18,
		      "A on the pad  -  Z or Space at the keyboard",
		      11, 0x596079, false, "center");
	}

	static function startGame():Void {
		intro = false;
		introClip.removeMovieClip();
		introClip = null;
	}

	static function showEnd():Void {
		veil = _root.createEmptyMovieClip("veil", 50);
		fillBox(veil, MAPX - 4, MAPY - 4, MAPW * TILE + 8, MAPH * TILE + 8, 0x0A0A10, 82);
		var bw:Number = MAPW * TILE;
		label(veil, "big", 1, MAPX, MAPY + 90, bw, 40,
		      hasAmulet ? "You escape, amulet in hand" : "You die", 26, HERO, true, "center");
		label(veil, "sub", 2, MAPX, MAPY + 130, bw, 24,
		      "depth " + depth + "   " + kills + " slain   " + gold + " gold",
		      13, TEXT, false, "center");
		label(veil, "sc", 3, MAPX, MAPY + 154, bw, 26,
		      "SCORE " + score(), 18, STAIR_COL, true, "center");
		label(veil, "again", 4, MAPX, MAPY + 190, bw, 20,
		      "A or L2 to delve again", 12, DIM, false, "center");
		veil._alpha = 0;
	}

	// =======================================================================
	// input
	// =======================================================================

	static function hit(code:Number):Void {
		if (code == 37) latch[0] = true;
		else if (code == 39) latch[1] = true;
		else if (code == 38) latch[2] = true;
		else if (code == 40) latch[3] = true;
		else if (code == 90) latch[4] = true;
		else if (code == 32) latch[5] = true;
		else if (code == 88) latch[6] = true;
		else if (code == 82) latch[7] = true;
	}

	// Eight LITERAL `isDown` calls — the only form the core's key survey
	// can read. See the note at the top of the file.
	static function readPad():Void {
		down[0] = Key.isDown(37);        // left
		down[1] = Key.isDown(39);        // right
		down[2] = Key.isDown(38);        // up
		down[3] = Key.isDown(40);        // down
		down[4] = Key.isDown(90);        // Z  -> pad A
		down[5] = Key.isDown(32);        // Space -> pad B
		down[6] = Key.isDown(88);        // X  -> pad X
		down[7] = Key.isDown(82);        // R  -> first spare button

		// EVERY edge is taken before anything is dispatched. `edge` is
		// where the hold and latch bookkeeping happens, so a call skipped
		// under one state would leave that key a frame stale under the
		// next — which only ever shows up as an occasional dropped press.
		var eLeft:Boolean = edge(0, true);
		var eRight:Boolean = edge(1, true);
		var eUp:Boolean = edge(2, true);
		var eDown:Boolean = edge(3, true);
		var eA:Boolean = edge(4, false);
		var eB:Boolean = edge(5, false);
		var eX:Boolean = edge(6, false);
		var eR:Boolean = edge(7, false);

		if (intro) {
			if (eA || eB) startGame();
			return;
		}

		if (eLeft) step(-1, 0);
		if (eRight) step(1, 0);
		if (eUp) step(0, -1);
		if (eDown) step(0, 1);
		if (eA) buttonA();
		if (eB) buttonB();
		if (eX) cyclePack();
		if (eR) restart();
	}

	// At most ONE action per key per frame, whoever asked for it: the
	// listener catches a tap shorter than a frame, the poll owns the
	// repeat, and dropping the latch while the key was already held
	// leaves the schedule in charge.
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

	static function step(dx:Number, dy:Number):Void {
		if (dead) return;
		disarm();
		heroStep(dx, dy);
	}

	static function buttonA():Void {
		if (dead) {
			reset();
			return;
		}
		disarm();
		act();
	}

	static function buttonB():Void {
		if (dead) return;
		disarm();
		say("You wait.");
		endTurn();
	}

	static function cyclePack():Void {
		if (dead) return;
		sel = (sel + 1) % 3;
		drawSide();
	}

	// Restart is two presses in play — L2 is easy to brush — and one
	// when the run is already over.
	static function restart():Void {
		if (dead || armed > 0) {
			reset();
			return;
		}
		armed = ARM_FOR;
		say("Press again to abandon this run.");
	}

	static function disarm():Void {
		if (armed > 0) armed = 0;
	}

	// =======================================================================
	// frame
	// =======================================================================

	static function tick():Void {
		readPad();
		var i:Number;

		if (intro) {
			// The prompt breathes, so a still screen still reads as one
			// that is waiting for you.
			introT++;
			promptFld._alpha = 60 + 40 * Math.sin(introT * 0.09);
			return;
		}

		if (armed > 0) armed--;

		if (bumpT > 0) {
			bumpT--;
			if (bumpT == 0) {
				bumpX = 0;
				bumpY = 0;
			} else {
				bumpX *= 0.7;
				bumpY *= 0.7;
			}
		}
		var animating:Boolean = bumpT > 0;
		for (i = 0; i < mons.length; i++) {
			var m:Object = mons[i];
			if (m.flash > 0) {
				m.flash--;
				animating = true;
			}
			if (m.bt > 0) {
				m.bt--;
				m.bx *= 0.7;
				m.by *= 0.7;
				if (m.bt == 0) {
					m.bx = 0;
					m.by = 0;
				}
				animating = true;
			}
		}

		if (hurt > 0) {
			hurt--;
			vignette._alpha = hurt * 6;
		}

		if (mapDirty) {
			mapDirty = false;
			drawMap();
			drawEntities();
		} else if (animating) {
			drawEntities();
		}

		if (dead && veil != null && veil._alpha < 100) {
			veil._alpha = Math.min(100, veil._alpha + 7);
		}
	}

	// =======================================================================
	// lifecycle
	// =======================================================================

	static function reset():Void {
		if (veil != null) {
			veil.removeMovieClip();
			veil = null;
		}
		dead = false;
		hasAmulet = false;
		depth = 1;
		hpMax = 24;
		hp = hpMax;
		atk = 4;
		def = 1;
		gold = 0;
		kills = 0;
		turns = 0;
		regen = 0;
		pack = [2, 1, 1];
		sel = 0;
		armed = 0;
		hurt = 0;
		bumpX = 0;
		bumpY = 0;
		bumpT = 0;
		vignette._alpha = 0;
		log = [];
		genLevel();
		computeFov();
		say("You enter the dungeon. Find the amulet on depth " + AMULET_DEPTH + ".");
		drawSide();
	}

	static function main():Void {
		Stage.scaleMode = "showAll";
		Stage.align = "";
		down = [false, false, false, false, false, false, false, false];
		hold = [0, 0, 0, 0, 0, 0, 0, 0];
		latch = [false, false, false, false, false, false, false, false];
		pool = [];
		used = 0;
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
	}
}
