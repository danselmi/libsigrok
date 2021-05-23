/*
 * This file is part of the libsigrok project.
 *
 * Copyright (C) 2021 Daniel Anselmi <danselmi@gmx.ch>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <config.h>
#include <glib.h>
#include <scpi.h>

#include "protocol.h"

static int rs_zvx_scpi_send_rwlocked(const struct sr_dev_inst *sdi,
				const char *format, ...)
{
	va_list args;
	int ret;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	va_start(args, format);
	g_mutex_lock(&devc->rw_mutex);
	ret = sr_scpi_send(scpi, format, args);
	g_mutex_unlock(&devc->rw_mutex);
	va_end(args);

	return ret;
}

static int rohde_schwarz_zvx_get_uint64(const struct sr_dev_inst *sdi,
										const char *command, uint64_t *response)
{
	int ret;
	char *buf;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	buf = NULL;
	ret = sr_scpi_get_string(scpi, command, &buf);
	if (ret != SR_OK)
		return ret;

	*response = atoll(buf);
	g_free(buf);
	return SR_OK;
}

SR_PRIV int rohde_schwarz_zvx_init(struct sr_scpi_dev_inst *scpi)
{
	int ret;
	ret = sr_scpi_send(scpi, "*RST");
	if (ret != SR_OK)
		return ret;

	ret = sr_scpi_send(scpi, "*CLS");
	if (ret != SR_OK)
		return ret;

	return ret;
}

SR_PRIV int rohde_schwarz_zvx_remote(const struct sr_dev_inst *sdi)
{
	int ret;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	g_mutex_lock(&devc->rw_mutex);
	/* disable display updates: */
	ret = sr_scpi_send(scpi, "SYST:DISP:UPD OFF");
	if (ret != SR_OK) {
		g_mutex_unlock(&devc->rw_mutex);
		return ret;
	}

	ret = sr_scpi_send(scpi, "SYST:USER:DISP:TITL 'sigrok controlled'");
	g_mutex_unlock(&devc->rw_mutex);
	return ret;
}

SR_PRIV int rohde_schwarz_zvx_local(const struct sr_dev_inst *sdi)
{
	int ret;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	g_mutex_lock(&devc->rw_mutex);
	/* disable display updates: */
	ret = sr_scpi_send(scpi, "SYST:DISP:UPD ON");
	g_mutex_unlock(&devc->rw_mutex);

	return ret;
}

SR_PRIV int rohde_schwarz_zvx_sync(const struct sr_dev_inst *sdi)
{
	int ret;

	if ((ret = rohde_schwarz_zvx_read_frequency(sdi)) != SR_OK)
		return ret;
	if ((ret = rohde_schwarz_zvx_read_span(sdi) != SR_OK))
		return ret;
//	if ((ret = rohde_schwarz_zvx_read_ref_level(sdi) != SR_OK))
//		return ret;
	if ((ret = rohde_schwarz_zvx_read_clk_src_idx(sdi)) != SR_OK)
		return ret;

	return SR_OK;
}

/// ************************** band center ********************************** */
SR_PRIV int rohde_schwarz_zvx_read_frequency(const struct sr_dev_inst *sdi)
{
	int ret;
	double frequency;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	frequency = 0.0;
	g_mutex_lock(&devc->rw_mutex);
	ret = sr_scpi_get_double(scpi, "FREQ:CENT?", &frequency);
	g_mutex_unlock(&devc->rw_mutex);
	if (ret != SR_OK)
		return ret;

	if (frequency == 0)
		return SR_ERR;

	devc->frequency = frequency;
	return SR_OK;
}

SR_PRIV int rohde_Schwarz_zvx_minmax_frequency(const struct sr_dev_inst *sdi,
        double *min_freq, double *max_freq)
{
	int ret;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;


	g_mutex_lock(&devc->rw_mutex);
	ret = sr_scpi_get_double(scpi, "FREQ:CENT? MIN", min_freq);
	if (ret != SR_OK) {
		g_mutex_unlock(&devc->rw_mutex);
		return ret;
	}

	ret = sr_scpi_get_double(scpi, "FREQ:CENT? MAX", max_freq);
	g_mutex_unlock(&devc->rw_mutex);
	return ret;
}

SR_PRIV int rohde_schwarz_zvx_set_frequency(const struct sr_dev_inst *sdi,
        double frequency)
{
	int ret;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	if (devc->frequency == frequency)
		return SR_OK;

	devc->frequency = frequency;
	g_mutex_lock(&devc->rw_mutex);
	if ((ret = sr_scpi_send(scpi, "FREQ:CENT %fHz", devc->frequency)) != SR_OK){
		g_mutex_unlock(&devc->rw_mutex);
		return ret;
	}

	ret = sr_scpi_get_double(scpi, "FREQ:SPAN?", &devc->span);
	g_mutex_unlock(&devc->rw_mutex);
	return ret;
}

