#include "OpusShim.h"

int cocogram_ope_encoder_set_bitrate(OggOpusEnc *encoder, int bitrate) {
    return ope_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}

int cocogram_opus_encoder_set_bitrate(OpusEncoder *encoder, int bitrate) {
    return opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}

int cocogram_opus_encoder_set_complexity(OpusEncoder *encoder, int complexity) {
    return opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(complexity));
}

int cocogram_opus_encoder_set_inband_fec(OpusEncoder *encoder, int enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(enabled));
}

int cocogram_opus_encoder_set_packet_loss_perc(OpusEncoder *encoder, int percent) {
    return opus_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(percent));
}

int cocogram_opus_encoder_set_signal_voice(OpusEncoder *encoder) {
    return opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}

int cocogram_opus_encoder_set_vbr(OpusEncoder *encoder, int enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_VBR(enabled));
}
