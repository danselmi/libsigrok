/*
 * This file is part of the libsigrok project.
 *
 * Copyright (C) 2014 Martin Ling <martin-sigrok@earth.li>
 * Copyright (C) 2024 Octave bindings contributor
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

/*
 * Octave bindings for libsigrok.
 *
 * Adapted from the Python bindings (bindings/python/sigrok/core/classes.i).
 *
 * Key differences from Python bindings:
 *  - No NumPy: analog data returned as Octave matrix (double), logic as uint8 matrix
 *  - No pygobject: GLib::VariantBase mapped to/from Octave native types directly
 *  - Callbacks use Octave function handles (octave_value / is_function_handle)
 *  - No GIL management (Octave is single-threaded)
 *  - %octavecode replaces %pythoncode blocks
 *  - dict_to_map_* replaced by Octave struct/cell helpers
 *
 * Spike / known unknowns:
 *  - SWIG's Octave target maturity: test with your SWIG version before committing
 *  - Octave function handle callback invocation API may need adjustment
 *  - GLib event loop integration for streaming (session.run()) needs testing
 */

%module(docstring="libsigrok Octave bindings") sigrok

%{
#include "config.h"
#include <stdio.h>
#include <octave/oct.h>
#include <octave/ov-fcn-handle.h>
#include <octave/parse.h>
#include <glibmm.h>
#include "libsigrokcxx/libsigrokcxx.hpp"

/* ---------------------------------------------------------------------------
 * Helper: Octave value -> Glib::VariantBase, driven by SR config key type
 * ---------------------------------------------------------------------------*/
static Glib::VariantBase octave_to_variant_by_key(const octave_value &ov,
    const sigrok::ConfigKey *key)
{
    enum sr_datatype type = (enum sr_datatype) key->data_type()->id();

    /* We rely on Octave's own conversion methods (uint64_value, double_value,
     * etc.) which throw if the value is not convertible, rather than trying
     * to pre-check with is_*_type() methods whose names vary across Octave
     * versions. The string and cell checks use universally available methods. */
    switch (type) {
        case SR_T_UINT64:
            if (ov.isnumeric())
                return Glib::Variant<guint64>::create((guint64) ov.uint64_value());
            break;
        case SR_T_STRING:
            if (ov.is_string())
                return Glib::Variant<Glib::ustring>::create(ov.string_value());
            break;
        case SR_T_BOOL:
            if (ov.islogical() || ov.isnumeric())
                return Glib::Variant<bool>::create((bool) ov.bool_value());
            break;
        case SR_T_FLOAT:
            if (ov.isnumeric())
                return Glib::Variant<double>::create(ov.double_value());
            break;
        case SR_T_INT32:
            if (ov.isnumeric())
                return Glib::Variant<gint32>::create((gint32) ov.int_value());
            break;
        case SR_T_UINT32:
            if (ov.isnumeric())
                return Glib::Variant<guint32>::create((guint32) ov.uint_value());
            break;
        case SR_T_RATIONAL_VOLT:
            if (ov.iscell() && ov.cell_value().numel() == 2) {
                Cell c = ov.cell_value();
                guint64 num   = (guint64) c(0).uint64_value();
                guint64 denom = (guint64) c(1).uint64_value();
                return Glib::Variant< std::vector<guint64> >::create({num, denom});
            }
            break;
        case SR_T_MQ:
            if (ov.iscell() && ov.cell_value().numel() == 2) {
                Cell c = ov.cell_value();
                guint32 mq    = (guint32) c(0).uint_value();
                guint64 flags = (guint64) c(1).uint64_value();
                return Glib::Variant<std::tuple<guint32, guint64>>::create(
                    std::make_tuple(mq, flags));
            }
            break;
        default:
            break;
    }
    throw sigrok::Error(SR_ERR_ARG);
}

/* Helper: Octave value -> Glib::VariantBase, driven by Option default type */
static Glib::VariantBase octave_to_variant_by_option(const octave_value &ov,
    std::shared_ptr<sigrok::Option> option)
{
    GVariantType *type = option->default_value().get_type().gobj();

    if (g_variant_type_equal(type, G_VARIANT_TYPE_UINT64) && ov.isnumeric())
        return Glib::Variant<guint64>::create((guint64) ov.uint64_value());
    else if (g_variant_type_equal(type, G_VARIANT_TYPE_STRING) && ov.is_string())
        return Glib::Variant<Glib::ustring>::create(ov.string_value());
    else if (g_variant_type_equal(type, G_VARIANT_TYPE_BOOLEAN) && (ov.islogical() || ov.isnumeric()))
        return Glib::Variant<bool>::create((bool) ov.bool_value());
    else if (g_variant_type_equal(type, G_VARIANT_TYPE_DOUBLE) && ov.isnumeric())
        return Glib::Variant<double>::create(ov.double_value());
    else if (g_variant_type_equal(type, G_VARIANT_TYPE_INT32) && ov.isnumeric())
        return Glib::Variant<gint32>::create((gint32) ov.int_value());
    else if (g_variant_type_equal(type, G_VARIANT_TYPE_UINT32) && ov.isnumeric())
        return Glib::Variant<guint32>::create((guint32) ov.uint_value());
    else
        throw sigrok::Error(SR_ERR_ARG);
}

/* ---------------------------------------------------------------------------
 * Helper: GLib GVariant* -> Octave value (recursive, handles nested types)
 * ---------------------------------------------------------------------------
 * Maps GLib variant types to Octave types:
 *   t (uint64), u (uint32), i (int32), d (double), b (bool), s (string)
 *   (tt) rational tuple  -> 1x2 uint64 row vector
 *   (vu) MQ tuple        -> 2-element cell {uint32, uint64}
 *   at / au / ai / ad    -> row vector of appropriate type
 *   as                   -> cell array of strings
 *   a{sv}                -> struct (for samplerates dict)
 *   a(tt) / a(dd)        -> Nx2 matrix (list of ranges/rationals)
 * Any other type          -> returned as octave_value() (empty)
 * ---------------------------------------------------------------------------*/
static octave_value gvariant_to_octave(GVariant *v)
{
    if (!v)
        return octave_value();

    const GVariantType *vtype = g_variant_get_type(v);
    const gchar *type_str = g_variant_type_peek_string(vtype);

    /* ---- scalars ---- */
    if (g_variant_type_equal(vtype, G_VARIANT_TYPE_UINT64))
        return octave_uint64(g_variant_get_uint64(v));

    if (g_variant_type_equal(vtype, G_VARIANT_TYPE_UINT32))
        return octave_uint32(g_variant_get_uint32(v));

    if (g_variant_type_equal(vtype, G_VARIANT_TYPE_INT32))
        return octave_int32(g_variant_get_int32(v));

    if (g_variant_type_equal(vtype, G_VARIANT_TYPE_DOUBLE))
        return octave_value(g_variant_get_double(v));

    if (g_variant_type_equal(vtype, G_VARIANT_TYPE_BOOLEAN))
        return octave_value((bool) g_variant_get_boolean(v));

    if (g_variant_type_equal(vtype, G_VARIANT_TYPE_STRING))
        return octave_value(std::string(g_variant_get_string(v, nullptr)));

    /* ---- (tt) rational/range: two uint64 -> 1x2 uint64NDArray ---- */
    if (strcmp(type_str, "(tt)") == 0) {
        guint64 a, b;
        g_variant_get(v, "(tt)", &a, &b);
        uint64NDArray arr(dim_vector(1, 2));
        arr(0) = a;
        arr(1) = b;
        return octave_value(arr);
    }

    /* ---- (vu) or (ut) MQ tuple: uint32 + uint64 -> 1x2 cell ---- */
    if (strcmp(type_str, "(vu)") == 0 || strcmp(type_str, "(ut)") == 0) {
        guint32 mq; guint64 flags;
        if (strcmp(type_str, "(vu)") == 0)
            g_variant_get(v, "(vu)", &mq, &flags);
        else
            g_variant_get(v, "(ut)", &mq, &flags);
        Cell c(1, 2);
        c(0) = octave_uint32(mq);
        c(1) = octave_uint64(flags);
        return octave_value(c);
    }

    /* ---- (dd) double range -> 1x2 double vector ---- */
    if (strcmp(type_str, "(dd)") == 0) {
        gdouble a, b;
        g_variant_get(v, "(dd)", &a, &b);
        Matrix m(1, 2);
        m(0) = a;
        m(1) = b;
        return octave_value(m);
    }

    /* ---- at: fixed array of uint64 -> uint64NDArray row vector ---- */
    if (strcmp(type_str, "at") == 0) {
        gsize n;
        const guint64 *data = (const guint64 *) g_variant_get_fixed_array(v, &n, sizeof(guint64));
        uint64NDArray arr(dim_vector(1, (octave_idx_type) n));
        for (gsize i = 0; i < n; i++)
            arr(i) = data[i];
        return octave_value(arr);
    }

    /* ---- au: fixed array of uint32 -> uint32NDArray row vector ---- */
    if (strcmp(type_str, "au") == 0) {
        gsize n;
        const guint32 *data = (const guint32 *) g_variant_get_fixed_array(v, &n, sizeof(guint32));
        uint32NDArray arr(dim_vector(1, (octave_idx_type) n));
        for (gsize i = 0; i < n; i++)
            arr(i) = data[i];
        return octave_value(arr);
    }

    /* ---- ai: fixed array of int32 -> int32NDArray row vector ---- */
    if (strcmp(type_str, "ai") == 0) {
        gsize n;
        const gint32 *data = (const gint32 *) g_variant_get_fixed_array(v, &n, sizeof(gint32));
        int32NDArray arr(dim_vector(1, (octave_idx_type) n));
        for (gsize i = 0; i < n; i++)
            arr(i) = data[i];
        return octave_value(arr);
    }

    /* ---- ad: array of doubles -> row vector ---- */
    if (strcmp(type_str, "ad") == 0) {
        gsize n = g_variant_n_children(v);
        Matrix m(1, (octave_idx_type) n);
        for (gsize i = 0; i < n; i++)
            m(i) = g_variant_get_double(g_variant_get_child_value(v, i));
        return octave_value(m);
    }

    /* ---- as: array of strings -> cell array of strings ---- */
    if (strcmp(type_str, "as") == 0) {
        gsize n = g_variant_n_children(v);
        Cell c((octave_idx_type) n, 1);
        for (gsize i = 0; i < n; i++) {
            GVariant *child = g_variant_get_child_value(v, i);
            c(i) = std::string(g_variant_get_string(child, nullptr));
            g_variant_unref(child);
        }
        return octave_value(c);
    }

    /* ---- a(tt): array of (uint64,uint64) tuples -> Nx2 uint64 matrix ---- */
    if (strcmp(type_str, "a(tt)") == 0) {
        gsize n = g_variant_n_children(v);
        uint64NDArray arr(dim_vector((octave_idx_type) n, 2));
        for (gsize i = 0; i < n; i++) {
            GVariant *row = g_variant_get_child_value(v, i);
            guint64 a, b;
            g_variant_get(row, "(tt)", &a, &b);
            arr(i, 0) = a;
            arr(i, 1) = b;
            g_variant_unref(row);
        }
        return octave_value(arr);
    }

    /* ---- a(dd): array of (double,double) tuples -> Nx2 double matrix ---- */
    if (strcmp(type_str, "a(dd)") == 0) {
        gsize n = g_variant_n_children(v);
        Matrix m((octave_idx_type) n, 2);
        for (gsize i = 0; i < n; i++) {
            GVariant *row = g_variant_get_child_value(v, i);
            gdouble a, b;
            g_variant_get(row, "(dd)", &a, &b);
            m(i, 0) = a;
            m(i, 1) = b;
            g_variant_unref(row);
        }
        return octave_value(m);
    }

    /* ---- a{sv}: dict (e.g. samplerates dict) -> Octave struct ---- */
    if (strcmp(type_str, "a{sv}") == 0) {
        gsize n = g_variant_n_children(v);
        octave_scalar_map s;
        for (gsize i = 0; i < n; i++) {
            GVariant *entry = g_variant_get_child_value(v, i);
            const gchar *key = g_variant_get_string(g_variant_get_child_value(entry, 0), nullptr);
            GVariant *val    = g_variant_get_variant(g_variant_get_child_value(entry, 1));
            /* Replace hyphens with underscores so it's a valid Octave field name */
            std::string field(key);
            for (char &c : field)
                if (c == '-') c = '_';
            s.assign(field, gvariant_to_octave(val));
            g_variant_unref(val);
            g_variant_unref(entry);
        }
        return octave_value(s);
    }

    /* ---- generic container: recurse into children -> cell array ---- */
    if (g_variant_is_container(v)) {
        gsize n = g_variant_n_children(v);
        Cell c((octave_idx_type) n, 1);
        for (gsize i = 0; i < n; i++) {
            GVariant *child = g_variant_get_child_value(v, i);
            c(i) = gvariant_to_octave(child);
            g_variant_unref(child);
        }
        return octave_value(c);
    }

    return octave_value();  /* unknown type — return empty */
}

/* Helper: Octave struct -> std::map<std::string, Glib::VariantBase> for options */
static std::map<std::string, Glib::VariantBase> struct_to_map_options(
    const octave_value &ov,
    std::map<std::string, std::shared_ptr<sigrok::Option>> options)
{
    std::map<std::string, Glib::VariantBase> output;
    if (!ov.isstruct())
        throw sigrok::Error(SR_ERR_ARG);
    octave_scalar_map s = ov.scalar_map_value();
    string_vector fields = s.fieldnames();
    for (octave_idx_type i = 0; i < fields.numel(); i++) {
        std::string key = fields(i);
        octave_value val = s.getfield(key);
        output[key] = octave_to_variant_by_option(val, options.at(key));
    }
    return output;
}

/* Helper: Octave struct -> std::map<const ConfigKey*, VariantBase> for scan */
static std::map<const sigrok::ConfigKey *, Glib::VariantBase>
struct_to_map_config(const octave_value &ov)
{
    std::map<const sigrok::ConfigKey *, Glib::VariantBase> output;
    if (!ov.isstruct())
        throw sigrok::Error(SR_ERR_ARG);
    /* octave_scalar_map iterators yield (string, octave_idx_type) index pairs.
     * Use fieldnames() + getfield() to get actual octave_value values. */
    octave_scalar_map s = ov.scalar_map_value();
    string_vector fields = s.fieldnames();
    for (octave_idx_type i = 0; i < fields.numel(); i++) {
        std::string fname = fields(i);
        octave_value val = s.getfield(fname);
        auto key = sigrok::ConfigKey::get_by_identifier(fname);
        output[key] = octave_to_variant_by_key(val, key);
    }
    return output;
}

%}