/// ************************** span ***************************************** */
SR_PRIV int rohde_schwarz_zvx_read_span(const struct sr_dev_inst *sdi)
{
	int ret;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	g_mutex_lock(&devc->rw_mutex);
	ret = sr_scpi_get_double(scpi, "FREQ:SPAN?", &devc->span);
	g_mutex_unlock(&devc->rw_mutex);
	return ret;
}

SR_PRIV int rohde_Schwarz_zvx_minmax_span(const struct sr_dev_inst *sdi,
        double *min_span, double *max_span)
{
	int ret;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	g_mutex_lock(&devc->rw_mutex);
	ret = sr_scpi_get_double(scpi, "FREQ:SPAN? MIN", min_span);
	if (ret != SR_OK) {
		g_mutex_unlock(&devc->rw_mutex);
		return ret;
	}

	ret = sr_scpi_get_double(scpi, "FREQ:SPAN? MAX", max_span);
	g_mutex_unlock(&devc->rw_mutex);
	return ret;
}

SR_PRIV int rohde_schwarz_zvx_set_span(const struct sr_dev_inst *sdi,
        double span)
{
	int ret;
	double new_frequency;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	if (devc->span == span)
		return SR_OK;

	devc->span = span;
	g_mutex_lock(&devc->rw_mutex);
	ret = sr_scpi_send(scpi, "FREQUENCY:SPAN %fHz", devc->span);
	if (ret != SR_OK) {
		g_mutex_unlock(&devc->rw_mutex);
		return ret;
	}

	new_frequency = 0.0;
	ret = sr_scpi_get_double(scpi, "FREQ:CENT?", &new_frequency);
	g_mutex_unlock(&devc->rw_mutex);
	if (ret != SR_OK)
		return ret;
	if (new_frequency == 0.0)
		return SR_ERR;

	return ret;
}

/// ************************** ref level ************************************ */
/*SR_PRIV int rohde_schwarz_zvx_read_ref_level(const struct sr_dev_inst *sdi)
{
	int ret;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	g_mutex_lock(&devc->rw_mutex);
	ret = sr_scpi_get_double(scpi, "DISP:TRAC:Y:RLEV?", &devc->ref_level);
	g_mutex_unlock(&devc->rw_mutex);
	return ret;
}

SR_PRIV int rohde_Schwarz_zvx_minmax_ref_level(const struct sr_dev_inst *sdi,
        double *min_ref_level, double *max_ref_level)
{
	int ret;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	g_mutex_lock(&devc->rw_mutex);
	ret = sr_scpi_get_double(scpi, "DISP:TRAC:Y:RLEV? MIN", min_ref_level);
	if (ret != SR_OK) {
		g_mutex_unlock(&devc->rw_mutex);
		return ret;
	}

	ret = sr_scpi_get_double(scpi, "DISP:TRAC:Y:RLEV? MAX", max_ref_level);
	g_mutex_unlock(&devc->rw_mutex);
	return ret;
}

SR_PRIV int rohde_schwarz_zvx_set_ref_level(const struct sr_dev_inst *sdi,
        double ref_level)
{
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	if (devc->ref_level == ref_level)
		return SR_OK;

	devc->ref_level = ref_level;
	return rs_zvx_scpi_send_rwlocked(sdi, "DISP:TRAC:Y:RLEV %fdBm",
									devc->ref_level);
}*/

/// ************************* clk source ************************************ */
SR_PRIV int rohde_schwarz_zvx_read_clk_src_idx(const struct sr_dev_inst *sdi)
{
	int ret;
	size_t i;
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	char *buf;
	const char *rohde_schwarz_zvx_ref_clk_sources[] = {
		"INT",
		"EXT"
	};

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	buf = NULL;
	g_mutex_lock(&devc->rw_mutex);
	ret = sr_scpi_get_string(scpi, "ROSC:SOUR?", &buf);
	g_mutex_unlock(&devc->rw_mutex);
	if (ret != SR_OK)
		return ret;

	ret = SR_ERR;
	for (i = 0; i < ARRAY_SIZE(rohde_schwarz_zvx_ref_clk_sources); ++i) {
		if (g_strcmp0(rohde_schwarz_zvx_ref_clk_sources[i], buf) == 0) {
			devc->clk_source_idx = (i > 1) ? 1 : 0;
			ret = SR_OK;
			break;
		}
	}

	g_free(buf);
	return ret;
}

SR_PRIV int rohde_schwarz_zvx_set_clk_src(const struct sr_dev_inst *sdi,
        size_t idx)
{
	struct sr_scpi_dev_inst *scpi;
	struct dev_context *devc;

	if (!(scpi = sdi->conn) || !(devc = sdi->priv))
		return SR_ERR;

	if (devc->clk_source_idx == idx)
		return SR_OK;

	devc->clk_source_idx = idx;

	return rs_zvx_scpi_send_rwlocked(sdi, "ROSC:SOUR %s",
									 (idx == 0) ? "INT" : "EXT1");
}

