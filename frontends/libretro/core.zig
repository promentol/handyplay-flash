//! M5: retro_* implementation. need_fullpath=false; NO BIOS; av_info from the
//! SWF header (fps + stage size); XRGB8888; serialize_size latched + headroom,
//! tail zeroed; RetroPad edge-triggered keymap; RETRO_DEVICE_POINTER later;
//! audio batch at END of retro_run (AUDIO_FRAMES = 44100/fps).