/*
 * SWIG does not understand GLib's compiler-attribute macros.
 * Define them away so SWIG can parse libsigrokcxx.hpp cleanly.
 * These are only seen by SWIG's parser, not by the C++ compiler
 * (the %{ ... %} block is passed straight through to the compiler).
 */
#define G_GNUC_BEGIN_IGNORE_DEPRECATIONS
#define G_GNUC_END_IGNORE_DEPRECATIONS
#define G_GNUC_DEPRECATED
#define G_GNUC_DEPRECATED_FOR(x)
#define G_GNUC_PRINTF(a, b)
#define G_GNUC_NULL_TERMINATED
#define G_GNUC_WARN_UNUSED_RESULT
#define G_GNUC_PURE
#define G_GNUC_CONST
#define G_GNUC_NORETURN
#define G_GNUC_UNUSED
#define SR_API
#define SR_PRIV

/* Pull in shared templates and class declarations */
%include "../../../swig/templates.i"

/* -------------------------------------------------------------------------
 * Global exception handler: convert sigrok::Error into an Octave error.
 *
 * Without this, any C++ exception that escapes a SWIG wrapper kills Octave
 * (SIGABRT).  With %exception, SWIG wraps every generated function body in
 * try/catch and calls error() — which raises an Octave-level exception that
 * can be caught with try/catch in .m scripts.
 * -------------------------------------------------------------------------*/
