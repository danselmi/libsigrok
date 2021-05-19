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

#include "config.h"

#include <glib.h>
#include <gmodule.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <libsigrok/libsigrok.h>
#include "libsigrok-internal.h"

#define LOG_PREFIX "input/touchstone"
#define INITIAL_DATA_SET_SIZE 512

enum parameter_kinds {
	KIND_SCATTERING_PARAMETERS = SR_MQFLAG_N_PORT_S_PARAMETER,
	KIND_IMPEDANCE_PARAMETERS  = SR_MQFLAG_N_PORT_Z_PARAMETER,
	KIND_ADMITTANCE_PARAMETERS = SR_MQFLAG_N_PORT_Y_PARAMETER,
	KIND_HYBRID_G_PARAMETERS   = SR_MQFLAG_TWO_PORT_G_PARAMETER,
	KIND_HYBRID_H_PARAMETERS   = SR_MQFLAG_TWO_PORT_H_PARAMETER,
};

enum number_formats {
	FORMAT_DB_ANGLE,        /* DB */
	FORMAT_MAGNITUDE_ANGLE, /* MA */
	FORMAT_REAL_IMAGINARY,  /* RI */
};

enum parser_states {
	PS_START_FILE,
	PS_OPTION_LINE,
	PS_NUM_PORTS,
	PS_KEYWORDS,
	PS_REFERENCES,
	PS_SKIP_INFO,
	PS_DATA_LINES,
	PS_NOISE_DATA
};

enum two_port_data_orders {
	TP_ORDER_12_21,
	TP_ORDER_21_12
};

enum matrix_formats {
	MF_FULL,
	MF_LOWER,
	MF_UPPER
};

struct context {
	double frequency_unit;
	double last_freq;
	double reference_resistance;
	double *reference_resistances;
	int parameter_kind;
	int number_format;
	int two_port_data_order;
	int matrix_format;
	size_t sweep_points;
	size_t sweep_points_noise;
	int state;
	size_t num_ports;
	size_t num_references_found;
	size_t num_vals_per_set;
	uint8_t file_version;
	gboolean started;

	double *data_set;
	size_t data_set_size;
	size_t data_set_count;

	double *sweep_freq;
	double *sweep_data;
	size_t sweep_count;
	size_t sweep_size;

	struct sr_datafeed_packet packet;
	struct sr_datafeed_analog analog;
	struct sr_analog_encoding encoding;
	struct sr_analog_meaning meaning;
	struct sr_analog_spec spec;
};

static void conv_len(double *a, void(conv)(double*), size_t N)
{
	while(N--) {
		conv(a);
		a += 2;
	}
}

static void convri(double *a)
{
	double *b = a+1;
	double r = *a;
	double i = *b;
	*a = sqrt(r*r + i*i);

	if (r == 0.0 && i == 0.0) {
		*b = 0.0;
		return;
	}
	*b = atan2(i, r);
}

static void convma(double *a)
{
	a++;
	*a = *a / 180.0 * acos(-1.0);
}

static void convdba(double *a)
{
	*a = pow(10.0, *a / 20.0);
	convma(a);
}

static void confNF2F(double *a)
{
	*a = pow(10.0, *a / 10.0);
}

static void swap(double *a, double *b)
{
	double t = *a;
	*a = *b;
	*b = t;
}

static void swap21_12(double *vals)
{
	// 21: [2] [3] <->  12: [4] [5]
	swap(vals + 2, vals + 4);
	swap(vals + 3, vals + 5);
}

static void fill_lower(double *a, size_t N)
{
	size_t i, j;
	for (i = 0; i < N-1 ; ++i)
		for (j = i+1 ; j < N ; ++j) {
			a[2*(j*N+i)]    = a[2*(i*N+j)];
			a[2*(j*N+i)+ 1] = a[2*(i*N+j)+ 1];
		}
}

static void fill_upper(double *a, size_t N)
{
	size_t i, j;
	for (i = 0; i < N-1 ; ++i)
		for (j = i+1 ; j < N ; ++j) {
			a[2*(i*N+j)]    = a[2*(j*N+i)];
			a[2*(i*N+j)+ 1] = a[2*(j*N+i)+ 1];
		}
}

static const char* default_dot_exts[] =
		{".s1p", ".s2p",".s3p",".s4p",".s5p",".s6p",".s7p",".s8p", NULL};

