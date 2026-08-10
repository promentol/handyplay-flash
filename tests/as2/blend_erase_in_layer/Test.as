// `alpha` and `erase` INSIDE a parent whose blendMode is "layer" — the
// arrangement in which they are supposed to work.
//
// KNOWN DIVERGENCE, and we believe ours is the right one. Erasing a
// 60x30 square out of a 100x50 box should leave the box with a hole in
// it; the reference instead drops the WHOLE box, which would make
// `erase` useless for the thing it exists for. Everything else here —
// the hole itself, and both `alpha` cells — agrees to the pixel.
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
		box(_root, "sky", 1, 0, 0, 130, 130, 0x2E5FA3);

		var layer:MovieClip = _root.createEmptyMovieClip("layer", 2);
		layer.blendMode = "layer";
		box(layer, "inBack", 1, 10, 10, 100, 50, 0xE8C34A);
		var eraser:MovieClip = box(layer, "eraser", 2, 30, 25, 60, 30, 0xFFFFFF);
		eraser.blendMode = "erase";

		var layer2:MovieClip = _root.createEmptyMovieClip("layer2", 3);
		layer2.blendMode = "layer";
		box(layer2, "inBack2", 1, 10, 70, 100, 50, 0xE8C34A);
		var alphaer:MovieClip = box(layer2, "alphaer", 2, 30, 85, 60, 30, 0xFFFFFF);
		alphaer.blendMode = "alpha";
	}
}
