#ifndef OPUS_SHIM_H
#define OPUS_SHIM_H

#include <opus/opusenc.h>
#include <opus/opus.h>

// libopusenc (Ogg Opus file) — used for recorded voice messages.
int cocogram_ope_encoder_set_bitrate(OggOpusEnc *encoder, int bitrate);

// Core libopus realtime CTLs — used by the call media engine. The OPUS_SET_* CTLs are variadic
// C macros that can't be called from Swift, so they are wrapped here.
int cocogram_opus_encoder_set_bitrate(OpusEncoder *encoder, int bitrate);
int cocogram_opus_encoder_set_complexity(OpusEncoder *encoder, int complexity);
int cocogram_opus_encoder_set_inband_fec(OpusEncoder *encoder, int enabled);
int cocogram_opus_encoder_set_packet_loss_perc(OpusEncoder *encoder, int percent);
int cocogram_opus_encoder_set_signal_voice(OpusEncoder *encoder);
int cocogram_opus_encoder_set_vbr(OpusEncoder *encoder, int enabled);

#endif
