%% test_sigrok.m — Automated test suite for libsigrok Octave bindings
%%
%% Tests run entirely against the built-in 'demo' driver; no hardware needed.
%%
%% Usage (from bindings/octave/):
%%   addpath('sigrok/core');  sigrok;
%%   test_sigrok
%%
%% Each test prints PASS / FAIL.  The script exits with a non-zero status
%% (via error()) if any test fails, so it can be used in CI:
%%
%%   octave --no-gui --path sigrok/core \
%%          --eval "sigrok; test_sigrok" && echo OK

%% ---------------------------------------------------------------------------
%% Initialisation
%% ---------------------------------------------------------------------------
addpath(fullfile(fileparts(mfilename('fullpath')), 'sigrok', 'core'));
sigrok;

pass_count = 0;
fail_count = 0;
fail_msgs  = {};

function result = assert_eq(a, b)
  result = isequal(a, b);
end

function _report(name, ok, fail_msgs, pass_count, fail_count)
  %% internal — not called directly; results collected via test() below
end

%% Minimal test runner: test(name, expr_result)
%%   expr_result must evaluate to a scalar logical true/false.
%%   Wrap in try/catch at call-site if the expression can throw.
function [pc, fc, fm] = t(name, ok, pc, fc, fm)
  if ok
    fprintf('  PASS  %s\n', name);
    pc = pc + 1;
  else
    fprintf('  FAIL  %s\n', name);
    fc = fc + 1;
    fm{end+1} = name;
  end
end

%% ---------------------------------------------------------------------------
%% 1. Context creation
%% ---------------------------------------------------------------------------
fprintf('\n=== 1. Context ===\n');
ctx = [];
try
  ctx = Context.create();
  [pass_count, fail_count, fail_msgs] = t('Context.create() returns object', ...
    ~isempty(ctx), pass_count, fail_count, fail_msgs);
