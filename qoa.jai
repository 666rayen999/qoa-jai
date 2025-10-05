#module_parameters (QOA_PLAY := true);

#scope_file

#import "Basic";

QOA_MAGIC : u32 : 0x716f6166; // qoaf

QOA_FRAME_SIZE :: (channels: u32, slices: u32) -> u32 { return (channels << 4) + ((slices * channels) << 3) + 8; }

quant_tab      : [17]s32 : .[ 7, 7, 7, 5, 5, 3, 3, 1, 0, 0, 2, 2, 4, 4, 6, 6, 6 ];
reciprocal_tab : [16]s32 : .[ 65536, 9363, 3121, 1457, 781, 475, 311, 216, 156, 117, 90, 71, 57, 47, 39, 32 ];
dequant_tab : [16][8]s32 : .[
    .[    1,    -1,    3,    -3,    5,    -5,     7,     -7 ],
    .[    5,    -5,   18,   -18,   32,   -32,    49,    -49 ],
    .[   16,   -16,   53,   -53,   95,   -95,   147,   -147 ],
    .[   34,   -34,  113,  -113,  203,  -203,   315,   -315 ],
    .[   63,   -63,  210,  -210,  378,  -378,   588,   -588 ],
    .[  104,  -104,  345,  -345,  621,  -621,   966,   -966 ],
    .[  158,  -158,  528,  -528,  950,  -950,  1477,  -1477 ],
    .[  228,  -228,  760,  -760, 1368, -1368,  2128,  -2128 ],
    .[  316,  -316, 1053, -1053, 1895, -1895,  2947,  -2947 ],
    .[  422,  -422, 1405, -1405, 2529, -2529,  3934,  -3934 ],
    .[  548,  -548, 1828, -1828, 3290, -3290,  5117,  -5117 ],
    .[  696,  -696, 2320, -2320, 4176, -4176,  6496,  -6496 ],
    .[  868,  -868, 2893, -2893, 5207, -5207,  8099,  -8099 ],
    .[ 1064, -1064, 3548, -3548, 6386, -6386,  9933,  -9933 ],
    .[ 1286, -1286, 4288, -4288, 7718, -7718, 12005, -12005 ],
    .[ 1536, -1536, 5120, -5120, 9216, -9216, 14336, -14336 ],
];

predict :: inline (lms: *Qoa_Lms) -> s32 {
    prediction : s32 = 0;
    for 0..3 prediction += lms.weights[it] * lms.history[it];
    return prediction >> 13;
}

update :: inline (lms: *Qoa_Lms, sample: s32, residual: s32) {
    delta : s32 = residual >> 4;
    for 0..3 lms.weights[it] += ifx lms.history[it] < 0 then -delta else delta;
    for 0..2 lms.history[it] = lms.history[it+1];
    lms.history[3] = sample;
}

#assert !size_of(Qoa);
#assert !size_of(QoaMath);
#assert !size_of(QoaCursor);
#assert !size_of(QoaCodec);
#assert !size_of(QoaPlay);

QoaMath :: struct {
    div :: inline (v: s32, scalefactor: s32) -> s32 {
        s :: inline (x: s32) -> s32 {
            if x > 0 return 1;
            if x < 0 return -1;
            return 0;
        }
        n := (v * reciprocal_tab[scalefactor] + 0x8000) >> 16;
        return n + s(v) - s(n);
    }

    clamp :: inline (v: s32, min: s32, max: s32) -> s32 {
        if v < min return min;
        if v > max return max;
        return v;
    }

    clamp_s16 :: inline (v: s32) -> s16 {
        if v < -32768 return -32768;
        if v >  32767 return  32767;
        return v.(s16, no_check);
    }
}

