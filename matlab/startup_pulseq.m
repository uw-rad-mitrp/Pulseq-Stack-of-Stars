function libs = startup_pulseq(varargin)
% startup_pulseq  Put the pinned Pulseq / pulseg / pge2 toolchain on the MATLAB path.
%   libs = startup_pulseq(name, value, ...)
%   Adds the toolboxes that ./setup.sh fetched into libs/:
%     libs/pulseq/matlab              +mr       Pulseq sequence design
%     libs/pulseg/matlab              +pulseg   .seq -> PulSeg intermediate representation
%     libs/pulseg/matlab/third_party  vararg_pair, textprogressbar, DataHash (used by pge2)
%     libs/pge2/matlab                +pge2     PulSeg -> GE .pge serialization
%
%   PulCeq is deliberately not added: it ships an older +pge2 package that shares function
%   names with pge2 (check/opts/plot/validate) but is incompatible (its pge2.check takes
%   'wt', not 'PNSwt'). Conflicting +pge2/+pulseg/+mr folders elsewhere on the path are
%   removed for this session, or raise an error with 'strict'.
%
%   Options
%     'quiet'   true/false (default false)  suppress the path summary
%     'root'    char  repo root (default: parent of this file's folder)
%     'strict'  true/false (default false)  error on conflicting packages instead of
%               removing them from the path
%   Output
%     libs      struct of absolute paths to each toolbox
%
%   Usage
%     addpath(fullfile(repoRoot, 'matlab')); startup_pulseq;

arg.quiet  = false;
arg.root   = '';
arg.strict = false;   % true = error on a conflicting package instead of removing it

for ii = 1:2:numel(varargin)
    assert(ischar(varargin{ii}) || isstring(varargin{ii}), ...
        'startup_pulseq: options must be name/value pairs');
    name = char(varargin{ii});
    assert(isfield(arg, name), 'startup_pulseq: unknown option ''%s''', name);
    arg.(name) = varargin{ii+1};
end

%% Locate the repo root (the folder holding libs/, setup.sh, versions.lock)
if isempty(arg.root)
    root = fileparts(fileparts(mfilename('fullpath')));   % parent of matlab/
else
    root = char(arg.root);
end
libsdir = fullfile(root, 'libs');

%% Fail early and clearly if setup.sh has not been run
required = {'pulseq', 'pulseg', 'pge2'};
missing  = required(~cellfun(@(d) isfolder(fullfile(libsdir, d)), required));
if ~isempty(missing)
    error(['startup_pulseq: missing toolbox(es): %s\n' ...
           'The pinned libraries have not been fetched yet. From a terminal:\n' ...
           '    cd %s\n    ./setup.sh\n'], strjoin(missing, ', '), root);
end

%% Build the path additions
% Order matters only for shadowing, which is verified below rather than relied on.
libs.root    = root;
libs.pulseq  = fullfile(libsdir, 'pulseq');
libs.pulseg  = fullfile(libsdir, 'pulseg');
libs.pge2    = fullfile(libsdir, 'pge2');
libs.examples = fullfile(libsdir, 'examples');   % optional, reference only

toAdd = { ...
    genpath(fullfile(libs.pulseq, 'matlab')), ...              % +mr, demoSeq, demoUnsorted
    fullfile(libs.pulseg, 'matlab'), ...                       % +pulseg
    genpath(fullfile(libs.pulseg, 'matlab', 'third_party')),... % vararg_pair, DataHash, ...
    fullfile(libs.pge2, 'matlab'), ...                         % +pge2
    };

for ii = 1:numel(toAdd)
    addpath(toAdd{ii});
end

%% Verify: no other +pge2 / +pulseg / +mr packages on the path
% which('pge2.check','-all') does not report package functions shadowed by another
% +pge2 folder, so scan the path folders instead of checking by name.
removed = {};
removed = [removed, checkNoRoguePackage('pge2',   libsdir, arg.strict)];
removed = [removed, checkNoRoguePackage('pulseg', libsdir, arg.strict)];
removed = [removed, checkNoRoguePackage('mr',     libsdir, arg.strict)];

if ~isempty(removed)
    warning('off', 'backtrace');
    warning(['startup_pulseq: removed %d conflicting package folder(s) from ' ...
             'the path for this session:\n%s\n' ...
             'These shadow the pinned toolchain and would decide silently, by ' ...
             'path order, which +pge2 you get.\n' ...
             'If they come back every time you launch MATLAB they are in your ' ...
             'saved path. To clear them permanently:\n' ...
             '    restoredefaultpath; savepath\n' ...
             'Pass startup_pulseq(''strict'', true) to error on these instead.'], ...
             numel(removed), sprintf('    %s\n', removed{:}));
    warning('on', 'backtrace');
end

% Plain (non-package) helpers can still be checked by name.
checkUnique('vararg_pair');
checkUnique('textprogressbar');

% pge2.check must be the PulSeg-era one, which takes 'PNSwt'.
src = fileread(which('pge2.check'));
if ~contains(src, 'arg.PNSwt')
    error(['startup_pulseq: the pge2.check on your path is the legacy PulCeq ' ...
           'version (takes ''wt'', not ''PNSwt''):\n    %s\n' ...
           'Run "restoredefaultpath" and re-run startup_pulseq.'], which('pge2.check'));
end

%% Summary
if ~arg.quiet
    fprintf('\npulseq/pulseg/pge2 toolchain ready:\n');
    printPin(root, 'pulseq', libs.pulseq);
    printPin(root, 'pulseg', libs.pulseg);
    printPin(root, 'pge2',   libs.pge2);
    fprintf('\n');
end

end

% ------------------------------------------------------------------
function removed = checkNoRoguePackage(pkg, libsdir, strict)
% Find +<pkg> folders on the path outside libsdir and remove them for this session.
% MATLAB silently uses the first +<pkg> folder on the path, so a stale entry (e.g. a
% PulCeq or an old copy in the saved path) would decide which implementation runs.
% With strict=true, error instead of removing.

removed = {};
entries = strsplit(path, pathsep);
rogue = {};
for ii = 1:numel(entries)
    e = entries{ii};
    if isempty(e); continue; end
    if isfolder(fullfile(e, ['+' pkg])) && ~startsWith(fullfile(e, filesep), fullfile(libsdir, filesep))
        rogue{end+1} = e; %#ok<AGROW>
    end
end
if isempty(rogue)
    return
end

if strict
    shown = cellfun(@(r) fullfile(r, ['+' pkg]), rogue, 'UniformOutput', false);
    error(['startup_pulseq: found +%s package(s) outside libs/:\n%s\n' ...
           'MATLAB picks whichever lands first on the path, silently. ' ...
           'PulCeq in particular ships an incompatible +pge2.\n' ...
           'Run "restoredefaultpath" and re-run startup_pulseq, or drop ' ...
           '''strict'' to have them removed automatically.'], ...
           pkg, sprintf('    %s\n', shown{:}));
end

for ii = 1:numel(rogue)
    rmpath(rogue{ii});
    removed{end+1} = fullfile(rogue{ii}, ['+' pkg]); %#ok<AGROW>
end
end

% ------------------------------------------------------------------
function checkUnique(fname)
% Error if 'fname' resolves to more than one file on the path.
hits = which(fname, '-all');
if isempty(hits)
    error('startup_pulseq: %s not found on path after setup.', fname);
end
% Ignore MATLAB's "shadowed by a variable/method" annotations
hits = hits(cellfun(@(h) ~contains(h, '% '), hits));
if numel(hits) > 1
    error(['startup_pulseq: %s is defined in %d places on the path:\n%s\n' ...
           'This is almost always a leftover PulCeq or an old *-main snapshot. ' ...
           'Run "restoredefaultpath" and re-run startup_pulseq.'], ...
           fname, numel(hits), sprintf('    %s\n', hits{:}));
end
end

% ------------------------------------------------------------------
function printPin(root, name, dir)
% Report the checked-out commit so the console log records what was used.
sha = '(not a git checkout)';
if isfolder(fullfile(dir, '.git'))
    [st, out] = system(sprintf('git -C "%s" rev-parse --short HEAD', dir));
    if st == 0
        sha = strtrim(out);
        [~, dirty] = system(sprintf('git -C "%s" status --porcelain', dir));
        if ~isempty(strtrim(dirty))
            sha = [sha ' (LOCALLY MODIFIED)'];
        end
    end
end
fprintf('  %-8s %s\n', name, sha);
end
