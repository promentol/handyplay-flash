// LIBRARY ASSETS: symbols that exist as tags before a line of code runs.
//
// mtasc cannot make these — a movie it builds from scratch has no shapes
// and no images. `template.swf` comes from swfmill (see assets.xml), and
// mtasc's `-swf` mode injects these classes into it, which is the way
// AS2 was actually built. The code then reaches the artwork by its
// LINKAGE NAME rather than drawing it.
class Test {
	static function main() {
		// Four copies of one library symbol, transformed differently, to
		// show the bitmap survives scaling and rotation.
		for (var i:Number = 0; i < 4; i++) {
			var mc:MovieClip = _root.attachMovie("Logo", "logo" + i, 10 + i);
			mc._x = 20 + i * 76;
			mc._y = 20;
			var s:Number = 100 + i * 55;
			mc._xscale = s;
			mc._yscale = s;
			mc._rotation = i * 12;
		}

		// The same symbol under a blend mode, over the others.
		var over:MovieClip = _root.attachMovie("Logo", "over", 30);
		over._x = 150;
		over._y = 60;
		over._xscale = 220;
		over._yscale = 220;
		over.blendMode = "screen";

		trace("attached: " + _root.logo0._name + " " + _root.logo3._width);
	}
}