QoaCursor :: struct {
    read :: inline (bytes: *u8, p: *u32) -> u64 {
        bytes += p.*;
        p.* += 8;
        return
            (bytes[0].(u64, no_check) << 56) | (bytes[1].(u64, no_check) << 48) |
            (bytes[2].(u64, no_check) << 40) | (bytes[3].(u64, no_check) << 32) |
            (bytes[4].(u64, no_check) << 24) | (bytes[5].(u64, no_check) << 16) |
            (bytes[6].(u64, no_check) <<  8) | bytes[7].(u64, no_check);
    }

    write :: inline (v: u64, bytes: *u8, p: *u32) {
        bytes += p.*;
        p.* += 8;
        bytes[0] = (v >> 56).(u8, no_check);
        bytes[1] = (v >> 48).(u8, no_check);
        bytes[2] = (v >> 40).(u8, no_check);
        bytes[3] = (v >> 32).(u8, no_check);
        bytes[4] = (v >> 24).(u8, no_check);
        bytes[5] = (v >> 16).(u8, no_check);
        bytes[6] = (v >>  8).(u8, no_check);
        bytes[7] = v.(u8, no_check);
    }
}

Range :: struct ($T: Type, $F: bool, $S: bool) {
    #if T from : T;
    count      : T;
    #if S step : T;
}
range    :: inline ($T: Type, from: T, count: T)          -> Range(T, true,  false) { return .{ from  = from, count = count }; }
range    :: inline ($T: Type, count: T)                   -> Range(T, false, false) { return .{ count = count }; }
range_by :: inline ($T: Type, from: T, count: T, step: T) -> Range(T, true,  true)  { return .{ from  = from, count = count, step = step }; }
range_by :: inline ($T: Type, count: T, step: T)          -> Range(T, false, true)  { return .{ count = count, step = step }; }

for_expansion :: inline (r: Range($T, $F, $S), body: Code, flags: For_Flags) #expand {
    #if F this : T = r.from;
    else  this : T = 0;
    idx        : T = 0;
    while this < r.count {
        defer {
            #if S this += r.step;
            else  this += 1;
            idx += 1;
        }
        `it       := this;
        `it_index := idx;
        #insert body;
    }
}

