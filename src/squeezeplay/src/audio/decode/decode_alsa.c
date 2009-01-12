/*
** Copyright 2007-2008 Logitech. All Rights Reserved.
**
** This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.
*/

#define RUNTIME_DEBUG 1

#include "common.h"

#include "audio/fifo.h"
#include "audio/fixed_math.h"
#include "audio/mqueue.h"
#include "audio/decode/decode.h"
#include "audio/decode/decode_priv.h"


#ifdef HAVE_LIBASOUND

#include <pthread.h>
#include <alsa/asoundlib.h>



#define FLAG_STREAM_PLAYBACK 0x01
#define FLAG_STREAM_EFFECTS  0x02

struct decode_alsa {
	/* device configuration */
	const char *name;
	u32_t flags;
	unsigned int buffer_time;
	unsigned int period_count;

	/* alsa state */
	snd_pcm_t *pcm;
	snd_pcm_hw_params_t *hw_params;
	snd_pcm_sframes_t period_size;

	/* playback state */
	u32_t new_sample_rate;
	u32_t pcm_sample_rate;

	fft_fixed lgain, rgain;

	/* thread */
	pthread_t thread;
};


#define ALSA_DEFAULT_DEVICE "default"
#define ALSA_DEFAULT_BUFFER_TIME 30000
#define ALSA_DEFAULT_PERIOD_COUNT 3


/* alsa debugging */
static snd_output_t *output;

/* player state */
static struct decode_alsa *playback_state;
static struct decode_alsa *effects_state;



/*
 * This function is called by to copy samples from the output buffer to
 * the alsa buffer.
 *
 * Called with fifo-lock held.
 */
static void playback_callback(struct decode_alsa *state,
			      void *outputBuffer,
			      unsigned long framesPerBuffer) {
	size_t bytes_used, len, skip_bytes = 0, add_bytes = 0;
	bool_t reached_start_point;
	Uint8 *outputArray = (u8_t *)outputBuffer;

	// XXXX full port from ip3k

	len = SAMPLES_TO_BYTES(framesPerBuffer);

	/* audio running? */
	if (!(current_audio_state & DECODE_STATE_RUNNING)) {
		memset(outputArray, 0, len);

		return;
	}
	
	if (add_silence_ms) {
		add_bytes = SAMPLES_TO_BYTES((u32_t)((add_silence_ms * current_sample_rate) / 1000));
		if (add_bytes > len) {
			add_bytes = len;
		}
		memset(outputArray, 0, add_bytes);
		outputArray += add_bytes;
		len -= add_bytes;
		add_silence_ms -= (BYTES_TO_SAMPLES(add_bytes) * 1000) / current_sample_rate;
		if (add_silence_ms < 2) {
			add_silence_ms = 0;
		}
		if (!len) {
			return;
		}
	}

	bytes_used = fifo_bytes_used(&decode_fifo);
	
	/* only skip if it will not cause an underrun */
	if (bytes_used >= len && skip_ahead_bytes > 0) {
		skip_bytes = bytes_used - len;
		if (skip_bytes > skip_ahead_bytes) {
			skip_bytes = skip_ahead_bytes;			
		}
	}

	if (bytes_used > len) {
		bytes_used = len;
	}

	/* audio underrun? */
	if (bytes_used == 0) {
		current_audio_state |= DECODE_STATE_UNDERRUN;
		memset(outputArray, 0, len);
		DEBUG_ERROR("Audio underrun: used 0 bytes");

		return;
	}

	if (bytes_used < len) {
		current_audio_state |= DECODE_STATE_UNDERRUN;
		memset(outputArray + bytes_used, 0, len - bytes_used);
		DEBUG_ERROR("Audio underrun: used %d bytes , requested %d bytes", (int)bytes_used, (int)len);
	}
	else {
		current_audio_state &= ~DECODE_STATE_UNDERRUN;
	}
	
	if (skip_bytes) {
		size_t wrap;

		DEBUG_TRACE("Skipping %d bytes", (int)skip_bytes);
		
		wrap = fifo_bytes_until_rptr_wrap(&decode_fifo);

		if (wrap < skip_bytes) {
			fifo_rptr_incby(&decode_fifo, wrap);
			skip_bytes -= wrap;
			skip_ahead_bytes -= wrap;
			decode_elapsed_samples += BYTES_TO_SAMPLES(wrap);
		}

		fifo_rptr_incby(&decode_fifo, skip_bytes);
		skip_ahead_bytes -= skip_bytes;
		decode_elapsed_samples += BYTES_TO_SAMPLES(skip_bytes);
	}

	while (bytes_used) {
		size_t wrap, bytes_write, samples_write;
		sample_t *output_ptr, *decode_ptr;

		wrap = fifo_bytes_until_rptr_wrap(&decode_fifo);

		bytes_write = bytes_used;
		if (wrap < bytes_write) {
			bytes_write = wrap;
		}

		samples_write = BYTES_TO_SAMPLES(bytes_write);

		output_ptr = (sample_t *)(void *)outputArray;
		decode_ptr = (sample_t *)(void *)(decode_fifo_buf + decode_fifo.rptr);
		while (samples_write--) {
			*(output_ptr++) = fixed_mul(state->lgain, *(decode_ptr++));
			*(output_ptr++) = fixed_mul(state->rgain, *(decode_ptr++));
		}

		fifo_rptr_incby(&decode_fifo, bytes_write);
		decode_elapsed_samples += BYTES_TO_SAMPLES(bytes_write);

		outputArray += bytes_write;
		bytes_used -= bytes_write;
	}

	reached_start_point = decode_check_start_point();
	if (reached_start_point && current_sample_rate != state->pcm_sample_rate) {
		state->new_sample_rate = current_sample_rate;
	}
}