static const char* default_exts[] =
		{"s1p", "s2p","s3p","s4p","s5p","s6p","s7p","s8p", NULL};

static int format_match(GHashTable *metadata, unsigned int *confidence)
{
	const char *fn;
	size_t i;
	GString *buf;

	fn = g_hash_table_lookup(metadata, GINT_TO_POINTER(SR_INPUT_META_FILENAME));
	buf = g_hash_table_lookup(metadata, GINT_TO_POINTER(SR_INPUT_META_HEADER));

	/* File names are a strong hint. Use then when available. */
	if (fn && *fn) {
		for (i = 0 ;  default_dot_exts[i] ; ++i) {
			if (g_str_has_suffix(fn, default_dot_exts[i])) {
				*confidence = 10;
				return SR_OK;
			}
		}
	}

	if (!buf || !buf->len || !buf->str || !*buf->str)
		return SR_ERR;
	//TODO: check for option line or version keyword

	return SR_ERR;
}

static void init_context(struct context *inc, GSList *channels)
{
	inc->packet.type = SR_DF_ANALOG;
	inc->packet.payload = &inc->analog;

	inc->analog.data = NULL;
	inc->analog.num_samples = 0;
	inc->analog.encoding = &inc->encoding;
	inc->analog.meaning = &inc->meaning;
	inc->analog.spec = &inc->spec;

	inc->encoding.unitsize = sizeof(double);
	inc->encoding.is_signed = TRUE;
	inc->encoding.is_float = TRUE;
#ifdef WORDS_BIGENDIAN
	inc->encoding.is_bigendian = TRUE;
#else
	inc->encoding.is_bigendian = FALSE;
#endif
	inc->encoding.digits = 15;
	inc->encoding.is_digits_decimal = TRUE;
	inc->encoding.offset.p = 0;
	inc->encoding.offset.q = 1;
	inc->encoding.scale.p = 1;
	inc->encoding.scale.q = 1;

	inc->meaning.channels = channels;
	/// TODO:
	inc->spec.spec_digits = 0;
}

static int init(struct sr_input *in, GHashTable *options)
{
	struct context *inc;
	(void)options;

	in->sdi = g_malloc0(sizeof(struct sr_dev_inst));
	in->priv = inc = g_malloc0(sizeof(struct context));

	inc->started = FALSE;

	sr_channel_new(in->sdi, 0, SR_CHANNEL_ANALOG, TRUE, "CH1");

	init_context(inc, in->sdi->channels);
	inc->state = PS_START_FILE;
	inc->num_ports = 0;
	inc->num_vals_per_set = 0;
	inc->two_port_data_order = TP_ORDER_21_12;
	inc->matrix_format = MF_FULL;
	inc->sweep_points = 0;
	inc->sweep_points_noise = 0;
	inc->num_references_found = 0;
	inc->reference_resistances = NULL;

	inc->data_set = NULL;
	inc->data_set_size = 0;
	inc->data_set_count = 0;
	inc->sweep_freq = NULL;
	inc->sweep_data = NULL;
	inc->sweep_count = 0;
	inc->sweep_size = 0;

	return SR_OK;
}

static void strip_comment(char *line)
{
	char *ptr;

	if ((ptr = strstr(line, "!"))) {
		*ptr = '\0';
	}
	g_strstrip(line);
}