QoaCodec :: struct {
    encode_header :: inline (qoa: *Qoa_Desc, bytes: *u8) -> u32 {
        p : u32 = 0;
        QoaCursor.write((QOA_MAGIC.(u64, no_check) << 32) | qoa.samples, bytes, *p);
        return p;
    }

    encode_frame :: inline (sample_data: *s16, qoa: *Qoa_Desc, frame_len: u32, bytes: *u8) -> u32 {
        channels : u32 = qoa.channels;

        p                : u32 = 0;
        slices           : u32 = (frame_len + 19) / 20;
        frame_size       : u32 = QOA_FRAME_SIZE(channels, slices);
        prev_scalefactor : [8]s32;

        QoaCursor.write(
            (qoa.channels.(u64, no_check)   << 56) |
            (qoa.samplerate.(u64, no_check) << 32) |
            (frame_len.(u64, no_check)      << 16) |
            frame_size.(u64, no_check), bytes, *p);

        for range(u32, channels) {
            QoaCursor.write(
                (qoa.lms[it].history[0].(u16, no_check).(u64, no_check) << 48) |
                (qoa.lms[it].history[1].(u16, no_check).(u64, no_check) << 32) |
                (qoa.lms[it].history[2].(u16, no_check).(u64, no_check) << 16) |
                qoa.lms[it].history[3].(u16, no_check).(u64, no_check),
            bytes, *p);
            QoaCursor.write(
                (qoa.lms[it].weights[0].(u16, no_check).(u64, no_check) << 48) |
                (qoa.lms[it].weights[1].(u16, no_check).(u64, no_check) << 32) |
                (qoa.lms[it].weights[2].(u16, no_check).(u64, no_check) << 16) |
                qoa.lms[it].weights[3].(u16, no_check).(u64, no_check),
            bytes, *p);
        }

        for sample_index: range_by(u32, frame_len, 20) {
            for c: range(u32, channels) {
                slice_len   := QoaMath.clamp(20, 0, (frame_len - sample_index).(s32, no_check)).(u32, no_check);
                slice_start := sample_index * channels + c;
                slice_end   := (sample_index + slice_len) * channels + c;

                best_rank        : u64 = 0xffff_ffff_ffff_ffff;
                best_slice       : u64 = 0;
                best_lms         : Qoa_Lms = ---;
                best_scalefactor : s32 = 0;

                for sfi: range(s32, 16) {
                    lms          := qoa.lms[c];
                    scalefactor  := (sfi + prev_scalefactor[c]) & 0xf;
                    slice        := scalefactor.(u64, no_check);
                    current_rank : u64 = 0;

                    for si: range_by(u32, slice_start, slice_end, channels) {
                        sample        := sample_data[si];
                        predicted     := predict(*lms);
                        quantized     := quant_tab[QoaMath.clamp(QoaMath.div(sample - predicted, scalefactor), -8, 8) + 8];
                        dequantized   := dequant_tab[scalefactor][quantized];
                        reconstructed := QoaMath.clamp_s16(predicted + dequantized);

                        weights_penalty := ((
                            lms.weights[0] * lms.weights[0] +
                            lms.weights[1] * lms.weights[1] +
                            lms.weights[2] * lms.weights[2] +
                            lms.weights[3] * lms.weights[3]
                        ) >> 18) - 0x8ff;
                        if weights_penalty < 0 weights_penalty = 0;
                        weights_penalties := weights_penalty.(u64, no_check);
                        weights_penalties *= weights_penalties;

                        error    := sample - reconstructed;
                        error_sq := (error * error).(u64, no_check);

                        current_rank += error_sq + weights_penalties;
                        if current_rank > best_rank break;

                        update(*lms, reconstructed, dequantized);
                        slice = (slice << 3) | quantized.(u64, no_check);
                    }

                    if current_rank < best_rank {
                        best_rank        = current_rank;
                        best_slice       = slice;
                        best_lms         = lms;
                        best_scalefactor = scalefactor;
                    }
                }

                prev_scalefactor[c] = best_scalefactor;

                qoa.lms[c] = best_lms;

                best_slice <<= (20 - slice_len) * 3;
                QoaCursor.write(best_slice, bytes, *p);
            }
        }

        return p;
    }

    decode_header :: inline (bytes: *u8, size: u32, qoa: *Qoa_Desc) -> u32 {
        p : u32 = 0;
        if size < 16 return 0;

        file_header := QoaCursor.read(bytes, *p);

        if (file_header >> 32) != QOA_MAGIC return 0;

        qoa.samples = file_header.(u32, no_check);
        if !qoa.samples return 0;

        frame_header  := QoaCursor.read(bytes, *p);
        qoa.channels   = ((frame_header >> 56) & 0x0000ff).(u32, no_check);
        qoa.samplerate = ((frame_header >> 32) & 0xffffff).(u32, no_check);

        if !qoa.channels || !qoa.samples || !qoa.samplerate return 0;

        return 8;
    }

    decode_frame :: (bytes: *u8, size: u32, qoa: *Qoa_Desc, sample_data: *s16) -> u32, u32 {
        p : u32 = 0;

        if size < (qoa.channels << 4) + 8 return 0, 0;

        frame_header := QoaCursor.read(bytes, *p);
        channels   := ((frame_header >> 56) & 0x0000ff).(u32, no_check);
        samplerate := ((frame_header >> 32) & 0xffffff).(u32, no_check);
        samples    := ((frame_header >> 16) & 0x00ffff).(u32, no_check);
        frame_size := (frame_header         & 0x00ffff).(u32, no_check);

        data_size         := frame_size - 8 - (channels << 4);
        num_slices        := data_size >> 3;
        max_total_samples := num_slices * 20;

        if channels != qoa.channels || samplerate != qoa.samplerate || frame_size > size || samples * channels > max_total_samples
            return 0, 0;

        for range(u32, channels) {
            history := QoaCursor.read(bytes, *p);
            qoa.lms[it].history[0] = (history >> 48).(s16, no_check);
            qoa.lms[it].history[1] = (history >> 32).(s16, no_check);
            qoa.lms[it].history[2] = (history >> 16).(s16, no_check);
            qoa.lms[it].history[3] = history.(s16, no_check);
            weights := QoaCursor.read(bytes, *p);
            qoa.lms[it].weights[0] = (weights >> 48).(s16, no_check);
            qoa.lms[it].weights[1] = (weights >> 32).(s16, no_check);
            qoa.lms[it].weights[2] = (weights >> 16).(s16, no_check);
            qoa.lms[it].weights[3] = weights.(s16, no_check);
        }

        for sample_index: range_by(u32, samples, 20) {
            for c: range(u32, channels) {
                slice := QoaCursor.read(bytes, *p);

                scalefactor := ((slice >> 60) & 0xf).(u8, no_check);
                slice <<= 4;

                slice_start := sample_index * channels + c;
                slice_end   := sample_index + 20;
                if slice_end > samples slice_end = samples;
                slice_end = slice_end * channels + c;

                for si: range_by(u32, slice_start, slice_end, channels) {
                    predicted     := predict(*qoa.lms[c]);
                    dequantized   := dequant_tab[scalefactor][(slice >> 61) & 0x7];
                    reconstructed := QoaMath.clamp_s16(predicted + dequantized);

                    sample_data[si] = reconstructed;
                    slice <<= 3;

                    update(*qoa.lms[c], reconstructed, dequantized);
                }
            }
        }

        return p, samples;
    }
}