/*
 * This function is called by to copy effects to the alsa buffer.
 */
static void effects_callback(struct decode_alsa *state,
			      void *outputBuffer,
			      unsigned long framesPerBuffer) {

	decode_sample_mix(outputBuffer, SAMPLES_TO_BYTES(framesPerBuffer));
}


static int pcm_close(struct decode_alsa *state) {
	int err;

	if (!state->pcm) {
		return 0;
	}

	if ((err = snd_pcm_drain(state->pcm)) < 0) {
		DEBUG_ERROR("snd_pcm_drain error: %s", snd_strerror(err));
	}

	if ((err = snd_pcm_close(state->pcm)) < 0) {
		DEBUG_ERROR("snd_pcm_close error: %s", snd_strerror(err));
	}

	snd_pcm_hw_params_free(state->hw_params);

	state->pcm = NULL;
	return 0;
}


static int pcm_open(struct decode_alsa *state) {
	int err, dir;
	unsigned int val;
	snd_pcm_uframes_t size;

	/* Close existing pcm (if any) */
	if (state->pcm) {
		pcm_close(state);
	}

	/* Open pcm */
	if ((err = snd_pcm_open(&state->pcm, state->name, SND_PCM_STREAM_PLAYBACK, 0)) < 0) {
		DEBUG_ERROR("Playback open error: %s", snd_strerror(err));
		return err;
	}

	/* Set hardware parameters */
	if ((err = snd_pcm_hw_params_malloc(&state->hw_params)) < 0) {
		DEBUG_ERROR("hwparam malloc error: %s", snd_strerror(err));
		return err;
	}

	if ((err = snd_pcm_hw_params_any(state->pcm, state->hw_params)) < 0) {
		DEBUG_ERROR("hwparam init error: %s", snd_strerror(err));
		return err;
	}

	/* set hardware resampling */
	if ((err = snd_pcm_hw_params_set_rate_resample(state->pcm, state->hw_params, 1)) < 0) {
		DEBUG_ERROR("Resampling setup failed: %s\n", snd_strerror(err));
		return err;
	}

	/* set mmap interleaved access format */
	if ((err = snd_pcm_hw_params_set_access(state->pcm, state->hw_params, SND_PCM_ACCESS_MMAP_INTERLEAVED)) < 0) {
		DEBUG_ERROR("Access type not available: %s", snd_strerror(err));
		return err;
	}

	/* set the sample format */
	if ((err = snd_pcm_hw_params_set_format(state->pcm, state->hw_params, SND_PCM_FORMAT_S32_LE)) < 0) {
		DEBUG_ERROR("Sample format not available: %s", snd_strerror(err));
		return err;
	}

	/* set the channel count */
	if ((err = snd_pcm_hw_params_set_channels(state->pcm, state->hw_params, 2)) < 0) {
		DEBUG_ERROR("Channel count not available: %s", snd_strerror(err));
		return err;
	}

	/* set the stream rate */
	if ((err = snd_pcm_hw_params_set_rate_near(state->pcm, state->hw_params, &state->new_sample_rate, 0)) < 0) {
		DEBUG_ERROR("Rate not available: %s", snd_strerror(err));
		return err;
	}

	/* set buffer and period times */
	val = state->buffer_time;
	if ((err = snd_pcm_hw_params_set_buffer_time_near(state->pcm, state->hw_params, &val, &dir)) < 0) {
		DEBUG_ERROR("Unable to set  buffer time %s", snd_strerror(err));
		return err;
	}

	val = state->period_count;
	if ((err = snd_pcm_hw_params_set_periods_near(state->pcm, state->hw_params, &val, &dir)) < 0) {
		DEBUG_ERROR("Unable to set period size %s", snd_strerror(err));
		return err;
	}

	/* set hardware parameters */
	if ((err = snd_pcm_hw_params(state->pcm, state->hw_params)) < 0) {
		DEBUG_ERROR("Unable to set hw params: %s", snd_strerror(err));
		return err;
	}

	if ((err = snd_pcm_hw_params_get_period_size(state->hw_params, &size, &dir)) < 0) {
		DEBUG_ERROR("Unable to get period size: %s", snd_strerror(err));
		return err;
	}
	state->period_size = size;

#ifdef RUNTIME_DEBUG
	snd_pcm_dump(state->pcm, output);
#endif

	state->pcm_sample_rate = state->new_sample_rate;
	state->new_sample_rate = 0;

	return 0;
}


