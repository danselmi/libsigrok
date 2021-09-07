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

#ifndef LIBSIGROK_HARDWARE_ROHDE_SCHWARZ_FSX_PROTOCOL_H
#define LIBSIGROK_HARDWARE_ROHDE_SCHWARZ_FSX_PROTOCOL_H

#include <stdint.h>
#include <glib.h>
#include <libsigrok/libsigrok.h>
#include "libsigrok-internal.h"

#define LOG_PREFIX "rohde-schwarz-fsx"

struct dev_context {
	GMutex rw_mutex;
	double frequency;          /* Hz */
	double span;               /* Hz */
	uint64_t rbw;              /* Hz */
	uint64_t vbw;              /* Hz */
	double ref_level;        /* dBm */
	size_t clk_source_idx;
	size_t alloced_points_mem;
	size_t sweep_points;
	double *vals;
	struct sr_sw_limits limits;
	double freq_min;
	double freq_max;
	double span_min;
	double span_max;
	double ref_level_min;
	double ref_level_max;
	const uint64_t *rbws;
	size_t num_rbws;
	const uint64_t *vbws;
	size_t num_vbws;
	char *received_cmd_str;
};

SR_PRIV int rs_fsw_and_fsv_receive_data(int fd, int revents, void *cb_data);

SR_PRIV int rs_fsw_and_fsv_preset(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_init(struct sr_scpi_dev_inst *scpi);
SR_PRIV int rs_fsw_and_fsv_local(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_remote(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_sync(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_minmax_frequency(const struct sr_dev_inst *sdi, double *min_freq, double *max_freq);
SR_PRIV int rs_fsw_and_fsv_read_frequency(
            const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_minmax_span(const struct sr_dev_inst *sdi,
            double *min_span, double *max_span);
SR_PRIV int rs_fsw_and_fsv_read_span(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_read_rbw(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_read_vbw(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_minmax_ref_level(const struct sr_dev_inst *sdi,
            double *min_ref_level,double *max_ref_level);
SR_PRIV int rs_fsw_and_fsv_read_ref_level(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_read_detector(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_read_clk_src_idx(const struct sr_dev_inst *sdi);
SR_PRIV int rs_fsw_and_fsv_set_frequency(const struct sr_dev_inst *sdi,
            double freq);
SR_PRIV int rs_fsw_and_fsv_set_span(const struct sr_dev_inst *sdi, double span);
SR_PRIV int rs_fsw_and_fsv_set_rbw(const struct sr_dev_inst *sdi, uint64_t rbw);
SR_PRIV int rs_fsw_and_fsv_set_vbw(const struct sr_dev_inst *sdi, uint64_t vbw);
SR_PRIV int rs_fsw_and_fsv_set_ref_level(const struct sr_dev_inst *sdi,
            double ref_level);
SR_PRIV int rs_fsw_and_fsv_set_clk_src(const struct sr_dev_inst *sdi, size_t idx);


SR_PRIV int rs_fsw_and_fsv_cmd_set(const struct sr_dev_inst *sdi, const char *cmd);
SR_PRIV int rs_fsw_and_fsv_cmd_req(const struct sr_dev_inst *sdi, const char *cmd);

#endif

