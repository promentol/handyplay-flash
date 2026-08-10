// The MovieClip surface a script actually touches: creating and naming
// clips, depths, the coordinate conversions, bounds, and hit tests. All
// traced, so this is about the numbers rather than the pixels.
class Test {
	static function line(label, v) {
		trace(label + " = " + v);
	}

	static function box(parent:MovieClip, name:String, depth:Number,
	                    x:Number, y:Number, w:Number, h:Number):MovieClip {
		var mc:MovieClip = parent.createEmptyMovieClip(name, depth);
		mc.beginFill(0x808080);
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
		var a:MovieClip = box(_root, "a", 5, 10, 20, 40, 30);
		line("name", a._name);
		line("target", a._target);
		line("depth", a.getDepth());
		line("parent is root", a._parent == _root);
		line("x/y", a._x + "," + a._y);
		line("w/h", a._width + "," + a._height);

		// Bounds in two spaces.
		var b1:Object = a.getBounds(_root);
		line("bounds root", b1.xMin + "," + b1.yMin + "," + b1.xMax + "," + b1.yMax);
		var b2:Object = a.getBounds(a);
		line("bounds self", b2.xMin + "," + b2.yMin + "," + b2.xMax + "," + b2.yMax);

		// Coordinate conversion, both directions.
		var p:Object = {x: 5, y: 5};
		a.localToGlobal(p);
		line("localToGlobal", p.x + "," + p.y);
		a.globalToLocal(p);
		line("globalToLocal", p.x + "," + p.y);

		// Hit tests: a point inside, a point outside, and clip to clip.
		line("hit inside", a.hitTest(20, 30, true));
		line("hit outside", a.hitTest(200, 200, true));
		var c:MovieClip = box(_root, "c", 6, 30, 30, 40, 30);
		line("hit clip", a.hitTest(c));

		// Depth management.
		line("next depth", _root.getNextHighestDepth());
		a.swapDepths(c);
		line("after swap a", a.getDepth());
		line("after swap c", c.getDepth());
		line("instance at 6", _root.getInstanceAtDepth(6)._name);

		// Rotation feeds back through the matrix and out again.
		a._rotation = 45;
		line("rotation", a._rotation);
		line("rotated w", Math.round(a._width));
		a._rotation = 400;
		line("wrapped rotation", a._rotation);

		// Removal, and what is left behind.
		c.removeMovieClip();
		line("removed lookup", typeof(_root.c));
		line("root depth", _root.getDepth());
	}
}