static int pcm_test(const char *name) {
	struct decode_alsa tmp_state;
	int err;

	memset(&tmp_state, 0, sizeof(struct decode_alsa));
	tmp_state.name = name;
	tmp_state.buffer_time = ALSA_DEFAULT_BUFFER_TIME;
	tmp_state.period_count = ALSA_DEFAULT_PERIOD_COUNT;
	tmp_state.new_sample_rate = 44100;
	if ((err = pcm_open(&tmp_state)) < 0) {
		return err;
	}
	pcm_close(&tmp_state);

	return 0;
}


static int xrun_recovery(struct decode_alsa *state, int err) {
	if (err == -EPIPE) {	/* under-run */
		if ((err = snd_pcm_prepare(state->pcm) < 0)) {
			DEBUG_ERROR("Can't recovery from underrun, prepare failed: %s\n", snd_strerror(err));
		}
		return 0;
	} else if (err == -ESTRPIPE) {
		while ((err = snd_pcm_resume(state->pcm)) == -EAGAIN) {
			sleep(1);	/* wait until the suspend flag is released */
		}
		if (err < 0) {
			if ((err = snd_pcm_prepare(state->pcm)) < 0) {
				DEBUG_ERROR("Can't recovery from suspend, prepare failed: %s\n", snd_strerror(err));
			}
		}
		return 0;
	}
	return err;
}


