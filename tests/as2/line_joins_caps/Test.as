// SWF 8 line styles: every cap and join, at a hairline and at a width
// where the join geometry is unmistakable. Two real bugs in our stroker
// were found by eye this way — a join landing on the wrong side, and a
// zero-length closing segment squaring off a round corner — so it is
// worth a standing comparison.
class Test {
	static function chevron(parent:MovieClip, name:String, depth:Number,
	                        x:Number, y:Number, w:Number,
	                        caps:String, joins:String):MovieClip {
		var mc:MovieClip = parent.createEmptyMovieClip(name, depth);
		mc.lineStyle(w, 0x202020, 100, false, "none", caps, joins, 3);
		mc.moveTo(0, 30);
		mc.lineTo(20, 0);
		mc.lineTo(40, 30);
		mc._x = x;
		mc._y = y;
		return mc;
	}

	static function ring(parent:MovieClip, name:String, depth:Number,
	                     x:Number, y:Number, w:Number, joins:String):MovieClip {
		var mc:MovieClip = parent.createEmptyMovieClip(name, depth);
		mc.lineStyle(w, 0x202020, 100, false, "none", "none", joins, 3);
		mc.moveTo(0, 0);
		mc.lineTo(30, 0);
		mc.lineTo(30, 30);
		mc.lineTo(0, 30);
		mc.lineTo(0, 0);
		mc._x = x;
		mc._y = y;
		return mc;
	}

	static function main() {
		var caps:Array = ["none", "round", "square"];
		var joins:Array = ["miter", "round", "bevel"];
		var depth:Number = 1;
		for (var c:Number = 0; c < caps.length; c++) {
			for (var j:Number = 0; j < joins.length; j++) {
				chevron(_root, "thin" + depth, depth++, 10 + j * 60, 10 + c * 50, 1, caps[c], joins[j]);
				chevron(_root, "fat" + depth, depth++, 200 + j * 60, 10 + c * 50, 9, caps[c], joins[j]);
			}
		}
		// Closed rings: the seam where the path meets itself is its own
		// case, and it is where the closing-segment bug hid.
		for (var k:Number = 0; k < joins.length; k++) {
			ring(_root, "ring" + depth, depth++, 15 + k * 60, 165, 1, joins[k]);
			ring(_root, "ringfat" + depth, depth++, 205 + k * 60, 165, 9, joins[k]);
		}
	}
}
