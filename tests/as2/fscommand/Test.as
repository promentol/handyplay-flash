// `fscommand`, the half of the device seam that a compiler CAN emit.
//
// It is not an opcode: `fscommand("cmd", "args")` is a `getURL` whose URL
// is `FSCommand:cmd` and whose target is the single argument. That makes
// it the one half of this feature ruffle can be a reference for — it
// forwards the call to its host and returns nothing, exactly as we do.
//
// What this case is really measuring is SILENCE. Every one of the 679
// movies in ruffle's own conformance corpus ends with `fscommand("quit")`,
// so a player that traced its device commands, or acted on one in the
// core, would be caught here first and in all 679 second.
class Test {
	static function main() {
		trace("before");

		// The classic desktop four. None of them may produce output, and
		// none of them may stop the movie.
		fscommand("allowscale", "false");
		fscommand("showmenu", "false");
		fscommand("trapallkeys", "true");
		fscommand("exec", "notepad.exe");
		trace("after the desktop set");

		// A Flash Lite name reached through plain `fscommand`. There is no
		// return value on this path, so the answer is dropped — the point
		// is that the call is harmless, not that it reports.
		fscommand("SetSoftKeys", "Left");
		fscommand("GetBatteryLevel");
		trace("after the lite names");

		// The raw shape, written out. Both spellings of the scheme are
		// recognised, and neither may navigate anywhere.
		getURL("FSCommand:custom", "an argument");
		getURL("fscommand:lowercase", "");
		_root.getURL("FSCommand:viaClip", "clip argument");
		trace("after the raw form");

		// The idiom every corpus movie ends on.
		fscommand("quit");
		trace("still running after quit");
	}
}