static void *audio_thread_execute(void *data) {
	struct decode_alsa *state = (struct decode_alsa *)data;
	snd_pcm_state_t pcm_state;
	snd_pcm_uframes_t size;
	snd_pcm_sframes_t avail;
	snd_pcm_status_t *status;
	int err, first = 1;

	DEBUG_TRACE("audio_thread_execute");
	
	status = malloc(snd_pcm_hw_params_sizeof());

	while (1) {
		fifo_lock(&decode_fifo);

		if (state->new_sample_rate) {
			if ((err = pcm_open(state)) < 0) {
				DEBUG_ERROR("Open failed: %s", snd_strerror(err));
				goto thread_error_unlock;
			}
			first = 1;
		}

		fifo_unlock(&decode_fifo);

		pcm_state = snd_pcm_state(state->pcm);
		if (pcm_state == SND_PCM_STATE_XRUN) {
			if ((err = xrun_recovery(state, -EPIPE)) < 0) {
				DEBUG_ERROR("XRUN recovery failed: %s", snd_strerror(err));
			}
			first = 1;
		}
		else if (pcm_state == SND_PCM_STATE_SUSPENDED) {
			if ((err = xrun_recovery(state, -ESTRPIPE)) < 0) {
				DEBUG_ERROR("SUSPEND recovery failed: %s", snd_strerror(err));
			}
		}

		avail = snd_pcm_avail_update(state->pcm);
		if (avail < 0) {
			if ((err = xrun_recovery(state, avail)) < 0) {
				DEBUG_ERROR("Avail update failed: %s", snd_strerror(err));
			}
			first = 1;
			continue;
		}

		/* this is needed to ensure the sound works on resume */
		if (( err = snd_pcm_status(state->pcm, status)) < 0) {
			DEBUG_ERROR("snd_pcm_status err=%d\n", err);
		}

		if (avail < state->period_size) {
			if (first) {
				first = 0;
				if ((err = snd_pcm_start(state->pcm)) < 0) {
					DEBUG_ERROR("Audio start error: %s", snd_strerror(err));
				}
			}
			else {
				if ((err = snd_pcm_wait(state->pcm, 500)) < 0) {
					if ((err = xrun_recovery(state, avail)) < 0) {
						DEBUG_ERROR("PCM wait failed: %s", snd_strerror(err));
					}
					first = 1;
				}

			}
			continue;
		}

		size = state->period_size;
		while (size > 0) {
			const snd_pcm_channel_area_t *areas;
			snd_pcm_uframes_t frames, offset;
			snd_pcm_sframes_t commitres;
			void *buf;

			frames = size;

			if ((err = snd_pcm_mmap_begin(state->pcm, &areas, &offset, &frames)) < 0) {
				if ((err = xrun_recovery(state, avail)) < 0) {
					DEBUG_ERROR("mmap begin failed: %s", snd_strerror(err));
				}
				first = 1;
			}

			fifo_lock(&decode_fifo);

			buf = ((u8_t *)areas[0].addr) + (areas[0].first + offset * areas[0].step) / 8;

			if (state->flags & FLAG_STREAM_PLAYBACK) {
				playback_callback(state, buf, frames);
			}
			else {
				memset(buf, 0, SAMPLES_TO_BYTES(frames));
			}
			if (state->flags & FLAG_STREAM_EFFECTS) {
				effects_callback(state, buf, frames);
			}

			fifo_unlock(&decode_fifo);

			commitres = snd_pcm_mmap_commit(state->pcm, offset, frames); 
			if (commitres < 0 || (snd_pcm_uframes_t)commitres != frames) { 
				if ((err = xrun_recovery(state, avail)) < 0) {
					DEBUG_ERROR("mmap commit failed: %s", snd_strerror(err));
				}
				first = 1;
			}
			size -= frames;
		}
	}

 thread_error_unlock:
	fifo_unlock(&decode_fifo);
	free(status);

	DEBUG_ERROR("Audio thread exited");
	return (void *)-1;
}


static struct decode_alsa *decode_alsa_thread_init(const char *name, unsigned int buffer_time, unsigned int period_count, u32_t flags) {
	struct decode_alsa *state;
	pthread_attr_t thread_attr;
	struct sched_param thread_param;
	size_t stacksize;
	int err;

	state = calloc(sizeof(struct decode_alsa), 1);
	state->name = name;
	state->flags = flags;
	state->buffer_time = buffer_time;
	state->period_count = period_count;
	state->new_sample_rate = 44100;
	state->lgain = FIXED_ONE;
	state->rgain = FIXED_ONE;


	/* start audio thread */
	if ((err = pthread_attr_init(&thread_attr)) != 0) {
		DEBUG_ERROR("pthread_attr_init: %s", strerror(err));
		goto thread_err;
	}

	if ((err = pthread_attr_setdetachstate(&thread_attr, PTHREAD_CREATE_DETACHED)) != 0) {
		DEBUG_ERROR("pthread_attr_setdetachstate: %s", strerror(err));
		goto thread_err;
	}

	stacksize = 32 * 1024; /* 32k stack, we don't do much here */
	if ((err = pthread_attr_setstacksize(&thread_attr, stacksize)) != 0) {
		DEBUG_ERROR("pthread_attr_setstacksize: %s", strerror(err));
	}

	if ((err = pthread_create(&state->thread, &thread_attr, audio_thread_execute, state)) != 0) {
		DEBUG_ERROR("pthread_create: %s", strerror(err));
		goto thread_err;
	}

	/* set realtime scheduler policy, with a high priority */
	thread_param.sched_priority = sched_get_priority_max(SCHED_FIFO);

	err = pthread_setschedparam(state->thread, SCHED_FIFO, &thread_param);
	if (err) {
		if (err == EPERM) {
			DEBUG_ERROR("Can't set audio thread priority\n");
		}
		else {
			DEBUG_ERROR("pthread_create: %s", strerror(err));
			goto thread_err;
		}
	}

	return state;

 thread_err:
	// FIXME clean up
	return NULL;
}


