// A BitmapData built pixel by pixel, then used three ways: attached to
// the display list, tiled into a fill, and drawn scaled with smoothing
// on and off. The nearest-neighbour cases are the strict ones — any
// sampling disagreement shows as whole wrong pixels.
class Test {
	static function checker(w:Number, h:Number):flash.display.BitmapData {
		var bd:flash.display.BitmapData = new flash.display.BitmapData(w, h, true, 0x00000000);
		for (var y:Number = 0; y < h; y++) {
			for (var x:Number = 0; x < w; x++) {
				var light:Boolean = ((x + y) % 2) == 0;
				bd.setPixel32(x, y, light ? 0xFFCC3344 : 0xFF3344CC);
			}
		}
		return bd;
	}

	static function main() {
		var bd:flash.display.BitmapData = checker(8, 8);

		// Attached straight to the display list, unscaled.
		var a:MovieClip = _root.createEmptyMovieClip("plain", 1);
		a.attachBitmap(bd, 1);
		a._x = 10;
		a._y = 10;

		// The same, scaled up hard with smoothing OFF: every source texel
		// becomes an 8x8 block and the edges must land on whole pixels.
		var b:MovieClip = _root.createEmptyMovieClip("blocky", 2);
		b.attachBitmap(bd, 1, "auto", false);
		b._x = 30;
		b._y = 10;
		b._xscale = 800;
		b._yscale = 800;

		// Tiled into a drawn shape.
		var c:MovieClip = _root.createEmptyMovieClip("tiled", 3);
		c.beginBitmapFill(bd, null, true, false);
		c.moveTo(0, 0);
		c.lineTo(80, 0);
		c.lineTo(80, 74);
		c.lineTo(0, 74);
		c.endFill();
		c._x = 110;
		c._y = 10;

		// Tiled with a matrix that scales and rotates the texture.
		var d:MovieClip = _root.createEmptyMovieClip("skewed", 4);
		var m:Object = {matrixType: "box", x: 0, y: 0, w: 24, h: 24, r: 0.4};
		d.beginBitmapFill(bd, m, true, false);
		d.moveTo(0, 0);
		d.lineTo(80, 0);
		d.lineTo(80, 74);
		d.lineTo(0, 74);
		d.endFill();
		d._x = 200;
		d._y = 10;
	}
}