static int parse_option_line(struct context *inc, char *option_line)
{
	/* option line parameters may appear in any order. */

	char *ptr;
	int ret;
	GString *line = g_string_new(option_line);

	//g_string_replace(line, '#', ' ', 0);
	line->str[0] = ' ';
	g_string_append_c(line, ' ');

	ret = SR_OK;

	ptr = g_strstr_len(line->str, -1, "HZ ");
	if (ptr) {
		--ptr; // we always have at least a ' ' in front
		switch (*ptr) {
		case 'K':
			inc->frequency_unit = 1000.0;
			sr_spew("option line using kHz");
			break;
		case 'M':
			inc->frequency_unit = 1e6;
			sr_spew("option line using MHz");
			break;
		case 'G':
			inc->frequency_unit = 1e9;
			sr_spew("option line using GHz");
			break;
		case ' ':
			inc->frequency_unit = 1.0;
			sr_spew("option line using Hz");
			break;
		/* no valid si unit prefix found */
		default:
			sr_err("option line no known unit prefix found: '%s'", line->str);
			return SR_ERR;
		}
	}
	else {
		sr_spew("option line using default frequency");
		inc->frequency_unit = 1e9;
	}

	if (g_strstr_len(line->str, -1, " DB ")) {
		sr_spew("found option line data format: dB & angle");
		inc->number_format = FORMAT_DB_ANGLE;
	}
	else if (g_strstr_len(line->str, -1, " MA ")) {
		sr_spew("found option line data format: magnitude & angle");
		inc->number_format = FORMAT_MAGNITUDE_ANGLE;
	}
	else if (g_strstr_len(line->str, -1, " RI ")) {
		sr_spew("found option line data format: real & imaginary");
		inc->number_format = FORMAT_REAL_IMAGINARY;
	}
	else {
		sr_spew("using default data format dB & angle");
		inc->number_format = FORMAT_MAGNITUDE_ANGLE;
	}

	if (g_strstr_len(line->str, -1, " S ")) {
		sr_spew("found option line for scattering parameters");
		inc->parameter_kind = KIND_SCATTERING_PARAMETERS;
	}
	else if (g_strstr_len(line->str, -1, " Y ")) {
		sr_spew("found option line for admittance parameters");
		inc->parameter_kind = KIND_ADMITTANCE_PARAMETERS;
	}
	else if (g_strstr_len(line->str, -1, " Z ")) {
		sr_spew("found option line for impedance parameters");
		inc->parameter_kind = KIND_IMPEDANCE_PARAMETERS;
	}
	else if (g_strstr_len(line->str, -1, " G ")) {
		sr_spew("found option line for hybrid G parameters");
		inc->parameter_kind = KIND_HYBRID_G_PARAMETERS;
	}
	else if (g_strstr_len(line->str, -1, " H ")) {
		sr_spew("found option line for hybrid H parameters");
		inc->parameter_kind = KIND_HYBRID_H_PARAMETERS;
	}
	else {
		sr_spew("using default parameter kind: scattering parameters");
		inc->parameter_kind = KIND_SCATTERING_PARAMETERS;
	}

	ptr = g_strstr_len(line->str, -1, " R ");
	if (ptr) {
		ptr += 3;
		g_strchug(ptr);
		ret = sr_atod(ptr, &inc->reference_resistance);
		sr_spew("option line found reference resistance: %f",
				inc->reference_resistance);
	}
	else {
		sr_spew("using default reference resistance: 50");
		inc->reference_resistance = 50.0;
	}

	g_string_free(line, TRUE);

	return ret;
}

static int parse_version_line(struct context *inc, char *version_line)
{
	char *ptr;
	const char *version_keyword = "[VERSION]";

	if (!g_str_has_prefix(version_line, version_keyword))
		return SR_ERR;

	ptr = version_line + strlen(version_keyword);
	g_strchug(ptr);

	if (g_str_has_prefix(ptr, "2.0")) {
		inc->file_version = 2;
		return SR_OK;
	}

	return SR_ERR;
}

static uint16_t sqrti(uint32_t a) {
	uint32_t rem = 0, root = 0;

	for (int i = 32 / 2; i > 0; i--) {
		root <<= 1;
		rem = (rem << 2) | (a >> (32 - 2));
		a <<= 2;
		if (root < rem) {
				rem -= root | 1;
				root += 2;
		}
	}
	return root >> 1;
}

static int send_reference_information(struct sr_input *in)
{
	struct context *inc = in->priv;
	size_t idx;

	sr_spew("sending reference resistance information");

	inc->meaning.mq = SR_MQ_RESISTANCE;
	inc->meaning.unit = SR_UNIT_OHM;
	inc->meaning.mqflags = SR_MQFLAG_REFERENCE;

	if (!inc->reference_resistances) {
		inc->reference_resistances = g_malloc(sizeof(double) * inc->num_ports);
		if (!inc->reference_resistances)
			return SR_ERR;
		for (idx = 0; idx < inc->num_ports ; ++idx)
			inc->reference_resistances[idx] = inc->reference_resistance;
	}

	/*  version 2 has "no" reference for other than s parameters */
	if (inc->file_version > 1 &&
			inc->parameter_kind != KIND_SCATTERING_PARAMETERS) {
		for (idx = 0; idx < inc->num_ports ; ++idx)
			inc->reference_resistances[idx] = 1.0;
	}

	inc->analog.data = inc->reference_resistances;
	inc->analog.num_samples = inc->num_ports;

	return sr_session_send(in->sdi, &inc->packet);
}