static u32_t decode_alsa_delay(void)
{
	snd_pcm_status_t* status;
  
	/* dies with warning on GCC 4.2:
	 * snd_pcm_status_alloca(&status);
	 */
	status = (snd_pcm_status_t *) alloca(snd_pcm_hw_params_sizeof());
	memset(status, 0, snd_pcm_hw_params_sizeof());

	snd_pcm_status(playback_state->pcm, status);

	return (u32_t)snd_pcm_status_get_delay(status);
}


static void decode_alsa_start(void) {
	DEBUG_TRACE("decode_alsa_start");

	fifo_lock(&decode_fifo);
	if (playback_state->pcm_sample_rate != current_sample_rate) {
		playback_state->new_sample_rate = current_sample_rate;
	}
	fifo_unlock(&decode_fifo);
}


static void decode_alsa_resume(void) {
	DEBUG_TRACE("decode_alsa_resume");

	fifo_lock(&decode_fifo);
	if (playback_state->pcm_sample_rate != current_sample_rate) {
		playback_state->new_sample_rate = current_sample_rate;
	}
	// snd_pcm_pause(playback_state.pcm, 1);
	fifo_unlock(&decode_fifo);
}


static void decode_alsa_pause(void) {
	DEBUG_TRACE("decode_alsa_pause");

	fifo_lock(&decode_fifo);
//	snd_pcm_pause(playback_state.pcm, 0);
	if (playback_state->pcm_sample_rate != 44100) {
		playback_state->new_sample_rate = 44100;
	}
	fifo_unlock(&decode_fifo);
}


static void decode_alsa_stop(void) {
	DEBUG_TRACE("decode_alsa_stop");

	fifo_lock(&decode_fifo);
	if (playback_state->pcm_sample_rate != 44100) {
		playback_state->new_sample_rate = 44100;
	}
	fifo_unlock(&decode_fifo);
}


static void decode_alsa_gain(s32_t left_gain, s32_t right_gain) {
	playback_state->lgain = left_gain;
	playback_state->rgain = right_gain;
}


static int decode_alsa_init(lua_State *L) {
	int err;
	const char *playback_device;
	const char *effects_device;
	unsigned int buffer_time;
	unsigned int period_count;


	if ((err = snd_output_stdio_attach(&output, stdout, 0)) < 0) {
		DEBUG_ERROR("Output failed: %s", snd_strerror(err));
		return 0;
	}

	lua_getfield(L, 2, "alsaPlaybackDevice");
	playback_device = luaL_optstring(L, -1, ALSA_DEFAULT_DEVICE);

	lua_getfield(L, 2, "alsaEffectsDevice");
	effects_device = luaL_optstring(L, -1, NULL);


	/* test if device is available */
	if (pcm_test(playback_device) < 0) {
		lua_pop(L, 2);
		return 0;
	}

	if (effects_device && pcm_test(effects_device) < 0) {
		effects_device = NULL;
	}

	DEBUG_TRACE("Playback device: %s\n", playback_device);

	lua_getfield(L, 2, "alsaPlaybackBufferTime");
	buffer_time = luaL_optinteger(L, -1, ALSA_DEFAULT_BUFFER_TIME);
	lua_getfield(L, 2, "alsaPlaybackPeriodCount");
	period_count = luaL_optinteger(L, -1, ALSA_DEFAULT_PERIOD_COUNT);
	lua_pop(L, 2);

	playback_state =
		decode_alsa_thread_init(playback_device,
					buffer_time,
					period_count,
					(effects_device) ? FLAG_STREAM_PLAYBACK : FLAG_STREAM_PLAYBACK | FLAG_STREAM_EFFECTS
					);

	if (effects_device) {
		DEBUG_TRACE("Effects device: %s\n", effects_device);

		lua_getfield(L, 2, "alsaEffectsBufferTime");
		buffer_time = luaL_optinteger(L, -1, ALSA_DEFAULT_BUFFER_TIME);
		lua_getfield(L, 2, "alsaEffectsPeriodCount");
		period_count = luaL_optinteger(L, -1, ALSA_DEFAULT_PERIOD_COUNT);
		lua_pop(L, 2);

		effects_state = 
			decode_alsa_thread_init(effects_device,
						buffer_time,
						period_count,
						FLAG_STREAM_EFFECTS
						);
	}

	lua_pop(L, 2);
	return 1;
}


struct decode_audio decode_alsa = {
	decode_alsa_init,
	decode_alsa_start,
	decode_alsa_pause,
	decode_alsa_resume,
	decode_alsa_stop,
	decode_alsa_delay,
	decode_alsa_gain,
};

#endif // HAVE_LIBASOUND
