// Gradients whose two stops have DIFFERENT ALPHAS, in both interpolation
// spaces. This is the shape that exposed the reference shader treating a
// straight-alpha ramp as premultiplied: with equal alphas the two agree,
// and only when the alpha varies do they part company. Each row walks
// the spread modes so the wrap and the reflection are covered too.
class Test {
	static function cellMatrix(x:Number, y:Number, size:Number):Object {
		return {matrixType: "box", x: x, y: y, w: size, h: size, r: 0};
	}

	static function cell(depth:Number, x:Number, y:Number, alphas:Array,
	                     interp:String, spread:String):MovieClip {
		var mc:MovieClip = _root.createEmptyMovieClip("g" + depth, depth);
		mc.beginGradientFill("linear", [0xFF1419, 0x0E14FF], alphas, [0, 200],
		                     cellMatrix(x + 10, y + 10, 60), spread, interp);
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
			// Row 1: equal alphas — the two players should agree closely.
			cell(depth++, 10 + s * 90, 10, [100, 100], "RGB", spreads[s]);
			cell(depth++, 280 + s * 90, 10, [100, 100], "linearRGB", spreads[s]);
			// Row 2: VARYING alpha, which is where it gets interesting.
			cell(depth++, 10 + s * 90, 100, [100, 40], "RGB", spreads[s]);
			cell(depth++, 280 + s * 90, 100, [100, 40], "linearRGB", spreads[s]);
		}
	}
}
