// A blended clip composites as a WHOLE, not child by child.
//
// The distinction workstream F exists for. `group` holds a red square
// and a green one over it, and is multiplied against a grey backdrop.
// Inside the overlap the layer holds GREEN — the red is already covered
// — so the answer is grey x green. Multiplying each child against the
// backdrop in turn would multiply twice and give black.
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
		box(_root, "backdrop", 1, 0, 0, 200, 100, 0x808080);
		var group:MovieClip = _root.createEmptyMovieClip("group", 2);
		box(group, "red", 1, 20, 20, 80, 60, 0xFF0000);
		box(group, "green", 2, 60, 20, 80, 60, 0x00FF00);
		group.blendMode = "multiply";
	}
}
