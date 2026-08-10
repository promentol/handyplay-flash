// Colour transforms, which multiply and then add per channel, and stack
// down the tree. `_alpha` is the same machinery wearing a hat.
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

	static function tint(mc:MovieClip, ra:Number, rb:Number, ga:Number, gb:Number,
	                     ba:Number, bb:Number, aa:Number) {
		var c:Color = new Color(mc);
		c.setTransform({ra: ra, rb: rb, ga: ga, gb: gb, ba: ba, bb: bb, aa: aa, ab: 0});
	}

	static function main() {
		box(_root, "sky", 1, 0, 0, 400, 100, 0xFFFFFF);
		// A row of the same orange square under different transforms.
		var base:Number = 0xF07028;
		tint(box(_root, "plain", 2, 10, 10, 60, 80, base), 100, 0, 100, 0, 100, 0, 100);
		tint(box(_root, "half", 3, 80, 10, 60, 80, base), 50, 0, 50, 0, 50, 0, 100);
		tint(box(_root, "lift", 4, 150, 10, 60, 80, base), 100, 60, 100, 60, 100, 60, 100);
		tint(box(_root, "swap", 5, 220, 10, 60, 80, base), 0, 255, 100, 0, 0, 0, 100);
		var faded:MovieClip = box(_root, "faded", 6, 290, 10, 60, 80, base);
		faded._alpha = 40;

		// Nesting: the child's transform composes with the parent's, and
		// the ORDER of multiply-then-add is what makes it not commute.
		var outer:MovieClip = _root.createEmptyMovieClip("outer", 7);
		tint(outer, 50, 0, 50, 0, 50, 0, 100);
		var inner:MovieClip = box(outer, "inner", 1, 360, 10, 30, 80, 0xFFFFFF);
		tint(inner, 100, 100, 100, 0, 100, 0, 100);
	}
}
