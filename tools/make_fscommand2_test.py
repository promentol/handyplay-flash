#!/usr/bin/env python3
"""Write the SWF behind tests/as2/fscommand2.

    python3 tools/make_fscommand2_test.py            # -> tests/as2/fscommand2/test.swf

WHY A GENERATOR AND NOT ActionScript: `fscommand2` is opcode 0x2D, a
Flash Lite instruction. mtasc will not emit it, ruffle does not have it in
its opcode table, and no compiler this project can run produces one — so
the only way to exercise the instruction is to write the bytes.

That also means the expectation is OURS. Every other case under
tests/as2 is checked against ruffle's wasm; this one has no second
opinion, and its expected.txt was reviewed against Adobe's documented
semantics for each command (docs/FLASH-LITE.md) rather than measured.

The stack shape is the one the shipped games use, confirmed by
disassembling them: a Push carrying `[argN-1 … arg0, name, count]`, then
FSCommand2, which leaves the answer on the stack. The count INCLUDES the
name, so `SetSoftKeys("Left","Right")` counts 3.
"""
import os
import struct

# --- a very small AVM1 assembler ------------------------------------------

TRACE = 0x26
POP = 0x17
GET_VARIABLE = 0x1C
ADD2 = 0x47
FS_COMMAND2 = 0x2D
PUSH = 0x96


def push(*values):
    """Push (0x96). Strings become type 0, ints type 7, in order given."""
    payload = bytearray()
    for v in values:
        if isinstance(v, str):
            payload.append(0)
            payload += v.encode("utf-8") + b"\x00"
        else:
            payload.append(7)
            payload += struct.pack("<i", v)
    return bytes([PUSH]) + struct.pack("<H", len(payload)) + bytes(payload)


def call(name, *args):
    """One `fscommand2`, leaving its answer on the stack."""
    return push(*reversed(args), name, len(args) + 1) + bytes([FS_COMMAND2])


def trace_call(label, name, *args):
    """`trace(label + fscommand2(name, args...))`."""
    return push(label) + call(name, *args) + bytes([ADD2, TRACE])


def trace_var(label, var):
    """`trace(label + var)` — for the commands that answer INTO a variable."""
    return push(label, var) + bytes([GET_VARIABLE, ADD2, TRACE])


def trace_str(text):
    return push(text) + bytes([TRACE])


# --- the movie -------------------------------------------------------------

def actions():
    a = bytearray()

    a += trace_str("-- numbers the handset knows about itself")
    for name in (
        "GetBatteryLevel",
        "GetMaxBatteryLevel",
        "GetSignalLevel",
        "GetMaxSignalLevel",
        "GetVolumeLevel",
        "GetMaxVolumeLevel",
        "GetPowerSource",
        "GetTotalPlayerMemory",
        "GetFreePlayerMemory",
        "GetTotalObjectMemory",
        "GetFreeObjectMemory",
        "GetNetworkConnectStatus",
        "GetNetworkRequestStatus",
        "GetNetworkStatus",
        "GetSoftKeyLocation",
        "GetTimeZoneOffset",
    ):
        a += trace_call(name + " = ", name)

    # The clock. Deterministic here only because the trace runner starts
    # every movie on the same mock epoch; run this under a real player and
    # these lines move.
    a += trace_str("-- the clock")
    for name in (
        "GetDateYear",
        "GetDateMonth",
        "GetDateDay",
        "GetDateWeekday",
        "GetTimeHours",
        "GetTimeMinutes",
        "GetTimeSeconds",
    ):
        a += trace_call(name + " = ", name)

    # A string getter names the VARIABLE its answer goes into and returns
    # 0 — the one shape in this instruction that is not a return value.
    a += trace_str("-- strings, written into the variable named by arg 0")
    for name, var in (
        ("GetDevice", "dev"),
        ("GetDeviceID", "devid"),
        ("GetPlatform", "plat"),
        ("GetLanguage", "lang"),
        ("GetNetworkName", "net"),
        ("GetNetworkConnectionName", "conn"),
        ("GetNetworkGeneration", "gen"),
        ("GetLocaleLongDate", "longdate"),
        ("GetLocaleShortDate", "shortdate"),
        ("GetLocaleTime", "loctime"),
    ):
        a += trace_call(name + " returns ", name, var)
        a += trace_var(name + " wrote ", var)

    # A string getter with NOWHERE to put its answer still succeeded.
    a += trace_call("GetDevice with no variable = ", "GetDevice")

    a += trace_str("-- actions")
    a += trace_call("SetQuality = ", "SetQuality", "high")
    a += trace_call("SetSoftKeys = ", "SetSoftKeys", "Left", "Right")
    a += trace_call("ResetSoftKeys = ", "ResetSoftKeys")
    a += trace_call("StartVibrate = ", "StartVibrate", "1000", "500", "3")
    a += trace_call("StopVibrate = ", "StopVibrate")
    a += trace_call("FullScreen = ", "FullScreen", "true")
    a += trace_call("Escape = ", "Escape", "true")
    a += trace_call("SetInputTextType = ", "SetInputTextType", "_root.field", "NUMERIC")
    a += trace_call("SetFocusRectColor = ", "SetFocusRectColor", "255", "0", "0")
    a += trace_call("ExtendBacklightDuration = ", "ExtendBacklightDuration", "12")

    # Names fold case: the games contain both spellings of this one.
    a += trace_str("-- the name is matched case-insensitively")
    a += trace_call("setsoftkeys = ", "setsoftkeys", "a", "b")
    a += trace_call("GETBATTERYLEVEL = ", "GETBATTERYLEVEL")

    a += trace_str("-- and what nothing recognises")
    a += trace_call("NoSuchCommand = ", "NoSuchCommand")
    a += trace_call("NoSuchCommand with args = ", "NoSuchCommand", "x", "y")
    # Count 0: not even a name. Answers -1 and leaves the stack below it
    # alone, which is what the label pushed first proves.
    a += push("empty call = ") + push(0) + bytes([FS_COMMAND2, ADD2, TRACE])

    # Quit is the whole reason this file exists twice over: it must NOT
    # stop the movie. The core only reports it; the player decides, and
    # the trace runner decides no.
    a += trace_call("Quit = ", "Quit")
    a += trace_str("still running after Quit")

    a.append(0)  # End of actions
    return bytes(a)


def tag(code, body):
    if len(body) < 0x3F:
        return struct.pack("<H", (code << 6) | len(body)) + body
    return struct.pack("<HI", (code << 6) | 0x3F, len(body)) + body


def rect(xmax_twips, ymax_twips):
    # 5-bit size then four fields; 15 bits holds 200x150 px in twips.
    nb = 15
    bits = "".join(
        format(v & 0x7FFF, "015b") for v in (0, xmax_twips, 0, ymax_twips)
    )
    bits = format(nb, "05b") + bits
    bits += "0" * (-len(bits) % 8)
    return bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))


def main():
    body = rect(200 * 20, 150 * 20)
    body += struct.pack("<HH", 30 << 8, 1)  # 30 fps, 1 frame
    body += tag(12, actions())              # DoAction
    body += tag(1, b"")                     # ShowFrame
    body += tag(0, b"")                     # End
    swf = b"FWS" + bytes([7]) + struct.pack("<I", 8 + len(body)) + body

    out = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "tests", "as2", "fscommand2", "test.swf",
    )
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(swf)
    print(f"{os.path.normpath(out)}: {len(swf)} bytes")


if __name__ == "__main__":
    main()
