//! M5: HFS0 TLV container (ADR D5) — magic, u32 version, [tag][len][bytes]
//! sections (SWFH movie hash, DISP, AVM1 object table, TIMR, RAND, INPT).
//! SharedObject/LSO EXCLUDED: rewind must not un-write persistence.
