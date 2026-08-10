// A trace-only regression net for the interpreter, in the areas this
// project has actually been bitten in: numeric coercion at the edges,
// array index wrapping, prototype and scope lookup, and the string
// conversions that decide what a trace even says.
class Test {
	static function line(label, v) {
		trace(label + " = " + v);
	}

	// mtasc type-checks arithmetic, and half the point of these lines is
	// what AVM1 does when the operands do NOT agree. Laundering an
	// operand through an untyped function is how the source says "I mean
	// it" to the compiler without changing what runs.
	static function dyn(v) {
		return v;
	}

	static function main() {
		// Numbers to strings: the rule is not printf's.
		line("int", 1);
		line("intish float", 1.0);
		line("third", 1 / 3);
		line("big", 1e21);
		line("small", 1e-7);
		line("neg zero", -0);
		line("inf", 1 / 0);
		line("nan", 0 / 0);

		// Coercion.
		line("empty to num", Number(""));
		line("space to num", Number("  "));
		line("hex string", Number("0x10"));
		line("trailing junk", Number("12abc"));
		line("bool add", dyn(true) + dyn(true));
		line("null add", dyn(null) + 1);
		line("undef add", dyn(undefined) + 1);
		line("str concat", 1 + "1");
		line("str minus", dyn("3") - 1);

		// Arrays: the index is an i32 that WRAPS, which is why a huge
		// numeric key is not the length it looks like.
		var a = [];
		a[0] = "zero";
		a[4294967295] = "wrap";
		line("len after wrap", a.length);
		a["2147483648"] = "neg";
		line("len after neg", a.length);
		var b = [3, 1, 2];
		b.sort();
		line("sorted", b.join(","));
		line("slice", [1, 2, 3, 4].slice(1, 3).join(","));
		line("splice", spliced());

		// Objects, prototypes and `this`.
		var o = {x: 1};
		o.__proto__ = {y: 2};
		line("own", o.x);
		line("inherited", o.y);
		line("hasOwn", o.hasOwnProperty("y"));
		line("typeof fn", typeof(Test.main));
		line("typeof undef", typeof(o.nope));

		// String surface.
		line("substr neg", "abcdef".substr(-2, 1));
		line("slice neg", "abcdef".slice(-3));
		line("indexOf", "abcabc".lastIndexOf("b"));
		line("charCode", "A".charCodeAt(0));
		line("split empty", "abc".split("").join("|"));
		line("toUpper", "MiXeD".toUpperCase());

		// The equality table, which is where AVM1 differs from AS3.
		line("eq undef null", dyn(undefined) == dyn(null));
		line("eq str num", dyn("1") == dyn(1));
		line("eq empty zero", dyn("") == dyn(0));
		line("strict eq", 1 === 1);
	}

	static function spliced() {
		var s = [1, 2, 3, 4, 5];
		s.splice(1, 2, "a");
		return s.join(",");
	}
}