catch e
  [pass_count, fail_count, fail_msgs] = t('Context.create() does not throw', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

if ~isempty(ctx)
  [pass_count, fail_count, fail_msgs] = t('package_version is non-empty string', ...
    ischar(ctx.package_version) && ~isempty(ctx.package_version), ...
    pass_count, fail_count, fail_msgs);

  [pass_count, fail_count, fail_msgs] = t('lib_version is non-empty string', ...
    ischar(ctx.lib_version) && ~isempty(ctx.lib_version), ...
    pass_count, fail_count, fail_msgs);
end

%% ---------------------------------------------------------------------------
%% 2. Driver list
%% ---------------------------------------------------------------------------
fprintf('\n=== 2. Drivers ===\n');
drv_list = [];
try
  drv_list = ctx.driver_list();
catch e
  drv_list = {};
end

[pass_count, fail_count, fail_msgs] = t('driver_list() returns cell array', ...
  iscell(drv_list), pass_count, fail_count, fail_msgs);

[pass_count, fail_count, fail_msgs] = t('driver_list() is non-empty', ...
  ~isempty(drv_list), pass_count, fail_count, fail_msgs);

%% driver_list() returns Nx2 cell: {name, Driver}
demo_drv = [];
if iscell(drv_list) && size(drv_list,2) == 2
  names = drv_list(:,1);
  idx   = strcmp(names, 'demo');
  [pass_count, fail_count, fail_msgs] = t('''demo'' driver present', ...
    any(idx), pass_count, fail_count, fail_msgs);
  if any(idx)
    demo_drv = drv_list{find(idx,1), 2};
    [pass_count, fail_count, fail_msgs] = t('demo driver name property == ''demo''', ...
      strcmp(demo_drv.name, 'demo'), pass_count, fail_count, fail_msgs);
    [pass_count, fail_count, fail_msgs] = t('demo driver long_name non-empty', ...
      ischar(demo_drv.long_name) && ~isempty(demo_drv.long_name), ...
      pass_count, fail_count, fail_msgs);
  end
end

%% ---------------------------------------------------------------------------
%% 3. Device scan (demo driver)
%% ---------------------------------------------------------------------------
fprintf('\n=== 3. Device scan ===\n');
dev = [];
if ~isempty(demo_drv)
  try
    devices = demo_drv.scan();
    [pass_count, fail_count, fail_msgs] = t('demo.scan() returns cell array', ...
      iscell(devices), pass_count, fail_count, fail_msgs);
    [pass_count, fail_count, fail_msgs] = t('demo.scan() finds at least one device', ...
      ~isempty(devices), pass_count, fail_count, fail_msgs);
    if ~isempty(devices)
      dev = devices{1};
      [pass_count, fail_count, fail_msgs] = t('device vendor is string', ...
        ischar(dev.vendor), pass_count, fail_count, fail_msgs);
      [pass_count, fail_count, fail_msgs] = t('device model is string', ...
        ischar(dev.model), pass_count, fail_count, fail_msgs);
    end
  catch e
    [pass_count, fail_count, fail_msgs] = t('demo.scan() does not throw', ...
      false, pass_count, fail_count, fail_msgs);
    fprintf('     exception: %s\n', e.message);
  end
end

%% ---------------------------------------------------------------------------
%% 4. ConfigKey lookup
%% ---------------------------------------------------------------------------
fprintf('\n=== 4. ConfigKey ===\n');
try
  ck = ConfigKey.get_by_identifier('limit_samples');
  [pass_count, fail_count, fail_msgs] = t('ConfigKey.get_by_identifier(''limit_samples'') succeeds', ...
    true, pass_count, fail_count, fail_msgs);
  [pass_count, fail_count, fail_msgs] = t('ConfigKey.LIMIT_SAMPLES.identifier == ''limit_samples''', ...
    strcmp(ConfigKey.LIMIT_SAMPLES.identifier, 'limit_samples'), ...
    pass_count, fail_count, fail_msgs);
catch e
  [pass_count, fail_count, fail_msgs] = t('ConfigKey.get_by_identifier works', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

try
  ConfigKey.get_by_identifier('__no_such_key__');
  [pass_count, fail_count, fail_msgs] = t('ConfigKey.get_by_identifier(bad key) throws', ...
    false, pass_count, fail_count, fail_msgs);
catch
  [pass_count, fail_count, fail_msgs] = t('ConfigKey.get_by_identifier(bad key) throws', ...
    true, pass_count, fail_count, fail_msgs);
end

%% ---------------------------------------------------------------------------
%% 5. config_set / config_get on demo device
%% ---------------------------------------------------------------------------
fprintf('\n=== 5. config_set / config_get ===\n');
if ~isempty(dev)
  try
    dev.open();
    ck_ls = ConfigKey.get_by_identifier('limit_samples');
    dev.config_set(ck_ls, uint64(512));
    got = dev.config_get(ck_ls);
    [pass_count, fail_count, fail_msgs] = t('config_set/get limit_samples round-trips', ...
      isequal(got, uint64(512)), pass_count, fail_count, fail_msgs);

    ck_sr = ConfigKey.get_by_identifier('samplerate');
    dev.config_set(ck_sr, uint64(1000000));
    got_sr = dev.config_get(ck_sr);
    [pass_count, fail_count, fail_msgs] = t('config_set/get samplerate round-trips', ...
      isequal(got_sr, uint64(1000000)), pass_count, fail_count, fail_msgs);
    dev.close();
  catch e
    [pass_count, fail_count, fail_msgs] = t('config_set/config_get work on demo device', ...
      false, pass_count, fail_count, fail_msgs);
    fprintf('     exception: %s\n', e.message);
    try; dev.close(); catch; end
  end
end

%% ---------------------------------------------------------------------------
%% 6. config_list on demo device
%% ---------------------------------------------------------------------------
fprintf('\n=== 6. config_list ===\n');
if ~isempty(dev)
  try
    dev.open();

    %% SR_CONF_SAMPLERATE -> a{sv} with "samplerates" or "samplerate-steps"
    ck_sr = ConfigKey.get_by_identifier('samplerate');
    sr_list = dev.config_list(ck_sr);
    [pass_count, fail_count, fail_msgs] = t('config_list(samplerate) returns struct', ...
      isstruct(sr_list), pass_count, fail_count, fail_msgs);

    %% The demo driver uses "samplerate-steps" (stored as samplerate_steps field)
    if isstruct(sr_list)
      fnames = fieldnames(sr_list);
      has_rates = any(strcmp(fnames, 'samplerates')) || any(strcmp(fnames, 'samplerate_steps'));
      [pass_count, fail_count, fail_msgs] = t('samplerate list has rates or steps field', ...
        has_rates, pass_count, fail_count, fail_msgs);

      if any(strcmp(fnames, 'samplerates'))
        rates = sr_list.samplerates;
        [pass_count, fail_count, fail_msgs] = t('samplerates field is numeric array', ...
          isnumeric(rates) && numel(rates) > 0, pass_count, fail_count, fail_msgs);
      elseif any(strcmp(fnames, 'samplerate_steps'))
        steps = sr_list.samplerate_steps;
        [pass_count, fail_count, fail_msgs] = t('samplerate_steps field is numeric array', ...
          isnumeric(steps) && numel(steps) > 0, pass_count, fail_count, fail_msgs);
      end
    end

    dev.close();
  catch e
    [pass_count, fail_count, fail_msgs] = t('config_list works on demo device', ...
      false, pass_count, fail_count, fail_msgs);
    fprintf('     exception: %s\n', e.message);
    try; dev.close(); catch; end
  end
end

%% ---------------------------------------------------------------------------
%% 7. LogLevel
%% ---------------------------------------------------------------------------
fprintf('\n=== 7. LogLevel ===\n');
try
  ll = LogLevel.WARN;
  [pass_count, fail_count, fail_msgs] = t('LogLevel.WARN accessible', ...
    ~isempty(ll), pass_count, fail_count, fail_msgs);
  [pass_count, fail_count, fail_msgs] = t('LogLevel.WARN id == 2', ...
    ll.id == 2, pass_count, fail_count, fail_msgs);
catch e
  [pass_count, fail_count, fail_msgs] = t('LogLevel accessible', ...
    false, pass_count, fail_count, fail_msgs);
end

try
  ctx.set_log_level(LogLevel.ERR);
  got_ll = ctx.log_level;
  [pass_count, fail_count, fail_msgs] = t('set_log_level(ERR) / log_level round-trip', ...
    got_ll.id == LogLevel.ERR.id, pass_count, fail_count, fail_msgs);
  ctx.set_log_level(LogLevel.WARN);   %% restore
catch e
  [pass_count, fail_count, fail_msgs] = t('set_log_level / log_level', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

%% ---------------------------------------------------------------------------
%% 8. Input/output format lists
%% ---------------------------------------------------------------------------
fprintf('\n=== 8. Input/Output formats ===\n');
%% The Octave binding exposes these as input_format_list() / output_format_list()
%% (not as properties named input_formats / output_formats).
try
  ifmts = ctx.input_format_list();
  [pass_count, fail_count, fail_msgs] = t('input_format_list() returns cell array', ...
    iscell(ifmts), pass_count, fail_count, fail_msgs);
  [pass_count, fail_count, fail_msgs] = t('input_format_list() non-empty', ...
    ~isempty(ifmts), pass_count, fail_count, fail_msgs);
catch e
  [pass_count, fail_count, fail_msgs] = t('input_format_list() accessible', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

try
  ofmts = ctx.output_format_list();
  [pass_count, fail_count, fail_msgs] = t('output_format_list() returns cell array', ...
    iscell(ofmts), pass_count, fail_count, fail_msgs);
  [pass_count, fail_count, fail_msgs] = t('output_format_list() non-empty', ...
    ~isempty(ofmts), pass_count, fail_count, fail_msgs);
catch e
  [pass_count, fail_count, fail_msgs] = t('output_format_list() accessible', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

%% ---------------------------------------------------------------------------
%% 9. create_logic_packet
%% ---------------------------------------------------------------------------
fprintf('\n=== 9. create_logic_packet ===\n');
try
  raw = uint8([1 0; 0 1; 1 1; 0 0]);   %% 4 samples, unit_size=2
  pkt = ctx.create_logic_packet(raw, 2);
  [pass_count, fail_count, fail_msgs] = t('create_logic_packet returns object', ...
    ~isempty(pkt), pass_count, fail_count, fail_msgs);
catch e
  [pass_count, fail_count, fail_msgs] = t('create_logic_packet', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

%% ---------------------------------------------------------------------------
%% 10. Datafeed session — demo driver, 200 samples
%% ---------------------------------------------------------------------------
fprintf('\n=== 10. Demo capture (200 samples via sigrok_capture) ===\n');
if ~isempty(dev)
  try
    addpath(fileparts(mfilename('fullpath')));   %% ensure sigrok_capture.m is on path
    try
      dev.open();
    catch oe
      %% "already open" is fine; any other error is surfaced in the outer catch
      if isempty(strfind(oe.message, 'already'))
        rethrow(oe);
      end
    end
    cap_opts = struct();
    cap_opts.limit_samples = uint64(200);
    cap_opts.samplerate    = uint64(100000);
    [logic_pkts, analog_pkts] = sigrok_capture(ctx, dev, cap_opts);
    dev.close();

    [pass_count, fail_count, fail_msgs] = t('sigrok_capture returns cell arrays', ...
      iscell(logic_pkts) && iscell(analog_pkts), pass_count, fail_count, fail_msgs);

    [pass_count, fail_count, fail_msgs] = t('analog packets received', ...
      ~isempty(analog_pkts), pass_count, fail_count, fail_msgs);

    if ~isempty(analog_pkts)
      mat = analog_pkts{1};
      [pass_count, fail_count, fail_msgs] = t('analog matrix is double', ...
        isa(mat, 'double'), pass_count, fail_count, fail_msgs);
      [pass_count, fail_count, fail_msgs] = t('analog matrix has 2 dims', ...
        ndims(mat) == 2, pass_count, fail_count, fail_msgs);
      [pass_count, fail_count, fail_msgs] = t('analog channels >= 1', ...
        size(mat,1) >= 1, pass_count, fail_count, fail_msgs);
      [pass_count, fail_count, fail_msgs] = t('analog samples > 0', ...
        size(mat,2) > 0, pass_count, fail_count, fail_msgs);

      total_samples = sum(cellfun(@(m) size(m,2), analog_pkts));
      [pass_count, fail_count, fail_msgs] = t('total analog samples >= 200', ...
        total_samples >= 200, pass_count, fail_count, fail_msgs);
    end
  catch e
    [pass_count, fail_count, fail_msgs] = t('sigrok_capture (demo) does not throw', ...
      false, pass_count, fail_count, fail_msgs);
    fprintf('     exception: %s\n', e.message);
    try; dev.close(); catch; end
  end
end

%% ---------------------------------------------------------------------------
%% 11. Channel access
%% ---------------------------------------------------------------------------
fprintf('\n=== 11. Channel access ===\n');
if ~isempty(dev)
  try
    dev.open();
    %% channels() returns a native Octave cell array of Channel objects
    chs = dev.get_channels();
    [pass_count, fail_count, fail_msgs] = t('channels() returns cell array', ...
      iscell(chs), pass_count, fail_count, fail_msgs);
    [pass_count, fail_count, fail_msgs] = t('at least one channel returned', ...
      ~isempty(chs), pass_count, fail_count, fail_msgs);
    if ~isempty(chs)
      ch = chs{1};
      [pass_count, fail_count, fail_msgs] = t('channel name is string', ...
        ischar(ch.name), pass_count, fail_count, fail_msgs);
      [pass_count, fail_count, fail_msgs] = t('channel enabled is logical', ...
        islogical(ch.enabled), pass_count, fail_count, fail_msgs);
      orig_enabled = ch.enabled;
      ch.enabled = !orig_enabled;
      [pass_count, fail_count, fail_msgs] = t('channel enabled can be toggled', ...
        ch.enabled == !orig_enabled, pass_count, fail_count, fail_msgs);
      ch.enabled = orig_enabled;   %% restore
    end
    dev.close();
  catch e
    [pass_count, fail_count, fail_msgs] = t('channel access', ...
      false, pass_count, fail_count, fail_msgs);
    fprintf('     exception: %s\n', e.message);
    try; dev.close(); catch; end
  end
end

%% ---------------------------------------------------------------------------
%% 12. Output format — VCD
%%
%% Strategy: create a UserDevice with two logic channels, create a VCD Output,
%% then feed it a sequence of hand-crafted packets (header, meta, logic, end)
%% and verify the collected VCD text is well-formed.
%%
%% Packet sequence required by VCD output:
%%   SR_DF_HEADER  — signals start of capture
%%   SR_DF_META    — samplerate (needed so VCD timescale is correct)
%%   SR_DF_LOGIC   — actual sample data
%%   SR_DF_END     — signals end of capture
%%
%% Output.receive(packet) returns a string chunk for each packet;
%% we concatenate them to get the full VCD text.
%% ---------------------------------------------------------------------------
fprintf('\n=== 12. Output format — VCD ===\n');
try
  %% --- build a small virtual device with 2 logic channels ---
  udev = ctx.create_user_device('Test', 'VCD-test', '1.0');
  udev.add_channel(0, ChannelType.LOGIC, 'CLK');
  udev.add_channel(1, ChannelType.LOGIC, 'DATA');

  [pass_count, fail_count, fail_msgs] = t('create_user_device() succeeds', ...
    ~isempty(udev), pass_count, fail_count, fail_msgs);

  %% verify channels visible
  uchs = udev.get_channels();
  [pass_count, fail_count, fail_msgs] = t('UserDevice has 2 channels', ...
    iscell(uchs) && numel(uchs) == 2, pass_count, fail_count, fail_msgs);

  %% --- get VCD output format ---
  ofmts = ctx.output_format_list();
  vcd_fmt = [];
  for i = 1:size(ofmts, 1)
    if strcmp(ofmts{i,1}, 'vcd')
      vcd_fmt = ofmts{i,2};
      break;
    end
  end
  [pass_count, fail_count, fail_msgs] = t('VCD output format found', ...
    ~isempty(vcd_fmt), pass_count, fail_count, fail_msgs);

  if ~isempty(vcd_fmt)
    [pass_count, fail_count, fail_msgs] = t('VCD format name is ''vcd''', ...
      strcmp(vcd_fmt.name, 'vcd'), pass_count, fail_count, fail_msgs);

    %% --- create Output ---
    out = vcd_fmt.create_output(udev);
    [pass_count, fail_count, fail_msgs] = t('create_output(udev) returns object', ...
      ~isempty(out), pass_count, fail_count, fail_msgs);

    %% --- feed packets and collect VCD text ---
    vcd_text = '';

    %% 1) Header packet
    hdr_pkt  = ctx.create_header_packet();
    vcd_text = [vcd_text, out.receive(hdr_pkt)];

    %% 2) Meta packet with samplerate = 1 MHz
    meta_cfg.samplerate = uint64(1000000);
    meta_pkt = ctx.create_meta_packet(meta_cfg);
    vcd_text = [vcd_text, out.receive(meta_pkt)];

    %% 3) Logic packet: 4 samples, 1 byte per sample (unit_size=1)
    %%    byte layout: bit0=CLK, bit1=DATA
    %%    sample 0: CLK=0 DATA=0  -> 0x00
    %%    sample 1: CLK=1 DATA=0  -> 0x01
    %%    sample 2: CLK=0 DATA=1  -> 0x02
    %%    sample 3: CLK=1 DATA=1  -> 0x03
    raw = uint8([0; 1; 2; 3]);   %% 4 samples, unit_size=1
    logic_pkt = ctx.create_logic_packet(raw, 1);
    vcd_text = [vcd_text, out.receive(logic_pkt)];

    %% 4) End packet
    end_pkt  = ctx.create_end_packet();
    vcd_text = [vcd_text, out.receive(end_pkt)];

    %% --- verify VCD structure ---
    [pass_count, fail_count, fail_msgs] = t('VCD output is non-empty string', ...
      ischar(vcd_text) && ~isempty(vcd_text), pass_count, fail_count, fail_msgs);

    [pass_count, fail_count, fail_msgs] = t('VCD contains $timescale', ...
      ~isempty(strfind(vcd_text, '$timescale')), pass_count, fail_count, fail_msgs);

    [pass_count, fail_count, fail_msgs] = t('VCD contains $end', ...
      ~isempty(strfind(vcd_text, '$end')), pass_count, fail_count, fail_msgs);

    [pass_count, fail_count, fail_msgs] = t('VCD contains channel name CLK', ...
      ~isempty(strfind(vcd_text, 'CLK')), pass_count, fail_count, fail_msgs);

    [pass_count, fail_count, fail_msgs] = t('VCD contains channel name DATA', ...
      ~isempty(strfind(vcd_text, 'DATA')), pass_count, fail_count, fail_msgs);

    [pass_count, fail_count, fail_msgs] = t('VCD contains initial values', ...
      ~isempty(strfind(vcd_text, '#0')), pass_count, fail_count, fail_msgs);
  end

catch e
  [pass_count, fail_count, fail_msgs] = t('VCD output format test', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

%% ---------------------------------------------------------------------------
%% 13. Input format — VCD round-trip
%%
%% Strategy: re-parse the VCD text we generated in section 12.
%% Flow:
%%   1. Find 'vcd' input format in input_format_list()
%%   2. create_input() → Input object
%%   3. sigrok_input(ctx, inp, uint8(vcd_text)) — sets up session, feeds data
%%   5. Verify we got logic data back with the expected number of channels
%% ---------------------------------------------------------------------------
fprintf('\n=== 13. Input format — VCD round-trip ===\n');
addpath(fileparts(mfilename('fullpath')));   %% ensure sigrok_input.m is on path
if exist('vcd_text', 'var') && ischar(vcd_text) && ~isempty(vcd_text)
  try
    %% --- find vcd input format ---
    ifmts = ctx.input_format_list();
    vcd_ifmt = [];
    for i = 1:size(ifmts, 1)
      if strcmp(ifmts{i,1}, 'vcd')
        vcd_ifmt = ifmts{i,2};
        break;
      end
    end
    [pass_count, fail_count, fail_msgs] = t('VCD input format found', ...
      ~isempty(vcd_ifmt), pass_count, fail_count, fail_msgs);

    if ~isempty(vcd_ifmt)
      %% --- create Input object ---
      inp = vcd_ifmt.create_input();
      [pass_count, fail_count, fail_msgs] = t('create_input() returns object', ...
        ~isempty(inp), pass_count, fail_count, fail_msgs);

      %% --- sigrok_input sets up session, feeds data, collects packets ---
      [in_logic, in_analog] = sigrok_input(ctx, inp, uint8(vcd_text));

      [pass_count, fail_count, fail_msgs] = t('VCD input: got logic packets', ...
        ~isempty(in_logic), pass_count, fail_count, fail_msgs);

      if ~isempty(in_logic)
        raw = in_logic{1};
        [pass_count, fail_count, fail_msgs] = t('VCD input: logic data is uint8', ...
          isa(raw, 'uint8'), pass_count, fail_count, fail_msgs);
        [pass_count, fail_count, fail_msgs] = t('VCD input: got 4 samples', ...
          rows(raw) == 4, pass_count, fail_count, fail_msgs);
      end
    end

  catch e
    [pass_count, fail_count, fail_msgs] = t('VCD input format test', ...
      false, pass_count, fail_count, fail_msgs);
    fprintf('     exception: %s\n', e.message);
  end
else
  fprintf('  SKIP  (vcd_text not available — section 12 did not run)\n');
end

%% ---------------------------------------------------------------------------
%% 14. ChannelGroup access
%%
%% The demo driver creates at least "Logic" and "Analog" channel groups.
%% We verify:
%%   - channel_groups_list() returns an Nx2 cell
%%   - each row has a string name and a ChannelGroup object
%%   - ChannelGroup.name matches the key
%%   - ChannelGroup.get_channels() returns the channels in that group
%% ---------------------------------------------------------------------------
fprintf('\n=== 14. ChannelGroup access ===\n');
try
  %% dev is the HardwareDevice from section 3
  cgl = dev.channel_groups_list();
  [pass_count, fail_count, fail_msgs] = t('channel_groups_list() returns cell', ...
    iscell(cgl), pass_count, fail_count, fail_msgs);
  [pass_count, fail_count, fail_msgs] = t('channel_groups_list() non-empty', ...
    rows(cgl) >= 1, pass_count, fail_count, fail_msgs);
  [pass_count, fail_count, fail_msgs] = t('channel_groups_list() has 2 columns', ...
    columns(cgl) == 2, pass_count, fail_count, fail_msgs);

  if rows(cgl) >= 1
    %% First entry
    cg_name = cgl{1,1};
    cg_obj  = cgl{1,2};
    [pass_count, fail_count, fail_msgs] = t('channel group key is string', ...
      ischar(cg_name), pass_count, fail_count, fail_msgs);
    [pass_count, fail_count, fail_msgs] = t('channel group object non-empty', ...
      ~isempty(cg_obj), pass_count, fail_count, fail_msgs);
    [pass_count, fail_count, fail_msgs] = t('ChannelGroup.name matches key', ...
      strcmp(cg_obj.name, cg_name), pass_count, fail_count, fail_msgs);

    %% get_channels() on the ChannelGroup
    cg_chs = cg_obj.get_channels();
    [pass_count, fail_count, fail_msgs] = t('ChannelGroup.get_channels() returns cell', ...
      iscell(cg_chs), pass_count, fail_count, fail_msgs);
    [pass_count, fail_count, fail_msgs] = t('ChannelGroup has at least one channel', ...
      numel(cg_chs) >= 1, pass_count, fail_count, fail_msgs);

    if numel(cg_chs) >= 1
      [pass_count, fail_count, fail_msgs] = t('ChannelGroup channel name is string', ...
        ischar(cg_chs{1}.name), pass_count, fail_count, fail_msgs);
    end

    %% Check that "Logic" and "Analog" groups exist
    cg_names = cgl(:,1);
    [pass_count, fail_count, fail_msgs] = t('"Logic" channel group present', ...
      any(strcmp(cg_names, 'Logic')), pass_count, fail_count, fail_msgs);
    [pass_count, fail_count, fail_msgs] = t('"Analog" channel group present', ...
      any(strcmp(cg_names, 'Analog')), pass_count, fail_count, fail_msgs);
  end

catch e
  [pass_count, fail_count, fail_msgs] = t('ChannelGroup access test', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

%% ---------------------------------------------------------------------------
%% 15. Trigger configuration
%%
%% Verify:
%%   - ctx.create_trigger(name) returns a Trigger object
%%   - trigger.name property works
%%   - trigger.add_stage() returns a TriggerStage
%%   - stage.add_match(channel, TriggerMatchType.RISING) succeeds
%%   - stage.get_matches() returns a cell with one TriggerMatch
%%   - match.type.name == 'RISING'
%%   - match.get_channel().name matches the channel we used
%%   - trigger.get_stages() returns the stage we added
%%   - session.set_trigger / session.get_trigger round-trips
%% ---------------------------------------------------------------------------
fprintf('\n=== 15. Trigger configuration ===\n');
try
  trig = ctx.create_trigger('test_trig');
  [pass_count, fail_count, fail_msgs] = t('create_trigger() returns object', ...
    ~isempty(trig), pass_count, fail_count, fail_msgs);
  [pass_count, fail_count, fail_msgs] = t('trigger.name is correct', ...
    strcmp(trig.name, 'test_trig'), pass_count, fail_count, fail_msgs);

  stage = trig.add_stage();
  [pass_count, fail_count, fail_msgs] = t('add_stage() returns TriggerStage', ...
    ~isempty(stage), pass_count, fail_count, fail_msgs);

  %% Use first channel of the demo device (from section 3)
  dev_chs = dev.get_channels();
  ch0 = dev_chs{1};

  stage.add_match(ch0, TriggerMatchType.RISING);

  matches = stage.get_matches();
  [pass_count, fail_count, fail_msgs] = t('get_matches() returns cell', ...
    iscell(matches), pass_count, fail_count, fail_msgs);
  [pass_count, fail_count, fail_msgs] = t('one match added', ...
    numel(matches) == 1, pass_count, fail_count, fail_msgs);

  if numel(matches) >= 1
    m = matches{1};
    [pass_count, fail_count, fail_msgs] = t('match type name is RISING', ...
      strcmp(m.type.name, 'RISING'), pass_count, fail_count, fail_msgs);
    [pass_count, fail_count, fail_msgs] = t('match channel name correct', ...
      strcmp(m.get_channel().name, ch0.name), pass_count, fail_count, fail_msgs);
  end

  stages = trig.get_stages();
  [pass_count, fail_count, fail_msgs] = t('get_stages() returns cell', ...
    iscell(stages), pass_count, fail_count, fail_msgs);
  [pass_count, fail_count, fail_msgs] = t('one stage in trigger', ...
    numel(stages) == 1, pass_count, fail_count, fail_msgs);

  %% Attach trigger to a fresh session and read it back
  tsess = ctx.create_session();
  tsess.add_device(dev);

  set_ok = false;
  try
    tsess.set_trigger(trig);
    set_ok = true;
  catch e2
    fprintf('     set_trigger exception: %s\n', e2.message);
  end
  [pass_count, fail_count, fail_msgs] = t('session.set_trigger() succeeds', ...
    set_ok, pass_count, fail_count, fail_msgs);

  if set_ok
    get_ok = false;
    trig2 = [];
    try
      trig2 = tsess.get_trigger();
      get_ok = true;
    catch e3
      fprintf('     get_trigger exception: %s\n', e3.message);
    end
    [pass_count, fail_count, fail_msgs] = t('session.get_trigger() non-empty', ...
      get_ok && ~isempty(trig2), pass_count, fail_count, fail_msgs);
    if get_ok && ~isempty(trig2)
      [pass_count, fail_count, fail_msgs] = t('session trigger name correct', ...
        strcmp(trig2.name, 'test_trig'), pass_count, fail_count, fail_msgs);
    end
  end

catch e
  [pass_count, fail_count, fail_msgs] = t('Trigger configuration test', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

%% ---------------------------------------------------------------------------
%% 16. ChannelGroup config_list / config_get / config_set
%%     The demo driver exposes SR_CONF_PATTERN_MODE on channel groups.
%% ---------------------------------------------------------------------------
fprintf('\n=== 16. ChannelGroup config ===\n');
try
  cg_devs = demo_drv.scan();
  cg_dev  = cg_devs{1};
  cg_dev.open();

  cg_list = cg_dev.channel_groups_list();
  %% Find the Logic channel group
  logic_cg = [];
  for i = 1:size(cg_list, 1)
    if strcmp(cg_list{i,1}, 'Logic')
      logic_cg = cg_list{i,2};
    end
  end
  [pass_count, fail_count, fail_msgs] = t('Logic ChannelGroup found', ...
    ~isempty(logic_cg), pass_count, fail_count, fail_msgs);

  if ~isempty(logic_cg)
    ck_pm = [];
    try
      ck_pm = ConfigKey.get_by_identifier('pattern');
    catch e_ck
      fprintf('     ConfigKey exception: %s\n', e_ck.message);
    end
    [pass_count, fail_count, fail_msgs] = t('pattern ConfigKey found', ...
      ~isempty(ck_pm), pass_count, fail_count, fail_msgs);

    %% config_list should return a cell array of pattern name strings
    pm_list = [];
    try
      pm_list = logic_cg.config_list(ck_pm);
    catch e_cl
      fprintf('     config_list exception: %s\n', e_cl.message);
    end
    [pass_count, fail_count, fail_msgs] = t('cg.config_list(pattern) returns value', ...
      ~isempty(pm_list), pass_count, fail_count, fail_msgs);
    [pass_count, fail_count, fail_msgs] = t('cg.config_list result is cell or struct', ...
      iscell(pm_list) || isstruct(pm_list), pass_count, fail_count, fail_msgs);

    %% config_get: read current pattern mode
    cur_mode = [];
    try
      cur_mode = logic_cg.config_get(ck_pm);
    catch e_cg
      fprintf('     config_get exception: %s\n', e_cg.message);
    end
    [pass_count, fail_count, fail_msgs] = t('cg.config_get(pattern) returns string', ...
      ischar(cur_mode) && ~isempty(cur_mode), pass_count, fail_count, fail_msgs);

    %% config_set: write a different pattern mode and read it back
    %% The demo driver supports: logic_0, logic_1, random, sigrok, ...
    %% Pick one different from current
    if iscell(pm_list)
      alt_mode = pm_list{1};
      for k = 1:numel(pm_list)
        if ~strcmp(pm_list{k}, cur_mode)
          alt_mode = pm_list{k};
          break;
        end
      end
    else
      alt_mode = cur_mode;  %% no list to pick from; skip set test
    end

    try
      if ~isempty(ck_pm) && ischar(cur_mode)
        if ~strcmp(alt_mode, cur_mode)
          logic_cg.config_set(ck_pm, alt_mode);
          readback = logic_cg.config_get(ck_pm);
          [pass_count, fail_count, fail_msgs] = t('cg.config_set/get pattern round-trips', ...
            strcmp(readback, alt_mode), pass_count, fail_count, fail_msgs);
          logic_cg.config_set(ck_pm, cur_mode);
        else
          logic_cg.config_set(ck_pm, cur_mode);
          readback = logic_cg.config_get(ck_pm);
          [pass_count, fail_count, fail_msgs] = t('cg.config_set/get pattern round-trips', ...
            strcmp(readback, cur_mode), pass_count, fail_count, fail_msgs);
        end
      end
    catch e_cs
      fprintf('     config_set/get exception: %s\n', e_cs.message);
      [pass_count, fail_count, fail_msgs] = t('cg.config_set/get pattern round-trips', ...
        false, pass_count, fail_count, fail_msgs);
    end
  end

  cg_dev.close();

catch e
  [pass_count, fail_count, fail_msgs] = t('ChannelGroup config test', ...
    false, pass_count, fail_count, fail_msgs);
  fprintf('     exception: %s\n', e.message);
end

%% ---------------------------------------------------------------------------
%% Summary
%% ---------------------------------------------------------------------------
fprintf('\n=== Summary ===\n');
fprintf('  Passed : %d\n', pass_count);
fprintf('  Failed : %d\n', fail_count);

if fail_count > 0
  fprintf('\nFailed tests:\n');
  for i = 1:numel(fail_msgs)
    fprintf('  - %s\n', fail_msgs{i});
  end
  error('test_sigrok: %d test(s) failed.', fail_count);
else
  fprintf('\nAll tests passed.\n');
end
