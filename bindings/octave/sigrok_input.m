## Copyright (C) 2024 libsigrok contributors
##
## This program is free software: you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.
##
## -*- texinfo -*-
## @deftypefn  {} {[@var{logic}, @var{analog}] =} sigrok_input (@var{context}, @var{input})
##
## Feed data through a sigrok Input object and collect the decoded packets.
##
## @var{context} is a @code{Context} object from @code{Context.create()}.
## @var{input}   is a fresh @code{Input} object from
##               @code{InputFormat.create_input()}.  The caller must NOT have
##               called @code{send_data} or @code{input_end} yet — this
##               function sets up the session first, then feeds the data.
##
## @var{data} is a @code{uint8} row or column vector containing the raw
## input bytes (e.g. the text of a VCD file).
##
## Returns:
## @table @var
## @item logic
##   Cell array of uint8 matrices, one per LOGIC packet.
##   Each matrix is @code{samples x unit_size}.
## @item analog
##   Cell array of double matrices, one per ANALOG packet.
##   Each matrix is @code{channels x samples}.
## @end table
##
## Example — parse a VCD byte string:
## @example
##   fmt  = ctx.input_format_list()  % find 'vcd' entry
##   inp  = fmt.create_input();
##   [logic, analog] = sigrok_input(ctx, inp, uint8(vcd_text));
## @end example
##
## @seealso{sigrok_capture, Context.create}
## @end deftypefn

function [logic, analog] = sigrok_input(context, input, data)

  global _sigrok_input_logic _sigrok_input_analog _sigrok_input_stopped;
  global _sigrok_input_sess;
  _sigrok_input_logic   = {};
  _sigrok_input_analog  = {};
  _sigrok_input_stopped = false;
  _sigrok_input_sess    = [];

  %% The libsigrok input flow requires a two-phase approach:
  %%
  %%   Phase 1 — send_data(data)
  %%     The input module parses the file header and sets sdi_ready = true.
  %%     At this point sdi->session is still NULL so no datafeed packets
  %%     are dispatched yet (sr_session_send() guards on sdi->session).
  %%
  %%   Phase 2 — get_device() → add_device() → input_end()
  %%     get_device() only succeeds after sdi_ready; add_device() wires
  %%     sdi->session so that input_end() can flush buffered data through
  %%     the datafeed callbacks.
  %%
  _sigrok_input_sess = context.create_session();
  try
    _sigrok_input_sess.add_datafeed_callback(@_sigrok_input_cb);

    %% Phase 1: send data so the module populates the device instance
    input.send_data(data);

    %% Phase 2: now the device instance is ready
    idev = input.get_device();
    _sigrok_input_sess.add_device(idev);

    %% Flush buffered data — datafeed callbacks fire here
    input.input_end();

  catch e
    clear global _sigrok_input_logic _sigrok_input_analog _sigrok_input_stopped _sigrok_input_sess;
    rethrow(e);
  end

  logic  = _sigrok_input_logic;
  analog = _sigrok_input_analog;

  clear global _sigrok_input_logic _sigrok_input_analog _sigrok_input_stopped _sigrok_input_sess;

endfunction


function _sigrok_input_cb(device, packet)
  global _sigrok_input_logic _sigrok_input_analog _sigrok_input_stopped;
  global _sigrok_input_sess;

  pt = packet.type.name;

  if strcmp(pt, 'LOGIC')
    payload = packet.payload_logic();
    _sigrok_input_logic{end+1} = payload.data();

  elseif strcmp(pt, 'ANALOG')
    payload = packet.payload_analog();
    _sigrok_input_analog{end+1} = payload.data();

  elseif strcmp(pt, 'END')
    if !_sigrok_input_stopped
      _sigrok_input_stopped = true;
    end
  endif

endfunction
