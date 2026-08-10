// `alpha` and `erase` against the ROOT, which is not a layer.
//
// These two modes change the DESTINATION's alpha and leave its colour
// alone, so they need a layer to act on. The stage is not one — it is
// opaque, and Flash will not make a movie see-through — so both should
// do nothing at all: the yellow boxes stay whole and the white squares
// are not drawn. The reference agrees. We used to punch holes here.
class Test {
	static function box(parent:MovieClip, name:String, depth:Number,
	                    x:Number, y:Number, w:Number, h:Number,
	                    colour:Number):MovieClip {
		var mc:MovieClip = parent.createEmptyMovieClip(name, depth);
		mc.beginFill(colour);
		mc.moveTo(0, 0);
		mc.lineTo(w, 0);
		mc.lineTo(w, h);
		mc.lineTo(0, h);
		mc.endFill();
		mc._x = x;
		mc._y = y;
		return mc;
	}

	static function main() {
		// A backdrop across the whole stage so a hole is obvious.
		box(_root, "sky", 1, 0, 0, 130, 130, 0x2E5FA3);

		// Not in a layer: per Adobe these should do nothing at all.
		box(_root, "plainBack", 2, 10, 10, 100, 50, 0xE8C34A);
		var bare:MovieClip = box(_root, "bare", 3, 30, 25, 60, 30, 0xFFFFFF);
		bare.blendMode = "erase";

		box(_root, "plainBack2", 4, 10, 70, 100, 50, 0xE8C34A);
		var bare2:MovieClip = box(_root, "bare2", 5, 30, 85, 60, 30, 0xFFFFFF);
		bare2.blendMode = "alpha";
	}
}
