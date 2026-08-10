// `cacheAsBitmap` draws through an offscreen layer whose origin is a
// WHOLE pixel, so a cached object loses sub-pixel positioning. The two
// rows here are identical except for the flag, and both sit at x.5, so
// the cached row should snap and the uncached one should not.
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
		for (var i:Number = 0; i < 5; i++) {
			var off:Number = i * 0.25;
			box(_root, "plain" + i, i + 1, 10 + i * 36 + off, 10.5, 24, 24, 0x2E5FA3);
			var cached:MovieClip = box(_root, "cached" + i, i + 21, 10 + i * 36 + off, 60.5, 24, 24, 0xC24E2A);
			cached.cacheAsBitmap = true;
		}
	}
}