static int send_sweep_information(struct sr_input *in)
{
	struct context *inc = in->priv;
	int ret;

	if (inc->sweep_count == 0)
		return SR_OK;

	inc->meaning.mq = SR_MQ_FREQUENCY;
	inc->meaning.unit = SR_UNIT_HERTZ;
	inc->meaning.mqflags = 0;

	inc->analog.data = inc->sweep_freq;
	inc->analog.num_samples = inc->sweep_count;

	if ((ret = sr_session_send(in->sdi, &inc->packet)) != SR_OK)
		return ret;

	inc->meaning.mq = SR_MQ_N_PORT_PARAMETER;
	/** we send the reference resistance so this is unit less */
	inc->meaning.unit = SR_UNIT_UNITLESS;
	inc->meaning.mqflags = (inc->state == PS_NOISE_DATA) ?
			SR_MQFLAG_TWO_PORT_NOISE_DATA : inc->parameter_kind;

	inc->analog.data = inc->sweep_data;
	inc->analog.num_samples = inc->sweep_count *
			((inc->state == PS_NOISE_DATA) ? 5 :
			  inc->num_ports * inc->num_ports * 2);

	inc->sweep_count = 0;

	if ((ret = sr_session_send(in->sdi, &inc->packet)) != SR_OK)
		return ret;

	return SR_OK;
}

static int prepare_data_set_memory(struct context *inc, size_t min_cap)
{
	if (!inc->data_set)
	{
		inc->data_set = g_malloc(INITIAL_DATA_SET_SIZE * sizeof(double));
		if (!inc->data_set){
			sr_err("failed to alloc memory");
			return SR_ERR;
		}
		inc->data_set_count = 0;
		inc->data_set_size  = INITIAL_DATA_SET_SIZE;
	}

	if (inc->data_set_count + min_cap > inc->data_set_size)
	{
		double *ptr;
		ptr = g_malloc((inc->data_set_size + INITIAL_DATA_SET_SIZE)*sizeof(double));
		if (!ptr){
			sr_err("failed to alloc memory");
			return SR_ERR;
		}
		memcpy(ptr, inc->data_set, sizeof(double) * inc->data_set_count);

		g_free(inc->data_set);
		inc->data_set = ptr;
	}
	return SR_OK;
}

static int add_data_to_set(struct context *inc, double *vals, size_t n)
{
	int ret;

	if ((ret = prepare_data_set_memory(inc, n)) != SR_OK)
		return ret;

	sr_spew("adding data to set");

	memcpy(inc->data_set + inc->data_set_count, vals, n*sizeof(double));
	inc->data_set_count += n;
	return SR_OK;
}

static int prepare_sweep_mem(struct context *inc)
{
	size_t sweep_points;
	const size_t data_set_entries = (inc->state == PS_NOISE_DATA) ? 5 :
			(inc->num_ports * inc->num_ports * 2);

	if (inc->sweep_size == 0) {
		if (inc->file_version > 1 && inc->sweep_points > 0)
			sweep_points = inc->sweep_points;
		else
			sweep_points = INITIAL_DATA_SET_SIZE;
		inc->sweep_freq = g_malloc(sizeof(double) * sweep_points);
		inc->sweep_data = g_malloc(sizeof(double) * sweep_points * data_set_entries);

		if (!inc->sweep_freq || !inc->sweep_data) {
			sr_err("failed to alloc memory");
			return SR_ERR;
		}
		inc->sweep_size = sweep_points;
	}
	else if (inc->sweep_count == inc->sweep_size) {
		double *ptr_f, *ptr_d;
		ptr_f = g_malloc(sizeof(double) *
						(inc->sweep_size + INITIAL_DATA_SET_SIZE));
		ptr_d = g_malloc(sizeof(double) *
						(inc->sweep_size + INITIAL_DATA_SET_SIZE) *
						data_set_entries);

		if (!ptr_f || !ptr_d) {
			sr_err("failed to alloc memory");
			return SR_ERR;
		}

		memcpy(ptr_f, inc->sweep_freq, inc->sweep_count*sizeof(double));
		memcpy(ptr_d, inc->sweep_data, inc->sweep_count*sizeof(double)*data_set_entries);
		g_free(inc->sweep_freq);
		g_free(inc->sweep_data);
		inc->sweep_freq = ptr_f;
		inc->sweep_data = ptr_d;
		inc->sweep_size += INITIAL_DATA_SET_SIZE;
	}
	return SR_OK;
}

