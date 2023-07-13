/*
 * This file is part of the libsigrok project.
 *
 * Copyright (C) 2016 Eva Kissling <eva.kissling@bluewin.ch>
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

#ifdef _WIN32
#define _WIN32_WINNT 0x0501
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/ioctl.h>
#endif
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include "protocol.h"

/* Top-level command opcodes */
#define CMD_SET_TRIGGER            0x00
#define CMD_CFG_TRIGGER            0xF0
#define CMD_CFG_LA                 0x0F
#define CMD_START                  0xFE
#define CMD_RESET                  0xEE

#define CMD_GET_BUS_WIDTHS         0xAA
#define CMD_GET_LA_ID              0xBB
#define CMD_ESCAPE                 0x55

/* Trigger subfunction command opcodes */
#define CMD_TRIG_MASKS             0xF1
#define CMD_TRIG_MASK              0xF3
#define CMD_TRIG_VALUE             0xF7

#define CMD_TRIG_MASKS_LAST        0xF9
#define CMD_TRIG_MASK_LAST         0xFB
#define CMD_TRIG_VALUE_LAST        0xFF

#define CMD_TRIG_SELECT_EDGE_MASK  0xF5
#define CMD_TRIG_SET_EDGE_MASK     0xF6

/* LA subfunction command opcodes */
#define CMD_LA_DELAY               0x1F

#define CMD_GET_FEATURES           0x10
#define CMD_GET_RLC_WIDTH          0x60
#define CMD_GET_CHANNEL_NAMES      0x70
#define CMD_GET_SAMPLE_RATE        0x80

const uint32_t FEATURE_AUGMENTER_APP_ENABLED =          0x00000001;
const uint32_t FEATURE_RUNLENGTH_CODER_ENABLED =        0x00000002;
const uint32_t FEATURE_AUGMENTER_SAMPLERATE_ENABLED =   0x00000004;
const uint32_t FEATURE_AUGMENTER_CH_NAMES_ENABLED =     0x00000008;


static const uint8_t host_word_size = 8;

