// Matrices down a tree: rotation, skew from a raw matrix, and scale that
// compounds. Flat colours, so any disagreement is geometry, not shading.
class Test {
	static function box(parent:MovieClip, name:String, depth:Number,
	                    w:Number, h:Number, colour:Number):MovieClip {
		var mc:MovieClip = parent.createEmptyMovieClip(name, depth);
		mc.beginFill(colour);
		mc.moveTo(0, 0);
		mc.lineTo(w, 0);
		mc.lineTo(w, h);
		mc.lineTo(0, h);
		mc.endFill();
		return mc;
	}

	static function main() {
		// Rotation about the clip's own origin.
		var a:MovieClip = box(_root, "rot", 1, 50, 30, 0x3366BB);
		a._x = 60;
		a._y = 50;
		a._rotation = 30;

		// Rotation INSIDE a scaled parent: the parent's scale applies
		// after the child's rotation, which is why this is not the same
		// shape as rotating a pre-scaled box.
		var p:MovieClip = _root.createEmptyMovieClip("parent", 2);
		p._x = 160;
		p._y = 50;
		p._xscale = 180;
		p._yscale = 70;
		var b:MovieClip = box(p, "child", 1, 50, 30, 0xBB3366);
		b._rotation = 30;

		// A skew, which the property surface cannot express: straight
		// through the transform matrix.
		var c:MovieClip = box(_root, "skew", 3, 50, 30, 0x33AA66);
		var m:Object = c.transform.matrix;
		m.a = 1;
		m.b = 0.35;
		m.c = 0.6;
		m.d = 1;
		m.tx = 280;
		m.ty = 40;
		c.transform.matrix = m;

		// Deep nesting: three levels, each contributing.
		var l1:MovieClip = _root.createEmptyMovieClip("l1", 4);
		l1._x = 380;
		l1._y = 20;
		l1._rotation = 10;
		var l2:MovieClip = l1.createEmptyMovieClip("l2", 1);
		l2._xscale = 120;
		l2._rotation = 15;
		box(l2, "leaf", 1, 40, 40, 0xDDAA22);
	}
}
