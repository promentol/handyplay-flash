// Every PlaceObject3 blend mode, one cell each, over a shared backdrop.
//
// Nothing in ruffle's corpus places an object with a blend mode, so this
// is the first side-by-side check of workstream F. Each cell draws a
// steel-blue square and an orange one over it; the orange square hangs
// past the blue on two sides so a mode's effect against the WHITE PAGE
// shows as well as its effect against the backdrop.
class Test {
	static var MODES:Array = ["normal", "layer", "multiply", "screen", "lighten",
	                    "darken", "difference", "add", "subtract", "invert",
	                    "alpha", "erase", "overlay", "hardlight"];

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
		var cell:Number = 80;
		var cols:Number = 7;
		for (var i:Number = 0; i < MODES.length; i++) {
			var cx:Number = (i % cols) * cell + 4;
			var cy:Number = Math.floor(i / cols) * cell + 4;
			box(_root, "back" + i, i * 2 + 1, cx, cy, 60, 60, 0x3C6EB4);
			var top:MovieClip = box(_root, "top" + i, i * 2 + 2, cx + 12, cy + 12, 60, 60, 0xF59628);
			top.blendMode = MODES[i];
		}
	}
}