static int move_data_to_sweep(struct context *inc)
{
	int ret;
	double *ptr;
	const size_t data_set_entries = (inc->state == PS_NOISE_DATA) ? 5 :
			(inc->num_ports * inc->num_ports * 2);
	double new_freq = inc->data_set[0];

	if (inc->num_ports == 0 )
		return SR_ERR;

	sr_spew("adding data-set to sweep");

	if ((ret = prepare_sweep_mem(inc)) != SR_OK)
		return ret;

	inc->sweep_freq[inc->sweep_count] = new_freq * inc->frequency_unit;
	sr_spew("add sweep point at %f Hz", new_freq * inc->frequency_unit);
	inc->last_freq = new_freq;

	ptr = &inc->sweep_data[inc->sweep_count*data_set_entries];
	if (inc->state == PS_DATA_LINES) {
		if (inc->matrix_format == MF_FULL) {
			sr_spew("moving full matrix");
			memcpy(ptr, &inc->data_set[1],
					(inc->num_vals_per_set-1) * sizeof(double));
		}
		else {
			size_t idx = 1;
			if (inc->matrix_format == MF_UPPER) {
				sr_spew("moving upper matrix");
				for (size_t i = 0 ; i < inc->num_ports ; ++i) {
					size_t row_len = 2 * (inc->num_ports - i);
					size_t offs = i * (inc->num_ports + 1) * 2;
					memcpy(ptr + offs, inc->data_set + idx,
							row_len * sizeof(double));
					idx += row_len;
				}
			}
			else { /* (inc->matrix_format == MF_LOWER) { */
				sr_spew("moving lower matrix");
				for (size_t i = 0 ; i < inc->num_ports ; ++i) {
					size_t row_len = 2 * (i+1);
					size_t offs = i * inc->num_ports * 2;
					memcpy(ptr + offs, inc->data_set + idx,
							row_len * sizeof(double));
					idx += row_len;
				}
			}
		}

		if (inc->number_format == FORMAT_DB_ANGLE)
			conv_len(ptr, convdba, inc->num_vals_per_set/2);
		else if (inc->number_format == FORMAT_MAGNITUDE_ANGLE)
			conv_len(ptr, convma, inc->num_vals_per_set/2);
		else /* FORMAT_REAL_IMAGINARY */
			conv_len(ptr, convri, inc->num_vals_per_set/2);

		if (inc->matrix_format == MF_UPPER)
			fill_lower(ptr, inc->num_ports);
		else if(inc->matrix_format == MF_LOWER)
			fill_upper(ptr, inc->num_ports);

		if (inc->num_ports == 2 && inc->two_port_data_order == TP_ORDER_21_12)
			swap21_12(ptr);
	}
	else
	{
		confNF2F(&inc->data_set[1]);
		convma(&inc->data_set[2]); // reflection coefficient
		memcpy(ptr, &inc->data_set[1], (inc->num_vals_per_set-1) * sizeof(double));
		/* data_set[0] Frequency in units.
		 * data_set[1] Minimum noise figure in dB.
		 * data_set[2] Source reflection coefficient to realize minimum noise figure (MA).
		 * data_set[3] Phase in degrees of the reflection coefficient (MA).
		 * data_set[4] Normalized effective noise resistance.
		 */
	}

	inc->sweep_count += 1;
	inc->data_set_count = 0;

	return SR_OK;
}

static int parse_data_line_numbers(char *line, double **vals, size_t *num_vals)
{
	char **val_strings, *val_str;
	size_t idx, mum_splits;
	int ret;

	val_strings = g_strsplit(line, " ", 0);
	*num_vals = 0;
	*vals = NULL;
	if ((mum_splits = g_strv_length(val_strings)) == 0)
		return SR_OK;

	*vals = g_malloc(sizeof(double) * mum_splits);
	if (*vals == NULL)
		return SR_ERR;

	ret = SR_OK;
	for (idx = 0 ; idx < mum_splits ; ++idx) {
		val_str = val_strings[idx];
		if (val_str[0] == '\0')
			continue;
		g_strchug(val_str);
		if ((ret = sr_atod(val_str, *vals + *num_vals)) != SR_OK) {
			sr_err("failed parsing '%s' as number", val_str);
			break;
		}
		sr_spew("parsed number %f", (*vals)[*num_vals]);
		*num_vals += 1;
	}
	g_strfreev(val_strings);

	return ret;
}

