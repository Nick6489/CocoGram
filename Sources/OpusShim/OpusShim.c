#include "OpusShim.h"

int cocogram_ope_encoder_set_bitrate(OggOpusEnc *encoder, int bitrate) {
    return ope_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}
