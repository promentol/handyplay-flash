//! M3: Action enum for all ~100 opcodes (0x00-0x9F) + operand decoding.
//! Actions >= 0x80 carry u16le length. Push typed values: 0=string 1=f32 2=null
//! 3=undefined 4=register 5=bool 6=f64(byte-swapped 45670123!) 7=i32 8/9=constant pool.