#scope_export

Qoa_Lms :: struct {
    history: [4]s32;
    weights: [4]s32;
}

Qoa_Desc :: struct {
    lms        : [8]Qoa_Lms;
    channels   : u32;
    samplerate : u32;
    samples    : u32;
}

Qoa :: struct {
    encode :: inline (sample_data: *s16, qoa: *Qoa_Desc) -> string, bool {
        bytes : string = .{ 0, null };

        if !qoa.samples || !qoa.samplerate || qoa.samplerate > 0xffffff || !qoa.channels || qoa.channels > 8
            return bytes, false;

        num_frames   := (qoa.samples + 5119) / 5120;
        num_slices   := (qoa.samples + 19) / 20;
        encoded_size := (num_frames << 3) + ((qoa.channels * num_frames) << 4) + ((num_slices * qoa.channels) << 3) + 8;

        bytes.data = alloc(encoded_size);

        for c: range(u32, qoa.channels) {
            qoa.lms[c].weights[0] = 0;
            qoa.lms[c].weights[1] = 0;
            qoa.lms[c].weights[2] = -0x2000;
            qoa.lms[c].weights[3] =  0x4000;

            for range(u32, 4) qoa.lms[c].history[it] = 0;
        }

        p := QoaCodec.encode_header(qoa, bytes.data);

        frame_len    : u32 = 5120;
        sample_index : u32 = 0;
        while sample_index < qoa.samples {
            frame_len = qoa.samples - sample_index;
            if frame_len > 5120 frame_len = 5120;
            frame_samples : *s16 = sample_data + sample_index * qoa.channels;
            frame_size    := QoaCodec.encode_frame(frame_samples, qoa, frame_len, bytes.data.(*u8, no_check) + p);
            sample_index  += frame_len;
            p             += frame_size;
        }
        bytes.count = xx,no_check p;

        return bytes, true;
    }

    decode :: inline (file: string) -> *s16, Qoa_Desc, bool {
        bytes := file.data.(*u8, no_check);
        size  := file.count.(u32, no_check);

        qoa : Qoa_Desc = ---;
        p := QoaCodec.decode_header(bytes, size, *qoa);
        if !p return null, qoa, false;

        total_samples := qoa.samples * qoa.channels;
        sample_data   := alloc(size_of(s16) * total_samples).(*s16, no_check);
        sample_ptr    := sample_data;

        frame_size, frame_len := QoaCodec.decode_frame(bytes + p, size - p, *qoa, sample_ptr);
        sample_index          := frame_len;
        p                     += frame_size;

        while frame_size && sample_index < qoa.samples {
            sample_ptr = sample_data + sample_index * qoa.channels;
            frame_size, frame_len = QoaCodec.decode_frame(bytes + p, size - p, *qoa, sample_ptr);

            sample_index += frame_len;
            p            += frame_size;
        }

        qoa.samples = sample_index;
        return sample_data, qoa, true;
    }
}