%exception {
    try {
        $action
    } catch (const sigrok::Error &e) {
        error("sigrok: %s", e.what());
        SWIG_fail;
    } catch (const std::exception &e) {
        error("sigrok: std::exception: %s", e.what());
        SWIG_fail;
    } catch (...) {
        error("sigrok: unknown C++ exception");
        SWIG_fail;
    }
}

/* -------------------------------------------------------------------------
 * Typemaps: Matrix and uint8NDArray -> native Octave values
 *
 * Without these, SWIG wraps Matrix as _p_Matrix (an opaque pointer object).
 * These typemaps make %extend methods returning Matrix or uint8NDArray hand
 * back a native Octave matrix directly.
 * -------------------------------------------------------------------------*/
%typemap(out) Matrix {
    $result = octave_value($1);
}
%typemap(out) uint8NDArray {
    $result = octave_value($1);
}

/* -------------------------------------------------------------------------
 * Identity typemap for octave_value parameters in %extend methods.
 *
 * SWIG's Octave target does not automatically handle raw octave_value
 * parameters — without a typemap it silently skips generating the wrapper.
 * This identity typemap tells SWIG to accept any Octave value and pass it
 * straight through. The %typecheck is required so overload resolution works.
 * -------------------------------------------------------------------------*/
%typemap(in) octave_value {
    $1 = $input;
}
%typemap(typecheck, precedence=SWIG_TYPECHECK_POINTER) octave_value {
    $1 = 1; /* accept any Octave value */
}

/*
 * %attributevector and %attributemap are macros that swig/classes.i expects
 * to be defined by the language-specific binding. The Python binding defines
 * them using %pythoncode; we define plain C++ property accessors instead,
 * which is sufficient for the Octave target.
 *
 * %attributevector(Class, Type, Name, Get)
 *   — renames Get to _Get so the shared .i doesn't conflict, and keeps the
 *     underlying method accessible as obj._Get() from Octave.
 *
 * %attributemap(Class, Type, Name, Get)
 *   — same, but the map types (DriverMap etc.) already have SWIG wrappers
 *     from templates.i; Octave users call obj._Get() directly.
 *
 * %enumextras(Class)
 *   — adds __hash__, __str__, __repr__ equivalents; for Octave we just
 *     expose the name() method which is already on the C++ class.
 */
