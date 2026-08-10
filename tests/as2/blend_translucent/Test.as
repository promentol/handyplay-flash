// TRANSLUCENT sources under a blend mode. Every blend test before this
// one used opaque squares, and `add` turned out to ignore the source's
// alpha entirely: a gradient with a zero-alpha stop painted solid white.
// Found by an animation, not by a test, which is why it is a test now.
class Test {
	static function bar(name:String, depth:Number, x:Number, mode:String,
	                    alpha:Number):MovieClip {
		var mc:MovieClip = _root.createEmptyMovieClip(name, depth);
		mc.beginFill(0xFFFFFF, alpha);
		mc.moveTo(0, 0);
		mc.lineTo(60, 0);
		mc.lineTo(60, 60);
		mc.lineTo(0, 60);
		mc.endFill();
		mc._x = x;
		mc._y = 20;
		mc.blendMode = mode;
		return mc;
	}

	static function main() {
		// A mid-grey backdrop so both lighter and darker show.
		var back:MovieClip = _root.createEmptyMovieClip("back", 1);
		back.beginFill(0x50607A);
		back.moveTo(0, 0);
		back.lineTo(420, 0);
		back.lineTo(420, 100);
		back.lineTo(0, 100);
		back.endFill();

		// The same white square at four alphas under `add`.
		bar("a0", 2, 10, "add", 0);
		bar("a25", 3, 80, "add", 25);
		bar("a60", 4, 150, "add", 60);
		bar("a100", 5, 220, "add", 100);

		// And a gradient whose ends are fully transparent, which is the
		// exact shape that exposed it.
		var g:MovieClip = _root.createEmptyMovieClip("grad", 6);
		var m:Object = {matrixType: "box", x: 300, y: 20, w: 100, h: 60, r: 0};
		g.beginGradientFill("linear", [0xFFFFFF, 0xFFFFFF, 0xFFFFFF],
		                    [0, 80, 0], [0, 128, 255], m, "pad", "RGB");
		g.moveTo(300, 20);
		g.lineTo(400, 20);
		g.lineTo(400, 80);
		g.lineTo(300, 80);
		g.endFill();
		g.blendMode = "add";

	}
}
