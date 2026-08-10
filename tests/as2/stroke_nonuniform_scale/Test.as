// A stroke under a NON-UNIFORM scale.
//
// KNOWN DIVERGENCE, and this one is ours. Flash carries the stroke
// through the transform, so a clip scaled 200% across and 60% down
// strokes with an ELLIPTICAL pen — thick horizontally, thin vertically.
// We flatten the path into device space and stroke it with a round pen
// whose diameter is the geometric mean of the two scales, which lays
// down about 30% more ink on a diagonal. Fixing it means stroking in
// local space and transforming the OUTLINE, which is a change to the
// rasteriser rather than to the player.
class Test {
	static function chevron(name:String, depth:Number, x:Number, y:Number,
	                        xs:Number, ys:Number):MovieClip {
		var mc:MovieClip = _root.createEmptyMovieClip(name, depth);
		mc.lineStyle(4, 0x222222, 100, false, "normal", "round", "round", 3);
		mc.moveTo(0, 0);
		mc.lineTo(40, 40);
		mc.lineTo(0, 80);
		mc._x = x;
		mc._y = y;
		mc._xscale = xs;
		mc._yscale = ys;
		return mc;
	}

	static function main() {
		chevron("even", 1, 10, 10, 100, 100);
		chevron("wide", 2, 90, 10, 200, 60);
		chevron("tall", 3, 200, 10, 60, 200);
	}
}