%define %attributevector(Class, Type, Name, Get)
%ignore sigrok::Class::Get;
%enddef

%define %attributemap(Class, Type, Name, Get)
%ignore sigrok::Class::Get;
%enddef

%define %enumextras(Class)
%extend sigrok::Class {
    long __hash__()  { return (long) $self; }
    std::string __str__()  { return $self->name(); }
    std::string __repr__() { return std::string(#Class) + "." + $self->name(); }
}
%enddef

/* -------------------------------------------------------------------------
 * Typemap: Glib::VariantBase -> Octave native value (out)
 *
 * Maps the most common GLib variant types to Octave scalars/strings.
 * Unmapped types fall back to an empty octave_value (prints as [](0x0)).
 * -------------------------------------------------------------------------*/
%typemap(out) Glib::VariantBase {
    Glib::VariantBase v = $1;
    if (!v.gobj()) {
        $result = octave_value();
    } else {
        const GVariantType *t = g_variant_get_type(v.gobj());
        if (g_variant_type_equal(t, G_VARIANT_TYPE_UINT64))
            $result = octave_value((uint64_t) Glib::VariantBase::cast_dynamic<Glib::Variant<guint64>>(v).get());
        else if (g_variant_type_equal(t, G_VARIANT_TYPE_INT32))
            $result = octave_value((int32_t)  Glib::VariantBase::cast_dynamic<Glib::Variant<gint32>>(v).get());
        else if (g_variant_type_equal(t, G_VARIANT_TYPE_UINT32))
            $result = octave_value((uint32_t) Glib::VariantBase::cast_dynamic<Glib::Variant<guint32>>(v).get());
        else if (g_variant_type_equal(t, G_VARIANT_TYPE_DOUBLE))
            $result = octave_value(           Glib::VariantBase::cast_dynamic<Glib::Variant<double>>(v).get());
        else if (g_variant_type_equal(t, G_VARIANT_TYPE_BOOLEAN))
            $result = octave_value(           Glib::VariantBase::cast_dynamic<Glib::Variant<bool>>(v).get());
        else if (g_variant_type_equal(t, G_VARIANT_TYPE_STRING))
            $result = octave_value(std::string(Glib::VariantBase::cast_dynamic<Glib::Variant<Glib::ustring>>(v).get()));
        else
            $result = octave_value(); /* unhandled variant type */
    }
}

%apply Glib::VariantBase { Glib::VariantContainerBase }

/* -------------------------------------------------------------------------
 * Typemap: LogCallbackFunction <- Octave function handle
 * -------------------------------------------------------------------------*/
%typecheck(SWIG_TYPECHECK_POINTER) sigrok::LogCallbackFunction {
    $1 = $input.is_function_handle() ? 1 : 0;
}

%typemap(in) sigrok::LogCallbackFunction {
    if (!$input.is_function_handle())
        SWIG_exception(SWIG_TypeError, "Expected an Octave function handle (@fn)");

    octave_value cb = $input;
    $1 = [cb] (const sigrok::LogLevel *loglevel, std::string message) {
        octave_value_list args;
        /* Pass loglevel as integer id and message as string */
        args(0) = octave_value((int) loglevel->id());
        args(1) = octave_value(message);
        octave::feval(cb.function_value(), args, 0);
    };
}

/* -------------------------------------------------------------------------
 * Typemap: SessionStoppedCallback <- Octave function handle
 * -------------------------------------------------------------------------*/
%typecheck(SWIG_TYPECHECK_POINTER) sigrok::SessionStoppedCallback {
    $1 = $input.is_function_handle() ? 1 : 0;
}

%typemap(in) sigrok::SessionStoppedCallback {
    if (!$input.is_function_handle())
        SWIG_exception(SWIG_TypeError, "Expected an Octave function handle (@fn)");

    octave_value cb = $input;
    $1 = [cb] () {
        octave::feval(cb.function_value(), octave_value_list(), 0);
    };
}

/* -------------------------------------------------------------------------
 * Typemap: DatafeedCallbackFunction <- Octave function handle
 *
 * The callback receives two SWIG-wrapped objects: Device and Packet.
 * The Octave side callback signature: @(device, packet) ...
 * -------------------------------------------------------------------------*/
%typecheck(SWIG_TYPECHECK_POINTER) sigrok::DatafeedCallbackFunction {
    $1 = $input.is_function_handle() ? 1 : 0;
}

%typemap(in) sigrok::DatafeedCallbackFunction {
    if (!$input.is_function_handle())
        SWIG_exception(SWIG_TypeError, "Expected an Octave function handle (@fn)");

    octave_value cb = $input;
    $1 = [cb] (std::shared_ptr<sigrok::Device> device,
               std::shared_ptr<sigrok::Packet> packet) {

        /*
         * Wrap the C++ shared_ptrs as SWIG octave objects.
         * SWIG's Octave target exposes SWIG_NewPointerObj for this purpose.
         * If SWIG_NewPointerObj is not available in the Octave SWIG runtime,
         * use a thin helper that boxes the pointer into an octave_value — this
         * is the main area to validate during the spike.
         */
        auto *dev_ptr = new std::shared_ptr<sigrok::Device>(device);
        auto *pkt_ptr = new std::shared_ptr<sigrok::Packet>(packet);

        octave_value dev_ov = SWIG_NewPointerObj(
            dev_ptr, SWIGTYPE_p_std__shared_ptrT_sigrok__Device_t, SWIG_POINTER_OWN);
        octave_value pkt_ov = SWIG_NewPointerObj(
            pkt_ptr, SWIGTYPE_p_std__shared_ptrT_sigrok__Packet_t, SWIG_POINTER_OWN);

        octave_value_list args;
        args(0) = dev_ov;
        args(1) = pkt_ov;
        octave::feval(cb.function_value(), args, 0);
    };
}

/* -------------------------------------------------------------------------
 * Packet payload dispatch — same pattern as Python but using octave_value
 * -------------------------------------------------------------------------*/
%ignore sigrok::Packet::payload;

%extend sigrok::Packet
{
    std::shared_ptr<sigrok::Header> payload_header()
    {
        return std::dynamic_pointer_cast<sigrok::Header>($self->payload());
    }
    std::shared_ptr<sigrok::Meta> payload_meta()
    {
        return std::dynamic_pointer_cast<sigrok::Meta>($self->payload());
    }
    std::shared_ptr<sigrok::Analog> payload_analog()
    {
        return std::dynamic_pointer_cast<sigrok::Analog>($self->payload());
    }
    std::shared_ptr<sigrok::Logic> payload_logic()
    {
        return std::dynamic_pointer_cast<sigrok::Logic>($self->payload());
    }
}

/* -------------------------------------------------------------------------
 * Driver.scan(struct) — accepts an Octave struct of config key/value pairs
 *
 * %extend is declared first (before %rename) so the rename directive only
 * applies to the original C++ method from libsigrokcxx.hpp, not to our
 * added methods. The original scan(std::map<...>) is renamed to _scan_map
 * to avoid W302 conflict with our scan(octave_value) extension.
 * Inside the extend body we call the C++ method by its original name since
 * $self is a real C++ pointer — the rename only affects SWIG's name table.
 * -------------------------------------------------------------------------*/
%extend sigrok::Driver
{
    std::vector<std::shared_ptr<sigrok::HardwareDevice> > scan(octave_value opts)
    {
        if (opts.isstruct())
            return $self->scan(struct_to_map_config(opts));
        else if (opts.isempty())
            return $self->scan({});
        throw sigrok::Error(SR_ERR_ARG);
    }

    /* Zero-argument convenience */
    std::vector<std::shared_ptr<sigrok::HardwareDevice> > scan()
    {
        return $self->scan({});
    }
}
%rename(_scan_map) sigrok::Driver::scan;

/* -------------------------------------------------------------------------
 * InputFormat.create_input(struct) / OutputFormat.create_output(dev, struct)
 * -------------------------------------------------------------------------*/
%extend sigrok::InputFormat
{
    std::shared_ptr<sigrok::Input> create_input(octave_value opts)
    {
        if (opts.isstruct())
            return $self->create_input(struct_to_map_options(opts, $self->options()));
        else if (opts.isempty())
            return $self->create_input({});
        throw sigrok::Error(SR_ERR_ARG);
    }

    std::shared_ptr<sigrok::Input> create_input()
    {
        return $self->create_input({});
    }
}
%rename(_create_input_map) sigrok::InputFormat::create_input;

/* -------------------------------------------------------------------------
 * Input.send_data(data) / Input.input_end() / Input.get_device()
 *
 * send() takes void* / size_t which SWIG cannot call from Octave directly.
 * We provide send_data() which accepts a uint8 vector.  We use a distinct
 * name to avoid SWIG rename/ignore conflicts with the native send().
 *
 * end() can conflict with SWIG internals as a keyword; we expose it as
 * input_end() for the same reason.
 *
 * Input::device() is renamed to _device by %attributestring in swig/classes.i.
 * We expose it as get_device() which returns the InputDevice pointer.
 *
 * InputDevice inherits from Device — add get_channels() so the caller can
 * inspect what channels the input file declares.
 * -------------------------------------------------------------------------*/
%ignore sigrok::Input::send;
%ignore sigrok::Input::end;
%extend sigrok::Input
{
    void send_data(octave_value data)
    {
        if (!data.is_uint8_type())
            throw sigrok::Error(SR_ERR_ARG);
        const uint8NDArray arr = data.uint8_array_value();
        const uint8_t *ptr = reinterpret_cast<const uint8_t *>(arr.data());
        $self->send((void *) ptr, (size_t) arr.numel());
    }

    void input_end()
    {
        $self->end();
    }

    std::shared_ptr<sigrok::InputDevice> get_device()
    {
        return $self->device();
    }
}

%extend sigrok::InputDevice
{
    Cell get_channels()
    {
        auto chans = $self->channels();
        Cell c((octave_idx_type) chans.size(), 1);
        octave_idx_type i = 0;
        for (auto &ch : chans) {
            c(i++) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::Channel>(ch),
                SWIGTYPE_p_std__shared_ptrT_sigrok__Channel_t,
                SWIG_POINTER_OWN);
        }
        return c;
    }
}

%extend sigrok::OutputFormat
{
    std::shared_ptr<sigrok::Output> create_output(
        std::shared_ptr<sigrok::Device> device, octave_value opts)
    {
        if (opts.isstruct())
            return $self->create_output(device,
                struct_to_map_options(opts, $self->options()));
        else if (opts.isempty())
            return $self->create_output(device, {});
        throw sigrok::Error(SR_ERR_ARG);
    }

    std::shared_ptr<sigrok::Output> create_output(
        std::shared_ptr<sigrok::Device> device)
    {
        return $self->create_output(device, {});
    }

    /* Overloads for UserDevice — SWIG Octave does not automatically upcast
     * shared_ptr<UserDevice> to shared_ptr<Device>. */
    std::shared_ptr<sigrok::Output> create_output(
        std::shared_ptr<sigrok::UserDevice> device, octave_value opts)
    {
        std::shared_ptr<sigrok::Device> dev =
            std::static_pointer_cast<sigrok::Device>(device);
        if (opts.isstruct())
            return $self->create_output(dev,
                struct_to_map_options(opts, $self->options()));
        else if (opts.isempty())
            return $self->create_output(dev, {});
        throw sigrok::Error(SR_ERR_ARG);
    }

    std::shared_ptr<sigrok::Output> create_output(
        std::shared_ptr<sigrok::UserDevice> device)
    {
        std::shared_ptr<sigrok::Device> dev =
            std::static_pointer_cast<sigrok::Device>(device);
        return $self->create_output(dev, {});
    }
}
%rename(_create_output_map) sigrok::OutputFormat::create_output;

/* -------------------------------------------------------------------------
 * Configurable.config_set(key, value) — value is an Octave native type
 * -------------------------------------------------------------------------*/
%extend sigrok::Configurable
{
    void config_set(const sigrok::ConfigKey *key, octave_value input)
    {
        $self->config_set(key, octave_to_variant_by_key(input, key));
    }
}

/* -------------------------------------------------------------------------
 * Context.set_log_level(level)
 *
 * The shared classes.i uses %attribute to turn set_log_level into a
 * read/write property.  In SWIG's Octave target that doesn't produce a
 * usable setter, so we expose set_log_level as an explicit method too.
 * Usage:
 *   ctx.set_log_level(LogLevel.SPEW)   % maximum verbosity (id=5)
 *   ctx.set_log_level(LogLevel.WARN)   % default
 *   ctx.set_log_level(LogLevel.NONE)   % silent
 * -------------------------------------------------------------------------*/
%extend sigrok::Context
{
    void set_log_level(const sigrok::LogLevel *level)
    {
        $self->set_log_level(level);
    }
}

/* -------------------------------------------------------------------------
 * Context.create_logic_packet(data, unit_size)
 * data: uint8 row vector or matrix
 * -------------------------------------------------------------------------*/
%extend sigrok::Context
{
    std::shared_ptr<sigrok::Packet> create_logic_packet(
        octave_value data, unsigned int unit_size)
    {
        if (!data.is_uint8_type())
            throw sigrok::Error(SR_ERR_ARG);
        uint8NDArray arr = data.uint8_array_value();
        size_t len = arr.numel() * sizeof(uint8_t);
        return $self->create_logic_packet((void *) arr.data(), len, unit_size);
    }
}

/* -------------------------------------------------------------------------
 * Session.run_in_background() / wait() / stop_and_wait()
 *
 * sess.run() blocks the GLib main loop and swallows Ctrl-C.
 * These helpers run the session on a std::thread so Octave stays live.
 *
 * Usage:
 *   sess.start();
 *   sess.run_background();
 *   while sess.is_running(); pause(0.1); end   % Ctrl-C works here
 *   % or: sess.stop_and_wait();
 * -------------------------------------------------------------------------*/
%{
#include <thread>
#include <mutex>

struct OctaveSessionRunner {
    std::thread thr;
};
static std::map<sigrok::Session*, OctaveSessionRunner*> _session_runners;
static std::mutex _session_runners_mutex;
%}

%extend sigrok::Session
{
    /* Start the GLib event loop on a background thread.
     * Call sess.start() first to arm the session. */
    void run_background()
    {
        std::lock_guard<std::mutex> lk(_session_runners_mutex);
        if (_session_runners.count($self))
            return; /* already running */
        auto *runner = new OctaveSessionRunner();
        sigrok::Session *sess = $self;
        runner->thr = std::thread([sess]() { sess->run(); });
        _session_runners[$self] = runner;
    }

    /* Block (in a yield-friendly way) until the session stops.
     * Call after run_background(). Returns immediately if not running. */
    void wait_done()
    {
        std::lock_guard<std::mutex> lk(_session_runners_mutex);
        auto it = _session_runners.find($self);
        if (it == _session_runners.end())
            return;
        if (it->second->thr.joinable())
            it->second->thr.join();
        delete it->second;
        _session_runners.erase(it);
    }

    /* Convenience: stop the session and join the background thread. */
    void stop_and_wait()
    {
        $self->stop();
        {
            std::lock_guard<std::mutex> lk(_session_runners_mutex);
            auto it = _session_runners.find($self);
            if (it != _session_runners.end()) {
                if (it->second->thr.joinable())
                    it->second->thr.join();
                delete it->second;
                _session_runners.erase(it);
            }
        }
    }

    /* Trigger attach/detach — placed here (before %include) so SWIG registers
     * them before it processes %attributestring(Session,...,set_trigger) which
     * would otherwise shadow our version.  The native set_trigger is renamed to
     * _set_trigger_native by the %rename below. */
    std::shared_ptr<sigrok::Trigger> get_trigger()
    {
        return $self->trigger();
    }

    void set_trigger(octave_value trig_ov)
    {
        std::shared_ptr<sigrok::Trigger> *ptr = nullptr;
        if (SWIG_ConvertPtr(trig_ov, (void **) &ptr,
                SWIGTYPE_p_std__shared_ptrT_sigrok__Trigger_t, 0) != SWIG_OK || !ptr)
            throw sigrok::Error(SR_ERR_ARG);
        $self->set_trigger(*ptr);
    }
}

/* Rename Session::set_trigger before the include so %attributestring in
 * swig/classes.i doesn't add a second set_trigger to the dispatch table. */
%rename(_set_trigger_native) sigrok::Session::set_trigger;

/* Pull in the shared class definitions */
%include "../../../swig/classes.i"


/* -------------------------------------------------------------------------
 * Configurable::config_list() — returns a Glib::VariantContainerBase which
 * we convert to a native Octave value.  The variant type depends on the key:
 *   SR_CONF_SAMPLERATE -> a{sv} with key "samplerates" or "samplerate-steps"
 *   SR_CONF_DEVICE_OPTIONS -> au (array of uint32 capability flags)
 *   SR_CONF_PATTERN_MODE -> as (array of strings)
 *   SR_CONF_TRIGGER_MATCH -> ai (array of int32 enum values)
 *   etc.
 *
 * Returns an Octave value of the appropriate type (see gvariant_to_octave).
 * Placed after %include so Configurable is fully defined.
 * -------------------------------------------------------------------------*/
%extend sigrok::Configurable
{
    octave_value config_list(const sigrok::ConfigKey *key)
    {
        Glib::VariantContainerBase vcb = $self->config_list(key);
        GVariant *gv = vcb.gobj();
        return gvariant_to_octave(gv);
    }
}

/* -------------------------------------------------------------------------
 * Device::channels() — the %attributevector macro above ignores the native
 * C++ channels() (which returns std::vector).  We provide a clean channels()
 * via %extend that returns a native Octave cell array of Channel objects.
 * $self->channels() calls the C++ method directly (the %ignore only affects
 * SWIG's name table, not the underlying C++).
 * -------------------------------------------------------------------------*/
%extend sigrok::Device
{
    Cell get_channels()
    {
        auto chans = $self->channels();
        Cell c((octave_idx_type) chans.size(), 1);
        octave_idx_type i = 0;
        for (auto &ch : chans) {
            c(i++) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::Channel>(ch),
                SWIGTYPE_p_std__shared_ptrT_sigrok__Channel_t,
                SWIG_POINTER_OWN);
        }
        return c;
    }
}

