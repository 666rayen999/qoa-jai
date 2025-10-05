# QOI Implementation in Jai

This repository contains an implementation of the [QOA (Quite OK Audio)](https://github.com/phoboslab/qoa/) format in the [Jai programming language](https://en.wikipedia.org/?title=JAI_(programming_language)).

> QOA is fast. It decodes audio 3x faster than Ogg-Vorbis, while offering better quality and compression than ADPCM (278 kbits/s for 44khz stereo).

---

## Features

- Compliant with the [latest](https://qoaformat.org/qoa-specification.pdf) QOA format specification.
- Clean and minimal codebase.
- streaming playback via **QoaPlay**

---

## ⚠️ Known Issues

The **encode** function currently has some minor artifacts — when you encode and then decode,
you might hear light **noise** mixed with the audio.

Still being debugged.
Decoding `.qoa` files made by the **official encoder** works fine.
So for now:
- ✅ You can use this implementation for decoding or playback
- ⚠️ Encoding is experimental (expect some noise)

---

## Module

```jai
#import,file "qoa";

Qoa.encode :: (sample_data: *s16, qoa: *Qoa_Desc) -> file: string, ok: bool;
Qoa.decode :: (file: string) -> sample_data: *s16, desc: Qoa_Desc, ok: bool;

QoaPlay.open  :: (file: string) -> desc: *QoaPlay_Desc, ok: bool;
QoaPlay.close :: (qoa_ctx: *QoaPlay_Desc);

QoaPlay.decode       :: (qoa_ctx: *QoaPlay_Desc, samples: []float32);
QoaPlay.decode_frame :: (qoa_ctx: *QoaPlay_Desc) -> frame_len: u32;

QoaPlay.get_duration :: (qoa_ctx: *QoaPlay_Desc) -> float64;
QoaPlay.get_time     :: (qoa_ctx: *QoaPlay_Desc) -> float64;
QoaPlay.get_frame    :: (qoa_ctx: *QoaPlay_Desc) -> u32;

QoaPlay.seek_frame :: (qoa_ctx: *QoaPlay_Desc, frame: u32);
QoaPlay.rewind     :: (qoa_ctx: *QoaPlay_Desc);
```

---

## Examples

### Qoa_Play

This example uses [Sokol-Jai](https://github.com/colinbellino/sokol-jai).

```jai
#import "Basic";
#import "File";

#import,dir  "sokol/audio";
#import,file "qoa.jai";

sokol_audio_cb :: (sample_data: *float, num_samples: s32, num_channels: s32, user_data: *void) #c_call {
    push_context,defer_pop;

	sound := cast(*QoaPlay_Desc) user_data;
    assert(sound.info.channels == cast(u32) num_channels);

    samples : []float;
    samples.count = num_samples;
    samples.data  = sample_data;

    QoaPlay.decode(sound, samples);

    print("% / % sec\n", QoaPlay.get_time(sound), QoaPlay.get_duration(sound));
}

main :: () {
    qoa_file, ok := read_entire_file("sound.qoa");
    assert(ok);
    defer free(qoa_file);

	sound:, ok = QoaPlay.open(qoa_file);
    assert(ok);
    defer QoaPlay.close(sound);

	print(
		"channels: %, samplerate: % hz, samples per channel: %, duration: % sec\n",
		sound.info.channels,
		sound.info.samplerate,
		sound.info.samples,
		QoaPlay.get_duration(sound),
	);

	saudio_setup(*(saudio_desc.{
		sample_rate        = xx sound.info.samplerate,
		num_channels       = xx sound.info.channels,
		stream_userdata_cb = sokol_audio_cb,
		user_data          = sound
	}));
	defer saudio_shutdown();

	while true { }
}
```

### Loading + Saving

```jai
#import "Basic";
#import "File";

#import,file "qoa.jai"(QOA_PLAY = false);

main2 :: () {
    original, ok := read_entire_file("original.qoa");
    assert(ok);
    defer free(original);

    decoded:, desc:, ok = Qoa.decode(original);
    assert(ok);
    defer free(decoded);

    encoded:, ok = Qoa.encode(decoded, *desc);
    assert(ok);
    defer free(encoded);

    write_entire_file("out.qoa", encoded);
}
```

---

### License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
