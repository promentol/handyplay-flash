// The drawing API's shapes rather than its colours: curves, a fill with
// a hole in it, self-intersection (which is where the even-odd versus
// non-zero question shows), and a scaled stroke.
class Test {
	static function clip(name:String, depth:Number, x:Number, y:Number):MovieClip {
		var mc:MovieClip = _root.createEmptyMovieClip(name, depth);
		mc._x = x;
		mc._y = y;
		return mc;
	}

	static function main() {
		// Quadratic curves closing into a blob.
		var a:MovieClip = clip("curves", 1, 10, 10);
		a.beginFill(0x4477CC);
		a.moveTo(0, 40);
		a.curveTo(0, 0, 40, 0);
		a.curveTo(80, 0, 80, 40);
		a.curveTo(80, 80, 40, 80);
		a.curveTo(0, 80, 0, 40);
		a.endFill();

		// A ring: outer path one way, inner path the OTHER way, which is
		// what makes the middle a hole rather than a second layer.
		var b:MovieClip = clip("ring", 2, 110, 10);
		b.beginFill(0xCC5533);
		b.moveTo(0, 0);
		b.lineTo(80, 0);
		b.lineTo(80, 80);
		b.lineTo(0, 80);
		b.lineTo(0, 0);
		b.moveTo(20, 20);
		b.lineTo(20, 60);
		b.lineTo(60, 60);
		b.lineTo(60, 20);
		b.lineTo(20, 20);
		b.endFill();

		// A five-pointed star drawn in one stroke: the middle is covered
		// twice, so the fill rule decides whether it is filled.
		var c:MovieClip = clip("star", 3, 210, 10);
		c.beginFill(0x33AA66);
		var r1:Number = 40;
		var r2:Number = 16;
		for (var i:Number = 0; i <= 10; i++) {
			var ang:Number = (i * Math.PI / 5) - Math.PI / 2;
			var rad:Number = (i % 2 == 0) ? r1 : r2;
			var px:Number = 40 + Math.cos(ang) * rad;
			var py:Number = 40 + Math.sin(ang) * rad;
			if (i == 0) {
				c.moveTo(px, py);
			} else {
				c.lineTo(px, py);
			}
		}
		c.endFill();
	}
}