/* HardwareDevice inherits Device::channels() but SWIG's Octave target does
 * not propagate %extend methods to derived classes — repeat the extension
 * explicitly on HardwareDevice so dev.get_channels() works on scan() results. */
%extend sigrok::HardwareDevice
{
    Cell get_channels()
    {
        auto chans = $self->channels();
        Cell c((octave_idx_type) chans.size(), 1);
        octave_idx_type i = 0;
        for (auto &ch : chans) {
            c(i++) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::Channel>(ch),
                SWIGTYPE_p_std__shared_ptrT_sigrok__Channel_t,
                SWIG_POINTER_OWN);
        }
        return c;
    }

    Cell channel_groups_list()
    {
        auto m = $self->channel_groups();
        octave_idx_type n = (octave_idx_type) m.size();
        Cell c(n, 2);
        octave_idx_type i = 0;
        for (auto &kv : m) {
            c(i, 0) = octave_value(kv.first);
            c(i, 1) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::ChannelGroup>(kv.second),
                SWIGTYPE_p_std__shared_ptrT_sigrok__ChannelGroup_t,
                SWIG_POINTER_OWN);
            i++;
        }
        return c;
    }
}

/* -------------------------------------------------------------------------
 * Device::channel_groups_list() — returns Nx2 cell array {name, ChanGrpObj}
 *
 * Device::channel_groups() returns std::map<string, shared_ptr<ChannelGroup>>
 * which the Octave SWIG target cannot iterate.  This helper converts it to
 * a native Nx2 cell array, mirroring driver_list() / input_format_list().
 *
 * Usage:
 *   cg = dev.channel_groups_list();   % Nx2 cell
 *   cg{1,1}                           % name string
 *   cg{1,2}                           % ChannelGroup object
 * -------------------------------------------------------------------------*/