/// ******************************************************************** */
static void rohde_schwarz_zvx_send_packet(const struct sr_dev_inst *sdi)
{
	struct dev_context *devc = sdi->priv;

	struct sr_datafeed_packet packet;
	struct sr_datafeed_analog analog;
	struct sr_analog_encoding encoding;
	struct sr_analog_meaning meaning;
	struct sr_analog_spec spec;

	if (!devc)
		return;

	std_session_send_df_frame_begin(sdi);

	sr_analog_init(&analog, &encoding, &meaning, &spec, 10);
	analog.meaning->mq = SR_MQ_POWER;
	analog.meaning->unit = SR_UNIT_DECIBEL_MW;
	analog.meaning->mqflags = 0;
	analog.meaning->channels = sdi->channels;
	analog.num_samples = devc->sweep_points;
	analog.data = devc->y_vals;
	analog.encoding->unitsize = sizeof(double);
	analog.encoding->is_float = TRUE;
	analog.encoding->digits = 10;

	packet.type = SR_DF_ANALOG;
	packet.payload = &analog;
	sr_session_send(sdi, &packet);

	analog.meaning->mq = SR_MQ_FREQUENCY;
	analog.meaning->unit = SR_UNIT_HERTZ;
	analog.data = devc->x_vals;
	sr_session_send(sdi, &packet);

	sr_sw_limits_update_samples_read(&devc->limits, devc->sweep_points);
	sr_sw_limits_update_frames_read(&devc->limits, 1);

	std_session_send_df_frame_end(sdi);
}

static int rohde_schwarz_zvx_receive_trace(struct sr_scpi_dev_inst *scpi,
        const char *cmd, double *resp, size_t n)
{
	char *buf;
	int ret;
	gchar **strings;

	buf = NULL;
	if ((ret = sr_scpi_get_string(scpi, cmd, &buf)) != SR_OK) {
		sr_spew("%s failed!", cmd);
		return ret;
	}
	strings = g_strsplit(buf, ",", n);
	for (size_t i = 0 ; i < n ; ++i) {
		/* Work with strings, and, when done: */
		gchar *str = strings[i];
		if (str == NULL)
		{
			sr_spew("y data from trace not enough data after %zu samples", i);
			break;
		}
		*resp++ = atof(str);
	}
	g_strfreev(strings);
	g_free(buf);

	return SR_OK;
}

SR_PRIV int rohde_schwarz_zvx_receive_data(int fd, int revents, void *cb_data)
{
	struct sr_dev_inst *sdi;
	struct dev_context *devc;
	struct sr_scpi_dev_inst *scpi;
	int sweep_points;
	int ret;

	(void)fd;
	(void)revents;

	if (!(sdi = cb_data))
		return TRUE;

	if (!(devc = sdi->priv)|| !(scpi = sdi->conn))
		return TRUE;

	g_mutex_lock(&devc->rw_mutex);
	size_t old_sweep_pts = devc->sweep_points;

	ret = sr_scpi_get_int(scpi, "SWEep:POINts?", &sweep_points);
	if (ret != SR_OK) {
		g_mutex_unlock(&devc->rw_mutex);
		return TRUE;
	}
	devc->sweep_points = sweep_points;

	if (old_sweep_pts < devc->sweep_points) {
		free(devc->x_vals);
		devc->x_vals = NULL;
		free(devc->y_vals);
		devc->y_vals = NULL;
	}

	if (!devc->x_vals || !devc->y_vals) {
		if (!devc->x_vals)
			devc->x_vals = g_malloc(devc->sweep_points * sizeof(double));
		if (!devc->y_vals)
			devc->y_vals = g_malloc(devc->sweep_points * sizeof(double));
		if (!devc->x_vals || !devc->y_vals) {
			sr_spew("mem allocation for trace data failed!");
			if (devc->x_vals) {
				g_free(devc->x_vals);
				devc->x_vals = NULL;
			}
			if (devc->y_vals) {
				g_free(devc->y_vals);
				devc->y_vals = NULL;
			}
			g_mutex_unlock(&devc->rw_mutex);
			return TRUE;
		}
	}

	if ((ret = rohde_schwarz_zvx_receive_trace(scpi, "TRACE:DATA? TRACE1",
							devc->y_vals, devc->sweep_points)) != SR_OK) {
		g_mutex_unlock(&devc->rw_mutex);
		return TRUE;
	}
	if ((ret = rohde_schwarz_zvx_receive_trace(scpi, "TRACE:DATA:X? TRACE1",
							devc->x_vals, devc->sweep_points)) != SR_OK) {
		g_mutex_unlock(&devc->rw_mutex);
		return TRUE;
	}
	g_mutex_unlock(&devc->rw_mutex);

	rohde_schwarz_zvx_send_packet(sdi);

	if (sr_sw_limits_check(&devc->limits))
		sr_dev_acquisition_stop(sdi);

	return TRUE;
}

