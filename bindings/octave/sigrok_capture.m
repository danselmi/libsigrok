## Copyright (C) 2024 libsigrok contributors
##
## This program is free software: you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.
##
## -*- texinfo -*-
## @deftypefn  {} {[@var{logic}, @var{analog}] =} sigrok_capture (@var{context}, @var{device})
## @deftypefnx {} {[@var{logic}, @var{analog}] =} sigrok_capture (@var{context}, @var{device}, @var{opts})
##
## Capture one burst of data from a sigrok device.
##
## @var{context} is a @code{Context} object from @code{Context.create()}.
## @var{device}  is a @code{HardwareDevice} returned by @code{Driver.scan()}.
## @var{opts}    is an optional struct with any of:
##
## @table @code
## @item opts.limit_samples
##   Number of samples to capture (uint64).  Default: driver decides.
## @item opts.limit_msec
##   Capture duration in milliseconds (uint64).  Default: driver decides.
## @item opts.samplerate
##   Sample rate in Hz (uint64).  Set only if the driver supports it.
## @end table
##
## Returns:
## @table @var
## @item logic
##   Cell array of uint8 matrices, one per LOGIC packet received.
##   Each matrix is @code{samples x unit_size}.
##   Extract channel N (0-based):
##   @code{bitand(logic@{k@}(:, floor(N/8)+1), uint8(2^mod(N,8))) > 0}
## @item analog
##   Cell array of double matrices, one per ANALOG packet received.
##   Each matrix is @code{channels x samples}.
## @end table
##
## Example — demo driver, 1000 samples:
## @example
##   addpath('sigrok/core');  sigrok;
##   ctx = Context.create();
##   d = ctx.driver_list();
##   demo = d@{strcmp(d(:,1),'demo'), 2@};
##   dev = demo.scan()@{1@};
##   dev.open();
##   opts.limit_samples = uint64(1000);
##   [logic, analog] = sigrok_capture(ctx, dev, opts);
##   dev.close();
##   data = vertcat(analog@{:@});   % channels x total_samples double matrix
## @end example
##
## Example — ipdbg-la over TCP:
## @example
##   scan_opts.conn = 'tcp-raw/127.0.0.1/4242';
##   dev = ipdbg_driver.scan(scan_opts)@{1@};
##   dev.open();
##   [logic, ~] = sigrok_capture(ctx, dev);
##   dev.close();
##   raw = vertcat(logic@{:@});          % N x unit_size uint8 matrix
##   ch0 = bitand(raw(:,1), uint8(1)) > 0;  % channel 0 as logical vector
## @end example
##
## @seealso{Context.create, Driver.scan}
## @end deftypefn

function [logic, analog] = sigrok_capture(context, device, opts)

  if nargin < 3
    opts = struct();
  end

  %% --- apply config options (warn and skip if driver doesn't support them)
  %% SWIG Octave generates free functions with underscores, not dot-syntax.
  %% ConfigKey.get_by_identifier() in the SWIG wrapper becomes the global
  %% function ConfigKey_get_by_identifier().
  config_keys = {'limit_samples', 'limit_msec', 'samplerate'};
  for i = 1:numel(config_keys)
    k = config_keys{i};
    if isfield(opts, k)
      try
        key = ConfigKey_get_by_identifier(k);
        device.config_set(key, opts.(k));
      catch e
        warning('sigrok_capture: cannot set %s: %s', k, e.message);
      end
    end
  end

  %% --- use globals for callback state (Octave closures are by value;
  %% named subfunctions cannot capture locals from the calling function)
  global _sigrok_capture_logic _sigrok_capture_analog _sigrok_capture_stopped;
  global _sigrok_capture_sess;
  _sigrok_capture_logic   = {};
  _sigrok_capture_analog  = {};
  _sigrok_capture_stopped = false;
  _sigrok_capture_sess    = [];

  _sigrok_capture_sess = context.create_session();
  try
    _sigrok_capture_sess.add_device(device);
    _sigrok_capture_sess.add_datafeed_callback(@_sigrok_capture_cb);
    _sigrok_capture_sess.start();
    _sigrok_capture_sess.run();   % blocks; callback calls sess.stop() on END packet
  catch e
    %% clean up globals before re-throwing
    clear global _sigrok_capture_logic _sigrok_capture_analog _sigrok_capture_stopped _sigrok_capture_sess;
    rethrow(e);
  end

  logic  = _sigrok_capture_logic;
  analog = _sigrok_capture_analog;

  %% clean up globals
  clear global _sigrok_capture_logic _sigrok_capture_analog _sigrok_capture_stopped _sigrok_capture_sess;

endfunction


%% ---------------------------------------------------------------------------
%% Internal datafeed callback — not intended for direct use.
%% sess is accessed via global because Octave named functions cannot capture
%% locals from an enclosing function scope.
%% ---------------------------------------------------------------------------
function _sigrok_capture_cb(device, packet)
  global _sigrok_capture_logic _sigrok_capture_analog _sigrok_capture_stopped;
  global _sigrok_capture_sess;

  pt = packet.type.name;

  if strcmp(pt, 'LOGIC')
    payload = packet.payload_logic();
    _sigrok_capture_logic{end+1} = payload.data();

  elseif strcmp(pt, 'ANALOG')
    payload = packet.payload_analog();
    _sigrok_capture_analog{end+1} = payload.data();

  elseif strcmp(pt, 'END')
    if !_sigrok_capture_stopped
      _sigrok_capture_stopped = true;
      _sigrok_capture_sess.stop();
    end
  endif

endfunction