%extend sigrok::Device
{
    Cell channel_groups_list()
    {
        auto m = $self->channel_groups();
        octave_idx_type n = (octave_idx_type) m.size();
        Cell c(n, 2);
        octave_idx_type i = 0;
        for (auto &kv : m) {
            c(i, 0) = octave_value(kv.first);
            c(i, 1) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::ChannelGroup>(kv.second),
                SWIGTYPE_p_std__shared_ptrT_sigrok__ChannelGroup_t,
                SWIG_POINTER_OWN);
            i++;
        }
        return c;
    }
}

/* UserDevice also needs channel_groups_list() since it inherits from Device
 * but SWIG's Octave target doesn't propagate %extend to derived classes. */
%extend sigrok::UserDevice
{
    Cell channel_groups_list()
    {
        auto m = $self->channel_groups();
        octave_idx_type n = (octave_idx_type) m.size();
        Cell c(n, 2);
        octave_idx_type i = 0;
        for (auto &kv : m) {
            c(i, 0) = octave_value(kv.first);
            c(i, 1) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::ChannelGroup>(kv.second),
                SWIGTYPE_p_std__shared_ptrT_sigrok__ChannelGroup_t,
                SWIG_POINTER_OWN);
            i++;
        }
        return c;
    }

    Cell get_channels()
    {
        auto chans = $self->channels();
        Cell c((octave_idx_type) chans.size(), 1);
        octave_idx_type i = 0;
        for (auto &ch : chans) {
            c(i++) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::Channel>(ch),
                SWIGTYPE_p_std__shared_ptrT_sigrok__Channel_t,
                SWIG_POINTER_OWN);
        }
        return c;
    }
}

