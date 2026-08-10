// Objects, prototypes, functions and the loose ends AVM1 has around
// them: `arguments`, `call`/`apply`, constructor chains and enumeration
// order, which a player has to get right for real content to work.
class Test {
	static function line(label, v) {
		trace(label + " = " + v);
	}

	static function main() {
		// Enumeration walks own properties NEWEST FIRST in AVM1.
		var o = {};
		o.first = 1;
		o.second = 2;
		o.third = 3;
		var seen:String = "";
		for (var k in o) {
			seen += k + ",";
		}
		line("for-in order", seen);

		// delete, and what survives it.
		delete o.second;
		seen = "";
		for (var k2 in o) {
			seen += k2 + ",";
		}
		line("after delete", seen);
		line("delete missing", delete o.nope);

		// Prototype chains built the old way.
		var Animal = function (name) {
			this.name = name;
		};
		Animal.prototype.speak = function () {
			return this.name + " makes a sound";
		};
		var Dog = function (name) {
			this.name = name;
		};
		Dog.prototype = new Animal("proto");
		Dog.prototype.speak = function () {
			return this.name + " barks";
		};
		var d = new Dog("Rex");
		line("own method", d.speak());
		line("instanceof", d instanceof Animal);
		line("constructor name", typeof(d.constructor));

		// Functions: arguments, call, apply.
		var f = function () {
			return arguments.length + ":" + arguments[0] + "," + arguments[1];
		};
		line("arguments", f(10, 20, 30));
		var g = function (a, b) {
			return this.tag + " " + a + b;
		};
		line("call", g.call({tag: "T"}, 1, 2));
		line("apply", g.apply({tag: "U"}, [3, 4]));

		// The odd corners.
		line("typeof array", typeof([]));
		line("array to string", String([1, [2, 3], 4]));
		line("object to string", String({}));
		line("null to string", String(null));
		line("nested access", ({a: {b: {c: 7}}}).a.b.c);
	}
}
