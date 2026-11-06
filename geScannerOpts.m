function [sys_ge, PNSwt, suffix, zeroSlew] = geScannerOpts(scanner)
% geScannerOpts  GE scanner settings for converting a .seq to .pge with pge2.
%   [sys_ge, PNSwt, suffix, zeroSlew] = geScannerOpts(scanner)
%   The sequence design can be shared between scanners; only the .pge conversion
%   differs, so a writer can build one .pge per scanner.
%
%   Inputs
%     scanner   "premier" (GE SIGNA Premier) | "petmr" (GE SIGNA PET/MR)
%   Outputs
%     sys_ge    struct   pge2.opts(...) for pge2.check / pge2.validate
%     PNSwt     [1x3]    PNS weights passed to pge2.check
%     suffix    char     appended to output file names ('' for premier)
%     zeroSlew  logical  write maxSlew = 0 into the .pge header (see below)
%
%   g_max / slew_max only set what pge2.check enforces on the desktop. The scanner-side
%   interpreter derives its own limits from the system gradient configuration; on the
%   PET/MR these were 3.3 G/cm peak gradient and 11.9565 G/cm/ms peak slew, below the
%   coil ratings (premier 80 mT/m, 200 T/m/s; petmr 44 mT/m, 200 T/m/s).
%
%   PNS weights: premier [1 1 1]; petmr [0.1 0.1 0.1], because at [1 1 1] the XRMW
%   model puts typical prephaser and spoiler blocks at ~90%. The interpreter does not
%   compute PNS itself, so also review the PNS values at [1 1 1].
%
%   zeroSlew: the interpreter rejects a .pge whose header maxSlew exceeds its slew
%   limit; that is the field's only use. pge2.serialize writes the real peak slew
%   there. With zeroSlew = true a writer sets params.smax = 0 before serializing (as
%   the older PulCeq writer did) and keeps the real peak as smaxActual in its .mat.
%   This bypasses the console's peak-slew check; pge2.check still enforces slew_max.

switch string(scanner)
    case "premier"
        % GE SIGNA Premier, HRMW gradient coil.
        psd_rf_wait  = 148e-6;   % RF-gradient delay (s)
        psd_grd_wait = 152e-6;   % ADC-gradient delay (s)
        b1_max       = 0.25;     % Gauss
        g_max        = 5;        % Gauss/cm   (= 50 mT/m); coil rating 80 mT/m
        slew_max     = 20;       % Gauss/cm/ms (= 200 T/m/s); = coil rating
        coil         = 'hrmw';
        PNSwt        = [1 1 1];
        suffix       = '';
        zeroSlew     = true;     % .pge header maxSlew = 0 (see above)

    case "petmr"
        % GE SIGNA PET/MR, XRMW gradient coil.
        psd_rf_wait  = 42e-6;    % RF-gradient delay (s)
        psd_grd_wait = 44e-6;    % ADC-gradient delay (s)
        b1_max       = 0.25;     % Gauss
        g_max        = 3.3;      % Gauss/cm   (= 33 mT/m): the console's peak-gradient limit,
                                 %   which is also the interpreter's gradient full scale.
                                 %   Coil rating 44 mT/m.
        slew_max     = 20;       % Gauss/cm/ms (= 200 T/m/s); = coil rating. The console
                                 %   limit is 11.9565 G/cm/ms (see zeroSlew above).
        coil         = 'xrmw';
        PNSwt        = [0.1 0.1 0.1];
        suffix       = '_petmr';
        zeroSlew     = true;     % .pge header maxSlew = 0 (see above)

    otherwise
        error('geScannerOpts: unknown scanner "%s" (premier | petmr)', scanner);
end

sys_ge = pge2.opts(psd_rf_wait, psd_grd_wait, b1_max, g_max, slew_max, coil);
end