/* -------------------------------------------------------------------------
 * ChannelGroup::get_channels() — returns cell array of Channel objects
 *
 * ChannelGroup::channels() returns std::vector<shared_ptr<Channel>> which
 * is ignored by %attributevector (our macro uses %ignore).  We expose it
 * as get_channels() mirroring the same method on Device subclasses.
 * -------------------------------------------------------------------------*/
%extend sigrok::ChannelGroup
{
    Cell get_channels()
    {
        auto chans = $self->channels();
        Cell c((octave_idx_type) chans.size(), 1);
        octave_idx_type i = 0;
        for (auto &ch : chans) {
            c(i++) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::Channel>(ch),
                SWIGTYPE_p_std__shared_ptrT_sigrok__Channel_t,
                SWIG_POINTER_OWN);
        }
        return c;
    }
}

/* -------------------------------------------------------------------------
 * Analog::data() -> Octave matrix (double, channels x samples)
 *
 * Equivalent to the NumPy array returned by the Python bindings.
 * libsigrok stores samples as float, interleaved per channel.
 * We return a double matrix: rows = channels, cols = samples.
 *
 * Placed after %include so the class is fully defined before we extend it.
 * sigrok::Analog has no C++ member called "data" (only data_pointer()), so
 * no %ignore or %rename is needed — the %extend creates a new method.
 * -------------------------------------------------------------------------*/
%extend sigrok::Analog
{
    Matrix data()
    {
        int num_ch      = (int) $self->channels().size();
        int num_samples = $self->num_samples();
        const float *src = (const float *) $self->data_pointer();

        Matrix m(num_ch, num_samples);
        for (int ch = 0; ch < num_ch; ch++)
            for (int s = 0; s < num_samples; s++)
                m(ch, s) = (double) src[ch * num_samples + s];
        return m;
    }
}

/* -------------------------------------------------------------------------
 * Logic::data() -> Octave uint8 matrix (samples x unit_size)
 *
 * Each row is one sample; columns are the raw bytes of the logic word.
 *
 * Placed after %include so the class is fully defined before we extend it.
 * sigrok::Logic has no C++ member called "data" (only data_pointer()), so
 * no %ignore or %rename is needed.
 * -------------------------------------------------------------------------*/
%extend sigrok::Logic
{
    uint8NDArray data()
    {
        size_t unit_size   = $self->unit_size();
        size_t num_samples = $self->data_length() / unit_size;
        const uint8_t *src = (const uint8_t *) $self->data_pointer();

        dim_vector dv(2, 1);
        dv(0) = (octave_idx_type) num_samples;
        dv(1) = (octave_idx_type) unit_size;
        uint8NDArray arr(dv);
        for (size_t s = 0; s < num_samples; s++)
            for (size_t b = 0; b < unit_size; b++)
                arr(s, b) = src[s * unit_size + b];
        return arr;
    }
}

