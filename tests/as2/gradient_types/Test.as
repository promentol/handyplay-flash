// The three gradient shapes and the three spreads, at full alpha so this
// is about GEOMETRY: where the ramp runs, where it wraps, and where a
// focal gradient puts its centre.
class Test {
	static function cell(depth:Number, x:Number, y:Number, kind:String,
	                     spread:String, focal:Number):MovieClip {
		var mc:MovieClip = _root.createEmptyMovieClip("g" + depth, depth);
		var m:Object = {matrixType: "box", x: x + 15, y: y + 15, w: 50, h: 50, r: 0};
		mc.beginGradientFill(kind, [0xFFDD33, 0x2244AA], [100, 100], [0, 255],
		                     m, spread, "RGB", focal);
		mc.moveTo(x, y);
		mc.lineTo(x + 80, y);
		mc.lineTo(x + 80, y + 80);
		mc.lineTo(x, y + 80);
		mc.endFill();
		return mc;
	}

	static function main() {
		var spreads:Array = ["pad", "reflect", "repeat"];
		var depth:Number = 1;
		for (var s:Number = 0; s < spreads.length; s++) {
			cell(depth++, 10 + s * 90, 10, "linear", spreads[s], 0);
			cell(depth++, 10 + s * 90, 100, "radial", spreads[s], 0);
			// A focal gradient pushed well off centre, but not all the
			// way to the rim where its formula has a singularity.
			cell(depth++, 280 + s * 90, 10, "radial", spreads[s], 0.6);
			cell(depth++, 280 + s * 90, 100, "radial", spreads[s], -0.4);
		}
	}
}