#if QOA_PLAY {
    QoaPlay_Desc :: struct {
        info             : Qoa_Desc;
        file             : string;
        sample_data      : *s16;
        buffer           : *u8;
        sample_position  : u32;
        sample_data_len  : u32;
        sample_data_pos  : u32;
        file_data_offset : u32;
        first_frame_pos  : u32;
    }

    QoaPlay :: struct {
        open :: inline (file: string) -> *QoaPlay_Desc, bool {
            qoa : Qoa_Desc = ---;
            if !file.data || file.count < 16 return null, false;
            first_frame_pos := QoaCodec.decode_header(file.data, 16, *qoa);
            if !first_frame_pos return null, false;

            qoa_ctx : *QoaPlay_Desc = alloc(qoa.channels * 10240 * size_of(s16) + file.count + size_of(QoaPlay_Desc));
            memset(qoa_ctx, 0, size_of(QoaPlay_Desc));

            qoa_ctx.file             = file;
            qoa_ctx.file_data_offset = first_frame_pos;
            qoa_ctx.first_frame_pos  = first_frame_pos;

            qoa_ctx.buffer = null;
            qoa_ctx.sample_data = (qoa_ctx.(*u8, no_check) + size_of(QoaPlay_Desc)).(*s16, no_check);

            qoa_ctx.info.channels = qoa.channels;
            qoa_ctx.info.samplerate = qoa.samplerate;
            qoa_ctx.info.samples = qoa.samples;

            return qoa_ctx, true;
        }

        close :: inline (qoa_ctx: *QoaPlay_Desc) { free(qoa_ctx); }

        decode_frame :: inline (qoa_ctx: *QoaPlay_Desc) -> u32 {
            buffer     := qoa_ctx.file.data.(*u8, no_check) + qoa_ctx.file_data_offset;
            buffer_len := QOA_FRAME_SIZE(qoa_ctx.info.channels, 256);
            qoa_ctx.file_data_offset += buffer_len;

            _, frame_len := QoaCodec.decode_frame(buffer, buffer_len, *qoa_ctx.info, qoa_ctx.sample_data);
            qoa_ctx.sample_data_pos = 0;
            qoa_ctx.sample_data_len = frame_len;

            return frame_len;
        }

        rewind :: inline (qoa_ctx: *QoaPlay_Desc) {
            qoa_ctx.file_data_offset = qoa_ctx.first_frame_pos;

            qoa_ctx.sample_position = 0;
            qoa_ctx.sample_data_len = 0;
            qoa_ctx.sample_data_pos = 0;
        }

        decode :: inline (qoa_ctx: *QoaPlay_Desc, samples: []float32) {
            src_index := qoa_ctx.sample_data_pos * qoa_ctx.info.channels;
            dst_index : u32 = 0;

            samples_count := samples.count.(u32, no_check);
            for range(u32, samples_count) {
                if !(qoa_ctx.sample_data_len - qoa_ctx.sample_data_pos) {
                    if !decode_frame(qoa_ctx) {
                        rewind(qoa_ctx);
                        decode_frame(qoa_ctx);
                    }
                    src_index = 0;
                }

                for range(u32, qoa_ctx.info.channels) {
                    samples.data[dst_index] = qoa_ctx.sample_data[src_index] * 0h38000000;
                    dst_index += 1;
                    src_index += 1;
                }

                qoa_ctx.sample_data_pos += 1;
                qoa_ctx.sample_position += 1;
            }
        }

        get_duration :: inline (qoa_ctx: *QoaPlay_Desc) -> float64 {
            return qoa_ctx.info.samples.(float64, no_check) / qoa_ctx.info.samplerate.(float64, no_check);
        }

        get_time :: inline (qoa_ctx: *QoaPlay_Desc) -> float64 {
            return qoa_ctx.sample_position.(float64, no_check) / qoa_ctx.info.samplerate.(float64, no_check);
        }

        get_frame :: inline (qoa_ctx: *QoaPlay_Desc) -> u32 {
            return qoa_ctx.sample_position / 5120;
        }

        seek_frame :: inline (qoa_ctx: *QoaPlay_Desc, frame: u32) {
            s := qoa_ctx.info.samples / 5120;
            if frame > s frame = s;

            qoa_ctx.sample_position = frame * 5120;
            qoa_ctx.sample_data_len = 0;
            qoa_ctx.sample_data_pos = 0;
            qoa_ctx.file_data_offset = qoa_ctx.first_frame_pos + QOA_FRAME_SIZE(qoa_ctx.info.channels, 256) * frame;
        }
    }
}
