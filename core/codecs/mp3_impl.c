/* Single-TU implementation of the vendored minimp3 (../../vendor/minimp3)
 * plus a flat decode-whole-clip shim, so the Zig side (core/codecs/mp3.zig)
 * never sees a C struct layout.
 *
 * Whole-clip decode is the right shape for SWF: a DefineSound is tens of
 * KB of MP3 and the mixer wants a plain PCM buffer it can resample from.
 * The frame-by-frame path (hf_mp3_stream_*) exists for SoundStreamBlocks,
 * which arrive one frame at a time and must not wait for an end of file
 * that never comes.
 *
 * Compiled only with -Dmp3=true (the default) — see build.zig. */
#define MINIMP3_IMPLEMENTATION
#include "minimp3_ex.h"
#include <stdlib.h>
#include <string.h>

/* Decode an entire MP3 clip to interleaved s16 PCM. Returns 0 on success
 * and hands over a malloc'd buffer (plain free() releases it).
 * out_samples counts individual samples, channels included. */
int hf_mp3_decode(const unsigned char *buf, size_t len,
                  short **out_pcm, size_t *out_samples,
                  int *out_channels, int *out_hz)
{
    mp3dec_t dec;
    mp3dec_file_info_t info;
    if (mp3dec_load_buf(&dec, buf, len, &info, NULL, NULL))
        return -1;
    if (!info.buffer || !info.samples || info.channels < 1 || info.hz < 1) {
        free(info.buffer);
        return -1;
    }
    *out_pcm = info.buffer;
    *out_samples = info.samples;
    *out_channels = info.channels;
    *out_hz = info.hz;
    return 0;
}

void hf_mp3_free(short *pcm)
{
    free(pcm);
}

/* --- the streaming half ---------------------------------------------------
 *
 * One decoder that keeps its bit-reservoir across calls, because an MP3
 * frame may reference bytes from the frame before it. A SoundStreamBlock
 * is fed in whole and however many complete frames it yields come out;
 * whatever is left over is the caller's to re-present next time. */

size_t hf_mp3_state_size(void)
{
    return sizeof(mp3dec_t);
}

void hf_mp3_state_init(void *state)
{
    mp3dec_init((mp3dec_t *)state);
}

/* Decode ONE frame from `buf`. Writes up to 1152*2 samples into `pcm`.
 * Returns the number of bytes consumed (0 when there is not enough data
 * for a whole frame), and sets *out_samples to the per-channel sample
 * count — which is 0 for a frame that was only a header (minimp3 skips
 * ID3 and garbage that way, and consumed > 0 still means progress). */
int hf_mp3_decode_frame(void *state, const unsigned char *buf, size_t len,
                        short *pcm, int *out_samples,
                        int *out_channels, int *out_hz)
{
    mp3dec_frame_info_t info;
    int samples = mp3dec_decode_frame((mp3dec_t *)state, buf, (int)len, pcm, &info);
    *out_samples = samples;
    *out_channels = info.channels;
    *out_hz = info.hz;
    return info.frame_bytes;
}