static int calc_num_ports(struct context *inc)
{
	inc->num_vals_per_set = inc->data_set_count;
	inc->num_ports = sqrti(inc->num_vals_per_set / 2);
	if ((inc->num_ports * inc->num_ports * 2 + 1) != inc->num_vals_per_set)
	{
		sr_err("num_port = %zu num_vals_per_set = %zu",
			inc->num_ports, inc->num_vals_per_set);
		return SR_ERR;
	}
	sr_spew("calculated number of ports = %zu", inc->num_ports);
	return SR_OK;
}

static int parse_data_line(struct sr_input *in, char *line)
{
	int ret;
	double *vals;
	struct context *inc = in->priv;
	size_t num_vals = 0;

	if ((ret = parse_data_line_numbers(line, &vals, &num_vals)) != SR_OK)
		return ret;

	if (!num_vals)
		return SR_OK;

	ret = SR_OK;
	if (inc->num_ports == 0 && inc->file_version == 1) {
		if (inc->data_set_count && num_vals % 2) {
			/* odd number of values -> contains a frequency ->
			   this is new data set -> now we know the number of ports*/
			ret = calc_num_ports(inc);

			if (ret == SR_OK)
				ret = send_reference_information(in);

			if (ret == SR_OK)
				ret = move_data_to_sweep(inc);
		}
		/* in case of one sweep point only we need an
		 * additional check during end() */
	}

	if (ret == SR_OK)
		ret = add_data_to_set(inc, vals, num_vals);

	g_free(vals);
	vals = NULL;

	if (inc->file_version == 1 && inc->state == PS_DATA_LINES && ret == SR_OK) {
		if (inc->sweep_count && inc->data_set_count) {
			if (inc->last_freq >= inc->data_set[0]) {
				sr_spew("start of noise data detected");
				send_sweep_information(in);
				inc->sweep_size = inc->sweep_size * inc->num_ports * inc->num_ports * 2 / 5;
				inc->state = PS_NOISE_DATA; /* start of noise data */
				inc->num_vals_per_set = 5;
			}
		}
	}

	if (ret == SR_OK && inc->num_vals_per_set) {
		if (inc->data_set_count > inc->num_vals_per_set)
			/* A new data has to start (with frequency value) on a new line
			 * but until now he had more data than expected in the last data-set
			 */
			sr_warn("more data than expected in the last data-set");
		if (inc->data_set_count >= inc->num_vals_per_set) {
			ret = move_data_to_sweep(inc);
		}
	}
	return ret;
}

static char *fwd_to(char *line, const char *word)
{
	char *ptr;
	if (g_str_has_prefix(line, word)) {
		ptr = line + strlen(word);
		g_strchug(ptr);
		return ptr;
	}
	return NULL;
}

static int parse_references(struct sr_input *in, char *line)
{
	struct context *inc = in->priv;
	char **val_strings, *val_str;
	size_t *num_refs, idx;
	int ret;

	val_strings = g_strsplit(line, " ", 0);
	num_refs = &inc->num_references_found;

	ret = SR_OK;
	for (idx = 0 ; (val_str = val_strings[idx]) &&
			*num_refs < inc->num_ports ; ++idx) {
		if (val_str[0] == '\0')
			continue;
		ret = sr_atod(val_str, inc->reference_resistances + *num_refs);
		if (ret != SR_OK) {
			g_strfreev(val_strings);
	 		return ret;
		}
		*num_refs += 1;
	}
	g_strfreev(val_strings);

	if (*num_refs == inc->num_ports) {
		inc->state = PS_KEYWORDS;
		return send_reference_information(in);
	}

	return SR_OK;}