static gboolean data_available(struct ipdbg_la_tcp *tcp)
{
#ifdef _WIN32
	u_long bytes_available;
	if (ioctlsocket(tcp->socket, FIONREAD, &bytes_available) != 0) {
#else
	int bytes_available;
	if (ioctl(tcp->socket, FIONREAD, &bytes_available) < 0) { /* TIOCMGET */
#endif
		sr_err("FIONREAD failed: %s\n", g_strerror(errno));
		return FALSE;
	}
	return (bytes_available > 0);
}

SR_PRIV struct ipdbg_la_tcp *ipdbg_la_tcp_new(void)
{
	struct ipdbg_la_tcp *tcp;

	tcp = g_malloc0(sizeof(struct ipdbg_la_tcp));
	tcp->address = NULL;
	tcp->port = NULL;
	tcp->socket = -1;

	return tcp;
}

SR_PRIV void ipdbg_la_tcp_free(struct ipdbg_la_tcp *tcp)
{
	g_free(tcp->address);
	g_free(tcp->port);
}

SR_PRIV int ipdbg_la_tcp_open(struct ipdbg_la_tcp *tcp)
{
	struct addrinfo hints;
	struct addrinfo *results, *res;
	int err;

	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;

	err = getaddrinfo(tcp->address, tcp->port, &hints, &results);

	if (err) {
		sr_err("Address lookup failed: %s:%s: %s", tcp->address,
			tcp->port, gai_strerror(err));
		return SR_ERR;
	}

	for (res = results; res; res = res->ai_next) {
		if ((tcp->socket = socket(res->ai_family, res->ai_socktype,
			res->ai_protocol)) < 0)
			continue;
		if (connect(tcp->socket, res->ai_addr, res->ai_addrlen) != 0) {
			close(tcp->socket);
			tcp->socket = -1;
			continue;
		}
		break;
	}

	freeaddrinfo(results);

	if (tcp->socket < 0) {
		sr_err("Failed to connect to %s:%s: %s", tcp->address, tcp->port,
			g_strerror(errno));
		return SR_ERR;
	}

	return SR_OK;
}

SR_PRIV int ipdbg_la_tcp_close(struct ipdbg_la_tcp *tcp)
{
	int ret = SR_OK;

#ifdef _WIN32
	if (shutdown(tcp->socket, SD_SEND) != SOCKET_ERROR) {
		char recvbuf[16];
		int recvbuflen = 16;
		/* Receive until the peer closes the connection. */
		while (recv(tcp->socket, recvbuf, recvbuflen, 0) > 0);
	}
#endif
	if (close(tcp->socket) < 0)
		ret = SR_ERR;

	tcp->socket = -1;

	return ret;
}

static int tcp_send(struct ipdbg_la_tcp *tcp, const uint8_t *buf, size_t len)
{
	int out;
	out = send(tcp->socket, (const char *)buf, len, 0);

	if (out < 0) {
		sr_err("Send error: %s", g_strerror(errno));
		return SR_ERR;
	}

	if (out < (int)len)
		sr_dbg("Only sent %d/%d bytes of data.", out, (int)len);

	return SR_OK;
}

static int tcp_receive_blocking(struct ipdbg_la_tcp *tcp,
	uint8_t *buf, int bufsize)
{
	int received = 0;
	int error_count = 0;

	/* Timeout after 2s of not receiving data. */
	/* Increase timeout in case lab is not just beside the office. */
	while ((received < bufsize) && (error_count < 2000)) {
		int recd = ipdbg_la_tcp_receive(tcp, buf, bufsize - received);
		if (recd > 0) {
			buf += recd;
			received += recd;
		} else {
			error_count++;
			g_usleep(1000);
		}
	}

	return received;
}

SR_PRIV int ipdbg_la_tcp_receive(struct ipdbg_la_tcp *tcp,
	uint8_t *buf, size_t bufsize)
{
	int received = 0;
	if (data_available(tcp))
		received = recv(tcp->socket, (char *)buf, bufsize, 0);
	if (received < 0) {
		sr_err("Receive error: %s", g_strerror(errno));
		return -1;
	} else
		return received;
}

SR_PRIV int ipdbg_la_convert_trigger(const struct sr_dev_inst *sdi)
{
	struct dev_context *devc;
	struct sr_trigger *trigger;
	struct sr_trigger_stage *stage;
	struct sr_trigger_match *match;
	const GSList *l, *m;

	devc = sdi->priv;

	devc->num_stages = 0;
	devc->num_transfers = 0;
	devc->raw_sample_buf = NULL;

	for (uint64_t i = 0; i < devc->data_width_bytes; i++) {
		devc->trigger_mask[i] = 0;
		devc->trigger_value[i] = 0;
		devc->trigger_mask_last[i] = 0;
		devc->trigger_value_last[i] = 0;
		devc->trigger_edge_mask[i] = 0;
	}

	if (!(trigger = sr_session_trigger_get(sdi->session)))
		return SR_OK;

	for (l = trigger->stages; l; l = l->next) {
		stage = l->data;
		for (m = stage->matches; m; m = m->next) {
			match = m->data;
			int byte_idx = match->channel->index / 8;
			uint8_t match_bit = 1 << (match->channel->index % 8);

			if (!match->channel->enabled)
				/* Ignore disabled channels with a trigger. */
				continue;

			if (match->match == SR_TRIGGER_ONE) {
				devc->trigger_value[byte_idx] |= match_bit;
				devc->trigger_mask[byte_idx] |= match_bit;
				devc->trigger_mask_last[byte_idx] &= ~match_bit;
				devc->trigger_edge_mask[byte_idx] &= ~match_bit;
			} else if (match->match == SR_TRIGGER_ZERO) {
				devc->trigger_value[byte_idx] &= ~match_bit;
				devc->trigger_mask[byte_idx] |= match_bit;
				devc->trigger_mask_last[byte_idx] &= ~match_bit;
				devc->trigger_edge_mask[byte_idx] &= ~match_bit;
			} else if (match->match == SR_TRIGGER_RISING) {
				devc->trigger_value[byte_idx] |= match_bit;
				devc->trigger_value_last[byte_idx] &=
				    ~match_bit;
				devc->trigger_mask[byte_idx] |= match_bit;
				devc->trigger_mask_last[byte_idx] |= match_bit;
				devc->trigger_edge_mask[byte_idx] &= ~match_bit;
			} else if (match->match == SR_TRIGGER_FALLING) {
				devc->trigger_value[byte_idx] &= ~match_bit;
				devc->trigger_value_last[byte_idx] |= match_bit;
				devc->trigger_mask[byte_idx] |= match_bit;
				devc->trigger_mask_last[byte_idx] |= match_bit;
				devc->trigger_edge_mask[byte_idx] &= ~match_bit;
			} else if (match->match == SR_TRIGGER_EDGE) {
				devc->trigger_mask[byte_idx] &= ~match_bit;
				devc->trigger_mask_last[byte_idx] &= ~match_bit;
				devc->trigger_edge_mask[byte_idx] |= match_bit;
			}
		}
	}

	return SR_OK;
}

static int ipdbg_la_runlength_decode(struct dev_context *devc,
	uint64_t *delay_value, uint64_t *total_samples)
{
	if (devc->runlength_code_width == 0) {
		*delay_value = devc->delay_value;
		*total_samples = devc->limit_samples;
		return TRUE;
	}

	uint8_t *raw_sample_buffer = devc->raw_sample_buf;
	const uint64_t total_raw_samples = devc->limit_samples;
	const uint64_t raw_delay_value = devc->delay_value;

	*delay_value = 0;
	*total_samples = 0;

	uint32_t raw_data_width_bytes =
		(devc->data_width + devc->runlength_code_width + host_word_size - 1) /
		host_word_size;
	uint32_t data_width_bytes =
		(devc->data_width + host_word_size - 1) / host_word_size;
	const uint32_t runlength_count_mask =
		(uint32_t)((1ull << devc->runlength_code_width) - 1);
	const uint32_t runlength_code_width_bytes =
		(devc->runlength_code_width + host_word_size - 1) / host_word_size;

	uint32_t *repeats = g_malloc(total_raw_samples * sizeof(uint32_t));
	if (!repeats) {
		sr_err("repeat counters malloc failed");
		return FALSE;
	}
	for (uint64_t i = 0; i < total_raw_samples; ++i) {
		repeats[i] = 0;
		for (size_t byte = 0; byte < runlength_code_width_bytes; ++byte)
			repeats[i] |= (uint32_t)(*(raw_sample_buffer +
				i * raw_data_width_bytes + byte)) <<
					(byte * host_word_size);
		repeats[i] &= runlength_count_mask;
		repeats[i] += 1;
		*total_samples += repeats[i];
		if (i < raw_delay_value)
			*delay_value += repeats[i];
	}

	uint8_t *run_buffer = g_try_malloc(*total_samples * data_width_bytes);
	if (!run_buffer) {
		g_free(repeats);
		sr_err("decoded sample buffer malloc failed.");
		return FALSE;
	}
	devc->raw_sample_buf = run_buffer;

	for (size_t i = 0; i < total_raw_samples; ++i) {
		for (size_t byte = 0; byte < data_width_bytes; ++byte) {
			uint16_t buffer = 0;
			if (devc->runlength_code_width % host_word_size)
			{
				buffer = *(raw_sample_buffer + i * raw_data_width_bytes +
					runlength_code_width_bytes - 1 + byte);
				if (byte < (raw_data_width_bytes - 1))
					buffer |= *(raw_sample_buffer + i * raw_data_width_bytes +
						runlength_code_width_bytes + byte) << 8;

				buffer = buffer >>
					(devc->runlength_code_width % host_word_size);
			} else {
				buffer = *(raw_sample_buffer + i * raw_data_width_bytes +
					runlength_code_width_bytes + byte);
			}
			*run_buffer++ = buffer & 0x00ff;
		}
		for (uint32_t rep = 1; rep < repeats[i]; ++rep) {
			memcpy(run_buffer, run_buffer - data_width_bytes, data_width_bytes);
			run_buffer += data_width_bytes;
		}
	}
	g_free(repeats);
	g_free(raw_sample_buffer);
	return TRUE;
}

SR_PRIV int ipdbg_la_receive_data(int fd, int revents, void *cb_data)
{
	const struct sr_dev_inst *sdi;
	struct dev_context *devc;

	(void)fd;
	(void)revents;

	sdi = cb_data;
	if (!sdi)
		return FALSE;

	if (!(devc = sdi->priv))
		return FALSE;

	struct ipdbg_la_tcp *tcp = sdi->conn;
	struct sr_datafeed_packet packet;
	struct sr_datafeed_logic logic;

	uint32_t raw_data_width_bytes =
		(devc->data_width + devc->runlength_code_width + host_word_size - 1) /
		host_word_size;

	if (!devc->raw_sample_buf) {
		devc->raw_sample_buf =
			g_try_malloc(devc->limit_samples * raw_data_width_bytes);
		if (!devc->raw_sample_buf) {
			sr_err("Sample buffer malloc failed.");
			return FALSE;
		}
	}
	if (devc->num_transfers <
		(devc->limit_samples_max * raw_data_width_bytes)) {
		const size_t bufsize = 1024*16;
		uint8_t buffer[bufsize];

		const int recd = ipdbg_la_tcp_receive(tcp, buffer, bufsize);
		if (recd > 0) {
			int num_move = (((devc->num_transfers + recd) <=
							 (devc->limit_samples * raw_data_width_bytes))
			?
				recd
			:
				(int)((devc->limit_samples * raw_data_width_bytes) -
						devc->num_transfers));
			if (num_move > 0)
				memcpy(&(devc->raw_sample_buf[devc->num_transfers]),
						buffer, num_move);
			devc->num_transfers += recd;

		}
	} else {
		uint64_t delay_value;
		uint64_t total_samples;
		if (!ipdbg_la_runlength_decode(devc, &delay_value, &total_samples)) {
			g_free(devc->raw_sample_buf);
			devc->raw_sample_buf = NULL;
			return FALSE;
		}

		if (delay_value > 0) {
			/* There are pre-trigger samples, send these first. */
			packet.type = SR_DF_LOGIC;
			packet.payload = &logic;
			logic.length = delay_value * devc->data_width_bytes;
			logic.unitsize = devc->data_width_bytes;
			logic.data = devc->raw_sample_buf;
			sr_session_send(cb_data, &packet);
		}

		/* Send the trigger. */
		std_session_send_df_trigger(cb_data);

		/* Send post-trigger samples. */
		packet.type = SR_DF_LOGIC;
		packet.payload = &logic;
		logic.length = (total_samples - delay_value) *
			devc->data_width_bytes;
		logic.unitsize = devc->data_width_bytes;
		logic.data = devc->raw_sample_buf +
			(delay_value * devc->data_width_bytes);
		sr_session_send(cb_data, &packet);

		g_free(devc->raw_sample_buf);
		devc->raw_sample_buf = NULL;

		ipdbg_la_abort_acquisition(sdi);
	}

	return TRUE;
}

static int send_escaping(struct ipdbg_la_tcp *tcp, uint8_t *data_to_send,
	uint32_t length)
{
	uint8_t escape = CMD_ESCAPE;

	while (length--) {
		uint8_t payload = *data_to_send++;

		if (payload == CMD_RESET)
			if (tcp_send(tcp, &escape, 1) != SR_OK)
				sr_warn("Couldn't send escape");

		if (payload == CMD_ESCAPE)
			if (tcp_send(tcp, &escape, 1) != SR_OK)
				sr_warn("Couldn't send escape");

		if (tcp_send(tcp, &payload, 1) != SR_OK)
			sr_warn("Couldn't send data");
	}

	return SR_OK;
}

SR_PRIV int ipdbg_la_send_delay(struct dev_context *devc,
	struct ipdbg_la_tcp *tcp)
{
	devc->delay_value = ((devc->limit_samples - 1) / 100.0) *
		devc->capture_ratio;

	uint8_t buf;
	buf = CMD_CFG_LA;
	tcp_send(tcp, &buf, 1);
	buf = CMD_LA_DELAY;
	tcp_send(tcp, &buf, 1);

	uint8_t delay_buf[4] = { devc->delay_value & 0x000000ff,
		(devc->delay_value >> 8) & 0x000000ff,
		(devc->delay_value >> 16) & 0x000000ff,
		(devc->delay_value >> 24) & 0x000000ff
	};

	for (uint64_t i = 0; i < devc->addr_width_bytes; i++)
		send_escaping(tcp, &(delay_buf[devc->addr_width_bytes - 1 - i]), 1);

	return SR_OK;
}

SR_PRIV int ipdbg_la_send_trigger(struct dev_context *devc,
	struct ipdbg_la_tcp *tcp)
{
	uint8_t buf;

	/* Mask */
	buf = CMD_CFG_TRIGGER;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_MASKS;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_MASK;
	tcp_send(tcp, &buf, 1);

	for (size_t i = 0; i < devc->data_width_bytes; i++)
		send_escaping(tcp,
			devc->trigger_mask + devc->data_width_bytes - 1 - i, 1);

	/* Value */
	buf = CMD_CFG_TRIGGER;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_MASKS;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_VALUE;
	tcp_send(tcp, &buf, 1);

	for (size_t i = 0; i < devc->data_width_bytes; i++)
		send_escaping(tcp,
			devc->trigger_value + devc->data_width_bytes - 1 - i, 1);

	/* Mask_last */
	buf = CMD_CFG_TRIGGER;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_MASKS_LAST;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_MASK_LAST;
	tcp_send(tcp, &buf, 1);

	for (size_t i = 0; i < devc->data_width_bytes; i++)
		send_escaping(tcp,
			devc->trigger_mask_last + devc->data_width_bytes - 1 - i, 1);

	/* Value_last */
	buf = CMD_CFG_TRIGGER;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_MASKS_LAST;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_VALUE_LAST;
	tcp_send(tcp, &buf, 1);

	for (size_t i = 0; i < devc->data_width_bytes; i++)
		send_escaping(tcp,
			devc->trigger_value_last + devc->data_width_bytes - 1 - i, 1);

	/* Edge_mask */
	buf = CMD_CFG_TRIGGER;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_SELECT_EDGE_MASK;
	tcp_send(tcp, &buf, 1);
	buf = CMD_TRIG_SET_EDGE_MASK;
	tcp_send(tcp, &buf, 1);

	for (size_t i = 0; i < devc->data_width_bytes; i++)
		send_escaping(tcp,
			devc->trigger_edge_mask + devc->data_width_bytes - 1 - i, 1);

	return SR_OK;
}

SR_PRIV void ipdbg_la_get_addrwidth_and_datawidth(
	struct ipdbg_la_tcp *tcp, struct dev_context *devc)
{
	uint8_t buf[8];
	uint8_t read_cmd = CMD_GET_BUS_WIDTHS;

	if (tcp_send(tcp, &read_cmd, 1) != SR_OK)
		sr_warn("Can't send read command");

	if (tcp_receive_blocking(tcp, buf, 8) != 8)
		sr_warn("Can't get address and data width from device");

	devc->data_width = buf[0] & 0x000000FF;
	devc->data_width |= (buf[1] << 8) & 0x0000FF00;
	devc->data_width |= (buf[2] << 16) & 0x00FF0000;
	devc->data_width |= (buf[3] << 24) & 0xFF000000;

	devc->addr_width = buf[4] & 0x000000FF;
	devc->addr_width |= (buf[5] << 8) & 0x0000FF00;
	devc->addr_width |= (buf[6] << 16) & 0x00FF0000;
	devc->addr_width |= (buf[7] << 24) & 0xFF000000;

	devc->data_width_bytes =
		(devc->data_width + host_word_size - 1) / host_word_size;
	devc->addr_width_bytes =
		(devc->addr_width + host_word_size - 1) / host_word_size;

	devc->limit_samples_max = (0x01 << devc->addr_width);
	devc->limit_samples = devc->limit_samples_max;

	devc->trigger_mask = g_malloc0(devc->data_width_bytes);
	devc->trigger_value = g_malloc0(devc->data_width_bytes);
	devc->trigger_mask_last = g_malloc0(devc->data_width_bytes);
	devc->trigger_value_last = g_malloc0(devc->data_width_bytes);
	devc->trigger_edge_mask = g_malloc0(devc->data_width_bytes);
}

static void ipdbg_la_init_runlength_coding(
	struct ipdbg_la_tcp *tcp, struct dev_context *devc)
{

	if (!(devc->features & FEATURE_RUNLENGTH_CODER_ENABLED)) {
		devc->runlength_code_width = 0;
		return;
	}

	uint8_t buf[1];
	uint8_t features_cmd = CMD_GET_RLC_WIDTH;

	if (tcp_send(tcp, &features_cmd, 1) != SR_OK) {
		sr_warn("Can't send get runlength counter width command");
		devc->runlength_code_width = 0;
		return;
	}

	if (tcp_receive_blocking(tcp, buf, 1) != 1) {
		sr_warn("Can't get runlength counter width from device");
		devc->runlength_code_width = 0;
		return;
	}

	devc->runlength_code_width = buf[0];
}

static void idpbg_la_init_features(
	struct ipdbg_la_tcp *tcp, struct dev_context *devc)
{
	ipdbg_la_init_runlength_coding(tcp, devc);
}

SR_PRIV void ipdbg_la_get_features(
	struct ipdbg_la_tcp *tcp, struct dev_context *devc)
{
	uint8_t buf[4];
	uint8_t features_cmd = CMD_GET_FEATURES;

	if (devc->version == 0) {
		devc->features = 0;
		return;
	}

	if (tcp_send(tcp, &features_cmd, 1) != SR_OK) {
		sr_warn("Can't send get features command");
		devc->features = 0;
		return;
	}

	if (tcp_receive_blocking(tcp, buf, 4) != 4) {
		sr_warn("Can't get features from device");
		devc->features = 0;
		return;
	}

	devc->features = buf[0] & 0x000000FF;
	devc->features |= (buf[1] << 8) & 0x0000FF00;
	devc->features |= (buf[2] << 16) & 0x00FF0000;
	devc->features |= (buf[3] << 24) & 0xFF000000;

	idpbg_la_init_features(tcp, devc);
}

SR_PRIV void ipdb_la_channel_new_default_name(struct sr_dev_inst *sdi, int i)
{
	char *name = g_strdup_printf("CH%d", i);
	sr_channel_new(sdi, i, SR_CHANNEL_LOGIC, TRUE, name);
	g_free(name);
}

SR_PRIV void ipdb_la_set_default_channel_names(struct sr_dev_inst *sdi)
{
	struct dev_context *devc = sdi->priv;
	const uint32_t number_of_channels = devc->data_width;

	for (uint32_t i = 0; i < number_of_channels; i++)
		ipdb_la_channel_new_default_name(sdi, i);
}

SR_PRIV void ipdbg_la_set_channel_names_and_groups(struct sr_dev_inst *sdi)
{
	struct dev_context *devc = sdi->priv;
	struct ipdbg_la_tcp *tcp = sdi->conn;
	uint8_t request_channel_names_cmd = CMD_GET_CHANNEL_NAMES;
	const uint8_t number_of_channels = devc->data_width;

	if (!(devc->features & FEATURE_AUGMENTER_CH_NAMES_ENABLED)) {
		/* set default channel names */
		ipdb_la_set_default_channel_names(sdi);
		return;
	}

	if (tcp_send(tcp, &request_channel_names_cmd, 1) != SR_OK) {
		sr_warn("Can't send cmd get channel names");
		/* set default channel names */
		ipdb_la_set_default_channel_names(sdi);
		return;
	}

	if (tcp_send(tcp, &number_of_channels, 1) != SR_OK) {
		sr_warn("Can't send number of channels");
		/* set default channel names */
		ipdb_la_set_default_channel_names(sdi);
		return;
	}

	for (uint8_t i = 0; i < number_of_channels; i++) {
		/* get channel name length */
		uint8_t channel_name_lenght;
		if (tcp_receive_blocking(tcp, &channel_name_lenght, 1) != 1) {
			sr_warn("Can't get channel name length");
			ipdb_la_channel_new_default_name(sdi, i);
			continue;
		}
		/* get channel name */
		char channel_name[channel_name_lenght + 1];
		channel_name[channel_name_lenght] = '\0';
		if (tcp_receive_blocking(tcp, (uint8_t*)channel_name,
			channel_name_lenght) != channel_name_lenght) {
			sr_warn("Can't get channel name of CH%d", i);
			ipdb_la_channel_new_default_name(sdi, i);
		}
		else
			sr_channel_new(sdi, i, SR_CHANNEL_LOGIC, TRUE, channel_name);
	}
	return;
}

SR_PRIV void ipdbg_la_set_samplerate(struct sr_dev_inst *sdi)
{
	struct dev_context *devc = sdi->priv;
	struct ipdbg_la_tcp *tcp = sdi->conn;
	const size_t buffer_size = 8;
	uint8_t buf[buffer_size];
	const uint8_t features_cmd = CMD_GET_SAMPLE_RATE;

	/* no samplerate to set */
	if (!(devc->features & FEATURE_AUGMENTER_SAMPLERATE_ENABLED))
		return;

	if (tcp_send(tcp, &features_cmd, 1) != SR_OK) {
		sr_warn("Can't send cmd get sample rate");
		/* no samplerate to set */
		return;
	}

	if (tcp_receive_blocking(tcp, buf, buffer_size) != buffer_size) {
		sr_warn("Can't receive sample rate");
		/* no samplerate to set */
		return;
	}

	devc->cur_samplerate  =  (uint64_t)buf[0]        & 0x00000000000000FF;
	devc->cur_samplerate |= ((uint64_t)buf[1] <<  8) & 0x000000000000FF00;
	devc->cur_samplerate |= ((uint64_t)buf[2] << 16) & 0x0000000000FF0000;
	devc->cur_samplerate |= ((uint64_t)buf[3] << 24) & 0x00000000FF000000;
	devc->cur_samplerate |= ((uint64_t)buf[4] << 32) & 0x000000FF00000000;
	devc->cur_samplerate |= ((uint64_t)buf[5] << 40) & 0x0000FF0000000000;
	devc->cur_samplerate |= ((uint64_t)buf[6] << 48) & 0x00FF000000000000;
	devc->cur_samplerate |= ((uint64_t)buf[7] << 56) & 0xFF00000000000000;
}

SR_PRIV struct dev_context *ipdbg_la_dev_new(void)
{
	struct dev_context *devc;

	devc = g_malloc0(sizeof(struct dev_context));
	devc->capture_ratio = 50;

	return devc;
}

SR_PRIV int ipdbg_la_send_reset(struct ipdbg_la_tcp *tcp)
{
	uint8_t buf = CMD_RESET;
	if (tcp_send(tcp, &buf, 1) != SR_OK)
		sr_warn("Couldn't send reset");

	return SR_OK;
}

SR_PRIV int ipdbg_la_request_id(struct ipdbg_la_tcp *tcp, uint8_t *version)
{
	uint8_t buf = CMD_GET_LA_ID;
	if (tcp_send(tcp, &buf, 1) != SR_OK)
		sr_warn("Couldn't send ID request");

	char id[4];
	if (tcp_receive_blocking(tcp, (uint8_t *)id, 4) != 4) {
		sr_err("Couldn't read device ID");
		return SR_ERR;
	}

	int cmp_IDBG = strncmp(id, "IDBG", 4);
	int cmp_idbg = strncmp(id, "idbg", 4);
	if (!cmp_IDBG && !cmp_idbg) {
		sr_err("Invalid device ID: expected 'idbg' or 'IDBG', got '%c%c%c%c'.",
			id[0], id[1], id[2], id[3]);
		return SR_ERR;
	}
	*version = (cmp_IDBG == 0) ? 0 : 1;

	return SR_OK;
}

SR_PRIV void ipdbg_la_abort_acquisition(const struct sr_dev_inst *sdi)
{
	struct ipdbg_la_tcp *tcp = sdi->conn;

	sr_session_source_remove(sdi->session, tcp->socket);

	std_session_send_df_end(sdi);
}

SR_PRIV int ipdbg_la_send_start(struct ipdbg_la_tcp *tcp)
{
	uint8_t buf = CMD_START;

	if (tcp_send(tcp, &buf, 1) != SR_OK)
		sr_warn("Couldn't send start");

	return SR_OK;
}
