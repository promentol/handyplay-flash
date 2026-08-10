// Masks and blends in the same tree, which is where a renderer that
// treats either as a special case tends to come apart: a blended clip
// UNDER a mask, a mask over a blended group, and a cached clip masked.
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
		box(_root, "sky", 1, 0, 0, 300, 100, 0x88AACC);

		// A multiplied square, masked by a circle-ish square.
		box(_root, "back1", 2, 10, 10, 80, 80, 0xE0B040);
		var tinted:MovieClip = box(_root, "tinted", 3, 20, 20, 60, 60, 0x8040C0);
		tinted.blendMode = "multiply";
		var mask1:MovieClip = box(_root, "mask1", 4, 30, 10, 40, 80, 0x000000);
		tinted.setMask(mask1);

		// A blended GROUP under a mask: the mask must apply to the
		// composited group, not to each child before compositing.
		box(_root, "back2", 5, 110, 10, 80, 80, 0xE0B040);
		var group:MovieClip = _root.createEmptyMovieClip("group", 6);
		box(group, "g1", 1, 115, 20, 40, 60, 0xFF4040);
		box(group, "g2", 2, 145, 20, 40, 60, 0x40FF40);
		group.blendMode = "multiply";
		var mask2:MovieClip = box(_root, "mask2", 7, 120, 30, 60, 40, 0x000000);
		group.setMask(mask2);

		// A cached clip, masked.
		box(_root, "back3", 8, 210, 10, 80, 80, 0xE0B040);
		var cached:MovieClip = box(_root, "cached", 9, 220, 20, 60, 60, 0x2050A0);
		cached.cacheAsBitmap = true;
		var mask3:MovieClip = box(_root, "mask3", 10, 230, 30, 40, 40, 0x000000);
		cached.setMask(mask3);
	}
}