static int parse_key_line(struct sr_input *in, char *line)
{
	struct context *inc = in->priv;
	char *ptr;
	int ret, ival;

	if ((ptr = fwd_to(line, "[NUMBER OF PORTS]"))) {
		if ((ret = sr_atoi(ptr, &ival)) != SR_OK)
			return ret;
        sr_spew("numper of ports set = %d", ival);
		inc->num_ports = ival;
		inc->num_vals_per_set = ival * ival * 2 + 1;
	}
	else if ((ptr = fwd_to(line, "[TWO-PORT ORDER]"))) {
		if (g_strstr_len(ptr, -1, "12_21"))
			inc->two_port_data_order = TP_ORDER_12_21;
		else if (g_strstr_len(ptr, -1, "21_12"))
			inc->two_port_data_order = TP_ORDER_21_12;
		else
			return SR_ERR;
	}
	else if ((ptr = fwd_to(line, "[NUMBER OF FREQUENCIES]"))) {
		/* (required) */
		if ((ret = sr_atoi(ptr, &ival)) != SR_OK)
			return ret;
		inc->sweep_points = ival;
	}
	else if ((ptr = fwd_to(line, "[NUMBER OF NOISE FREQUENCIES]"))) {
		/* (required if [Noise Data] defined) */
		if ((ret = sr_atoi(ptr, &ival)) != SR_OK)
			return ret;
		inc->sweep_points_noise = ival;
	}
	else if ((ptr = fwd_to(line, "[REFERENCE]"))) {
		if (inc->num_ports == 0)
			return SR_ERR;
		if (inc->reference_resistances)
			g_free(inc->reference_resistances);
		inc->reference_resistances = g_malloc(sizeof(double) * inc->num_ports);
		if (!inc->reference_resistances)
			return SR_ERR;
		inc->num_references_found = 0;
		inc->state = PS_REFERENCES;
		return parse_references(in, ptr);
	}
	else if ((ptr = fwd_to(line, "[MATRIX FORMAT]"))) {
		if (!inc->num_ports)
			return SR_ERR;
		if (g_strstr_len(ptr, -1, "FULL")) {
			inc->matrix_format = MF_FULL;
			sr_spew("matrix format is: FULL");
		}
		else if (g_strstr_len(ptr, -1, "LOWER")) {
			inc->matrix_format = MF_LOWER;
			sr_spew("matrix format is: LOWER");
		}
		else if (g_strstr_len(ptr, -1, "UPPER")) {
			inc->matrix_format = MF_UPPER;
			sr_spew("matrix format is: UPPER");
		}
		else
			return SR_ERR;
		inc->num_vals_per_set = (inc->matrix_format == MF_FULL) ?
			2 * inc->num_ports * inc->num_ports + 1 :             /* 2*n^2+1 */
			inc->num_ports * inc->num_ports + inc->num_ports + 1; /* n^2+n+1 */
        sr_spew("values per set is %zu", inc->num_vals_per_set);
	}
	else if ((ptr = fwd_to(line, "[MIXED-MODE ORDER]"))) {
		sr_err("Mixed mode parameters are not supported");
		return SR_ERR;
	}
	else if ((ptr = fwd_to(line, "[BEGIN INFORMATION]"))) {
		inc->state = PS_SKIP_INFO;
	}
	else if ((ptr = fwd_to(line, "[NETWORK DATA]"))) {
		if (!inc->num_ports)
			return SR_ERR;
		inc->state = PS_DATA_LINES;
	}

	return SR_OK;
}

static int process_line(struct sr_input *in, char *line)
{
	struct context *inc = in->priv;

	if (inc->state != PS_START_FILE && inc->state != PS_OPTION_LINE)
		if (line[0] == '#') /* ignoring further option lines */
			return SR_OK;

	switch(inc->state) {
	case PS_START_FILE:
		/*
		 * version 1 file has to start with the option line
		 * version 2 has to start with [version] keyword
		 */
		if (line[0] == '#') {
			inc->file_version = 1;
			inc->state = PS_DATA_LINES;
			return parse_option_line(inc, line);
		}
		else if (line[0] == '[') {
			inc->state = PS_OPTION_LINE;
			return parse_version_line(inc, line);
		}
		else
			return SR_ERR;
	case PS_OPTION_LINE:
		if (line[0] != '#')
			return SR_ERR;
		inc->state = PS_NUM_PORTS;
		return parse_option_line(inc, line);
	case PS_NUM_PORTS:
		if (line[0] != '[')
			return SR_ERR;
		inc->state = PS_KEYWORDS;
		return parse_key_line(in, line);
	case PS_KEYWORDS:
		if (line[0] == '[')
			return parse_key_line(in, line);
		else {
			inc->state = PS_DATA_LINES;
			return parse_data_line(in, line);
		}
	case PS_REFERENCES:
		return parse_references(in, line);
	case PS_SKIP_INFO:
		if (fwd_to(line, "[END INFORMATION]"))
			inc->state = PS_KEYWORDS;
		break;
	case PS_DATA_LINES:
		if (line[0] == '[' && fwd_to(line, "[NOISE DATA]")) {
			if (inc->num_ports != 2) {
				sr_err("Noise data only allowed for two port networks");
				return SR_ERR;
			}
			send_sweep_information(in);
			inc->sweep_size = inc->sweep_size * inc->num_ports * inc->num_ports * 2 / 5;
			inc->state = PS_NOISE_DATA;
			inc->num_vals_per_set = 5;
			return SR_OK;
		}
		/* fall through */
	case PS_NOISE_DATA:
		if (line[0] == '[' && fwd_to(line, "[END]")) {
			send_sweep_information(in);
			return SR_OK;
		}
		return parse_data_line(in, line);
	}

	return SR_OK;
}

