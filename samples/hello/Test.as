// "Hello Handyplay Flash" — a one-frame movie that animates itself from
// onEnterFrame, which is how AS2 does motion without a timeline.
//
// Everything on screen is drawn by script: a gradient sky, a ring of
// orbiting discs that ADD into each other, a pulsing logo mark under a
// blend mode, and a highlight that sweeps across the title through a
// mask. Compiled with tools/as2 (mtasc), rendered by handyplay-flash.
class Test {
	static var W:Number = 640;
	static var H:Number = 360;
	static var t:Number = 0;

	static var orbit:Array;
	static var mark:MovieClip;
	static var shine:MovieClip;
	static var titleClip:MovieClip;

	static function disc(parent:MovieClip, name:String, depth:Number,
	                     r:Number, colour:Number, alpha:Number):MovieClip {
		var mc:MovieClip = parent.createEmptyMovieClip(name, depth);
		mc.beginFill(colour, alpha);
		// Eight quadratic segments. The control point of an arc drawn
		// with curveTo sits where the two end TANGENTS meet, which for a
		// 45-degree sweep is r/cos(22.5) out along the bisector — four
		// segments with the corner as control (the cubic 0.5523 trick)
		// gives a rounded square, which is what this looked like first.
		var steps:Number = 8;
		var half:Number = Math.PI / steps;
		var ctrlR:Number = r / Math.cos(half);
		mc.moveTo(r, 0);
		for (var i:Number = 1; i <= steps; i++) {
			var a0:Number = (i - 1) * 2 * half;
			var a1:Number = i * 2 * half;
			var am:Number = a0 + half;
			mc.curveTo(Math.cos(am) * ctrlR, Math.sin(am) * ctrlR,
			           Math.cos(a1) * r, Math.sin(a1) * r);
		}
		mc.endFill();
		return mc;
	}

	static function rect(parent:MovieClip, name:String, depth:Number,
	                     w:Number, h:Number, colour:Number):MovieClip {
		var mc:MovieClip = parent.createEmptyMovieClip(name, depth);
		mc.beginFill(colour);
		mc.moveTo(0, 0);
		mc.lineTo(w, 0);
		mc.lineTo(w, h);
		mc.lineTo(0, h);
		mc.endFill();
		return mc;
	}

	static function sky() {
		var mc:MovieClip = _root.createEmptyMovieClip("sky", 1);
		var m:Object = {matrixType: "box", x: 0, y: 0, w: W, h: H, r: Math.PI / 2};
		mc.beginGradientFill("linear", [0x101A33, 0x2B1B4D, 0x0B0F1E],
		                     [100, 100, 100], [0, 130, 255], m, "pad", "linearRGB");
		mc.moveTo(0, 0);
		mc.lineTo(W, 0);
		mc.lineTo(W, H);
		mc.lineTo(0, H);
		mc.endFill();
	}

	// The mark: a rounded square with a notch, drawn as one path so the
	// hole is a genuine hole rather than a second shape on top.
	static function logo() {
		mark = _root.createEmptyMovieClip("mark", 20);
		mark._x = W / 2;
		mark._y = 132;
		var g:Object = {matrixType: "box", x: -46, y: -46, w: 92, h: 92, r: 0.9};
		mark.beginGradientFill("linear", [0xFFB347, 0xFF5E5B, 0xB14AED],
		                       [100, 100, 100], [0, 128, 255], g, "pad", "linearRGB");
		mark.moveTo(-46, -20);
		mark.curveTo(-46, -46, -20, -46);
		mark.lineTo(20, -46);
		mark.curveTo(46, -46, 46, -20);
		mark.lineTo(46, 20);
		mark.curveTo(46, 46, 20, 46);
		mark.lineTo(-20, 46);
		mark.curveTo(-46, 46, -46, 20);
		mark.lineTo(-46, -20);
		// The counter, wound the other way.
		mark.moveTo(-16, -14);
		mark.lineTo(-16, 14);
		mark.lineTo(16, 14);
		mark.lineTo(16, -14);
		mark.lineTo(-16, -14);
		mark.endFill();
	}

	static function title() {
		titleClip = _root.createEmptyMovieClip("titleClip", 30);
		// mtasc's headers say createTextField returns Void — that was
		// true before Flash 8 — so the field is picked up by name.
		titleClip.createTextField("label", 1, 0, 0, W, 60);
		var tf:TextField = titleClip.label;
		tf.selectable = false;
		tf.text = "Hello Handyplay Flash";
		var fmt:TextFormat = new TextFormat();
		fmt.font = "_sans";
		fmt.size = 44;
		fmt.bold = true;
		fmt.color = 0xF2ECFF;
		fmt.align = "center";
		tf.setTextFormat(fmt);
		titleClip._y = 214;

		// A pale bar that will sweep across the title, shown only where
		// the title's own box is — a mask, moving with the highlight.
		shine = _root.createEmptyMovieClip("shine", 31);
		var bar:MovieClip = shine.createEmptyMovieClip("bar", 1);
		// Transparent at both ends so the sweep has no edges of its own.
		var bm:Object = {matrixType: "box", x: 0, y: 0, w: 150, h: 60, r: 0};
		bar.beginGradientFill("linear", [0xFFFFFF, 0xFFFFFF, 0xFFFFFF],
		                      [0, 70, 0], [0, 128, 255], bm, "pad", "RGB");
		bar.moveTo(0, 0);
		bar.lineTo(150, 0);
		bar.lineTo(150, 60);
		bar.lineTo(0, 60);
		bar.endFill();
		bar.blendMode = "add";
		shine._y = 214;
		var m:MovieClip = rect(_root, "shineMask", 32, W, 60, 0x000000);
		m._y = 214;
		shine.setMask(m);
	}

	static function main() {
		sky();
		logo();

		// Six discs that orbit and ADD where they cross, which is the
		// blend mode doing the work rather than a stack of alphas.
		orbit = [];
		var hues:Array = [0xFF6B6B, 0xFFD166, 0x06D6A0, 0x4CC9F0, 0xB14AED, 0xFF9E7A];
		for (var i:Number = 0; i < 6; i++) {
			var d:MovieClip = disc(_root, "orb" + i, 10 + i, 26, hues[i], 70);
			d.blendMode = "add";
			orbit.push(d);
		}

		title();

		_root.onEnterFrame = function () {
			Test.tick();
		};
	}

	static function tick() {
		t += 1;
		var cx:Number = W / 2;
		var cy:Number = 132;
		for (var i:Number = 0; i < orbit.length; i++) {
			var mc:MovieClip = MovieClip(orbit[i]);
			var a:Number = (t * 0.018) + (i * Math.PI / 3);
			var wobble:Number = 96 + Math.sin(t * 0.03 + i) * 26;
			mc._x = cx + Math.cos(a) * wobble * 1.55;
			mc._y = cy + Math.sin(a) * wobble * 0.62;
			var s:Number = 78 + Math.sin(t * 0.05 + i * 1.7) * 26;
			mc._xscale = s;
			mc._yscale = s;
		}

		// The mark breathes and turns a little.
		var pulse:Number = 100 + Math.sin(t * 0.045) * 7;
		mark._xscale = pulse;
		mark._yscale = pulse;
		mark._rotation = Math.sin(t * 0.02) * 8;

		// The highlight sweeps, waits at the far side, and comes back.
		var period:Number = 150;
		var phase:Number = (t % period) / period;
		shine._x = -180 + phase * (W + 360);
	}
}