/* -------------------------------------------------------------------------
 * Trigger / TriggerStage / TriggerMatch
 *
 * The %attributevector macro above uses %ignore on the native stages() and
 * matches() accessors.  We expose them as get_stages() / get_matches() and
 * provide a get_trigger() / set_trigger() pair on Session.
 *
 * Trigger.get_stages()     — Cell of TriggerStage objects
 * TriggerStage.get_matches() — Cell of TriggerMatch objects
 * TriggerStage.add_match(channel, type)           — logic trigger
 * TriggerStage.add_match_value(channel, type, v)  — analog trigger
 * TriggerMatch.get_channel() — the Channel this match is on
 * Session.get_trigger() / Session.set_trigger(t)  — attach/detach trigger
 * -------------------------------------------------------------------------*/
%extend sigrok::Trigger
{
    Cell get_stages()
    {
        auto vec = $self->stages();
        Cell c((octave_idx_type) vec.size(), 1);
        octave_idx_type i = 0;
        for (auto &s : vec) {
            c(i++) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::TriggerStage>(s),
                SWIGTYPE_p_std__shared_ptrT_sigrok__TriggerStage_t,
                SWIG_POINTER_OWN);
        }
        return c;
    }
}

%extend sigrok::TriggerStage
{
    Cell get_matches()
    {
        auto vec = $self->matches();
        Cell c((octave_idx_type) vec.size(), 1);
        octave_idx_type i = 0;
        for (auto &m : vec) {
            c(i++) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::TriggerMatch>(m),
                SWIGTYPE_p_std__shared_ptrT_sigrok__TriggerMatch_t,
                SWIG_POINTER_OWN);
        }
        return c;
    }

    /* Logic trigger: channel + match type (RISING, FALLING, EDGE, ZERO, ONE) */
    void add_match(std::shared_ptr<sigrok::Channel> channel,
                   const sigrok::TriggerMatchType *type)
    {
        $self->add_match(channel, type);
    }

    /* Analog trigger: channel + match type (OVER, UNDER) + threshold value */
    void add_match_value(std::shared_ptr<sigrok::Channel> channel,
                         const sigrok::TriggerMatchType *type,
                         float value)
    {
        $self->add_match(channel, type, value);
    }
}

%extend sigrok::TriggerMatch
{
    std::shared_ptr<sigrok::Channel> get_channel()
    {
        return $self->channel();
    }
}

/* -------------------------------------------------------------------------
 * Convenience methods that return native Octave cell arrays instead of
 * std::map wrappers (which don't work well in the Octave SWIG target).
 *
 * Usage:
 *   c = Context.create();
 *   d = c.driver_list();     % Nx2 cell: {name, Driver; ...}
 *   d{1,1}                   % name of first driver
 *   d{1,2}                   % Driver object
 *
 *   ifmts = c.input_format_list();
 *   ofmts = c.output_format_list();
 * -------------------------------------------------------------------------*/
%extend sigrok::Context
{
    /* Returns Nx2 cell array: { "name", DriverObj ; ... } */
    Cell driver_list()
    {
        auto m = $self->drivers();
        octave_idx_type n = (octave_idx_type) m.size();
        Cell c(n, 2);
        octave_idx_type i = 0;
        for (auto &kv : m) {
            c(i, 0) = octave_value(kv.first);
            c(i, 1) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::Driver>(kv.second),
                SWIGTYPE_p_std__shared_ptrT_sigrok__Driver_t,
                SWIG_POINTER_OWN);
            i++;
        }
        return c;
    }

    /* Returns Nx2 cell array: { "name", InputFormatObj ; ... } */
    Cell input_format_list()
    {
        auto m = $self->input_formats();
        octave_idx_type n = (octave_idx_type) m.size();
        Cell c(n, 2);
        octave_idx_type i = 0;
        for (auto &kv : m) {
            c(i, 0) = octave_value(kv.first);
            c(i, 1) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::InputFormat>(kv.second),
                SWIGTYPE_p_std__shared_ptrT_sigrok__InputFormat_t,
                SWIG_POINTER_OWN);
            i++;
        }
        return c;
    }

    /* Returns Nx2 cell array: { "name", OutputFormatObj ; ... } */
    Cell output_format_list()
    {
        auto m = $self->output_formats();
        octave_idx_type n = (octave_idx_type) m.size();
        Cell c(n, 2);
        octave_idx_type i = 0;
        for (auto &kv : m) {
            c(i, 0) = octave_value(kv.first);
            c(i, 1) = SWIG_NewPointerObj(
                new std::shared_ptr<sigrok::OutputFormat>(kv.second),
                SWIGTYPE_p_std__shared_ptrT_sigrok__OutputFormat_t,
                SWIG_POINTER_OWN);
            i++;
        }
        return c;
    }

    /* Create a header packet (current UTC time as start_time). */
    std::shared_ptr<sigrok::Packet> create_header_packet()
    {
        return $self->create_header_packet(Glib::DateTime::create_now_utc());
    }

    /* Create a meta packet from an Octave struct of config key/value pairs.
     * E.g.: meta.samplerate = uint64(1000000) */
    std::shared_ptr<sigrok::Packet> create_meta_packet(octave_value opts)
    {
        std::map<const sigrok::ConfigKey *, Glib::VariantBase> cfg;
        if (opts.isstruct()) {
            octave_scalar_map s = opts.scalar_map_value();
            string_vector fields = s.fieldnames();
            for (octave_idx_type i = 0; i < fields.numel(); i++) {
                std::string fname = fields(i);
                octave_value val = s.getfield(fname);
                auto key = sigrok::ConfigKey::get_by_identifier(fname);
                cfg[key] = octave_to_variant_by_key(val, key);
            }
        }
        return $self->create_meta_packet(cfg);
    }

    /* Create an end packet. */
    std::shared_ptr<sigrok::Packet> create_end_packet()
    {
        return $self->create_end_packet();
    }

    /* Create a UserDevice (virtual device for output testing).
     * Usage: dev = ctx.create_user_device('vendor', 'model', 'version') */
    std::shared_ptr<sigrok::UserDevice> create_user_device(
        std::string vendor, std::string model, std::string version)
    {
        return $self->create_user_device(vendor, model, version);
    }
}