static int process_buffer(struct sr_input *in, gboolean is_eof)
{
	char **lines, *line, *ptr;
	char *process_up_to;
	size_t line_idx;
	int ret;
	struct context *inc = in->priv;

	if (!inc->started) {
		std_session_send_df_header(in->sdi);
		inc->started = TRUE;
		std_session_send_df_frame_begin(in->sdi);
	}

	if (!in->buf->len)
		return SR_OK;

	g_string_ascii_up(in->buf);

	while ((ptr = strstr(in->buf->str, "\t")))
		*ptr = ' ';

	while ((ptr = strstr(in->buf->str, "\r")))
		*ptr = '\n';

	if (is_eof) {
		process_up_to = in->buf->str + in->buf->len;
	} else {
		process_up_to = g_strrstr_len(in->buf->str, in->buf->len, "\n");
		if (!process_up_to)
			return SR_OK;
		*process_up_to = '\0';
		process_up_to += 1;
	}

	ret = SR_OK;
	lines = g_strsplit(in->buf->str, "\n", 0);
	for (line_idx = 0 ; (line = lines[line_idx]); ++line_idx) {
		strip_comment(line);

		if (line[0] == '\0')
			continue;

		if ((ret = process_line(in, line)) != SR_OK)
			break;
	}
	g_strfreev(lines);

	g_string_erase(in->buf, 0, process_up_to - in->buf->str);
	if (ret != SR_OK)
		return ret;

	return ret;
}

static int receive(struct sr_input *in, GString *buf)
{
	g_string_append_len(in->buf, buf->str, buf->len);

	if (!in->sdi_ready) {
		/* sdi is ready, notify frontend. */
		in->sdi_ready = TRUE;
		return SR_OK;
	}

	return process_buffer(in, FALSE);
}

static int end(struct sr_input *in)
{
	struct context *inc = in->priv;
	int ret = SR_OK;

	if (in->sdi_ready)
		ret = process_buffer(in, TRUE);

	if (inc->file_version == 1) {
		if (inc->num_ports == 0 && inc->data_set_count) {
			ret = calc_num_ports(inc);
			if (ret == SR_OK)
				ret = send_reference_information(in);

			if (ret == SR_OK)
				ret = move_data_to_sweep(inc);
		}
	}

	if (ret == SR_OK)
	//(inc->state == PS_DATA_LINES || inc->state == PS_NOISE_DATA)) {
		ret = send_sweep_information(in);

	std_session_send_df_frame_end(in->sdi);

	if (inc->started)
		std_session_send_df_end(in->sdi);

	return ret;
}

static void cleanup(struct sr_input *in)
{
	struct context *inc = in->priv;

	g_free(inc->reference_resistances);
	inc->reference_resistances = NULL;

	g_free(inc->data_set);
	inc->data_set = NULL;

	g_free(inc->sweep_data);
	inc->sweep_data = NULL;

	g_free(inc->sweep_freq);
	inc->sweep_freq = NULL;

	g_free(in->priv);
	in->priv = NULL;
}

static int reset(struct sr_input *in)
{
	struct context *inc = in->priv;

	inc->started = FALSE;

	g_string_truncate(in->buf, 0);

	return SR_OK;
}

SR_PRIV struct sr_input_module input_touchstone = {
	.id = "snp",
	.name = "SnP",
	.desc = "Touchstone file",
	.exts = default_exts,
	.metadata = { SR_INPUT_META_FILENAME,
			SR_INPUT_META_HEADER | SR_INPUT_META_REQUIRED, 0},
	.options = NULL,
	.format_match = format_match,
	.init = init,
	.receive = receive,
	.end = end,
	.cleanup = cleanup,
	.reset = reset,
};

