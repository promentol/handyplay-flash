// The string and number surface AVM1 scripts actually lean on, and the
// conversions that decide what a trace even prints.
class Test {
	static function line(label, v) {
		trace(label + " = " + v);
	}

	static function dyn(v) {
		return v;
	}

	static function main() {
		// Number formatting is the thing most likely to drift, because
		// Flash's rules are neither printf's nor JavaScript's.
		var probes:Array = [0, -1, 0.5, -0.5, 100000, 1000000000000000000000.0,
		                    0.00001, 0.000001, 123456789.123456789,
		                    1.7976931348623157e308, 5e-324];
		for (var i:Number = 0; i < probes.length; i++) {
			trace("num[" + i + "] " + probes[i]);
		}
		line("toString 16", dyn(255).toString(16));
		line("toString 2", dyn(5).toString(2));
		line("toFixed", dyn(1.005).toFixed(2));
		line("parseInt hex", parseInt("0xFF"));
		line("parseInt radix", parseInt("z", 36));
		line("parseFloat", parseFloat("3.14abc"));
		line("parseInt empty", parseInt(""));

		// String methods, including the negative-index cases that differ
		// between substr, substring and slice.
		var s:String = "Hello, world";
		line("length", s.length);
		line("substr", s.substr(7));
		line("substr neg", s.substr(-5));
		line("substring swapped", s.substring(9, 4));
		line("slice neg", s.slice(-5, -1));
		line("charAt oob", "[" + s.charAt(99) + "]");
		line("charCodeAt oob", s.charCodeAt(99));
		line("indexOf missing", s.indexOf("zzz"));
		line("split limit", s.split("", 3).join("|"));
		line("concat", s.concat("!", "!"));
		line("chr", String.fromCharCode(65, 66, 67));

		// Where a string meets a number.
		line("num plus str", dyn(5) + dyn("5"));
		line("str times", dyn("5") * dyn("2"));
		line("str compare", dyn("10") < dyn("9"));
		line("num compare", dyn(10) < dyn(9));
		line("empty compare", dyn("") == dyn(0));
	}
}
