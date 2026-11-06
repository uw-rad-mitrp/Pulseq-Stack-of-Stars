% StackOfStars_newRotv3  3D radial stack-of-stars dual-echo (Dixon) GRE for GE (Pulseq).
%   Slab-selective RF-spoiled GRE: kz partition encoding with partial Fourier, rotated
%   in-plane radial spokes, two bipolar echoes per TR. Builds the design once per scanner
%   in SCANNERS and writes STARS_v3<suffix>.seq/.pge/.mat next to this script
%   (suffix '' for the SIGNA Premier, '_petmr' for the SIGNA PET/MR).
%   Requires: Pulseq 1.5.1, pulseg, pge2 (fetch with ./setup.sh) and geScannerOpts.m.
%   Run this script in MATLAB; it puts the toolchain on the path itself.

clear; clc; close all;
% Toolchain: walk up from this folder to the one holding matlab/startup_pulseq.m.
d = fileparts(mfilename('fullpath'));
while ~isfile(fullfile(d,'matlab','startup_pulseq.m')) && ~strcmp(d, fileparts(d))
    d = fileparts(d);
end
addpath(fullfile(d,'matlab')); startup_pulseq('quiet', true);
here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));           % repo root, for geScannerOpts.m

SCANNERS   = ["premier" "petmr"];   % one set of output files per scanner
WRITE_PGE  = true;                  % also write the .pge and .mat
DOVALIDATE = true;                  % compare psq against the .seq (slow)
for scanner = SCANNERS
    [sys_ge, PNSwt, sfx, zeroSlew] = geScannerOpts(scanner);

    % Design limits per scanner. Set here rather than read from geScannerOpts, so a
    % change to the .pge conversion settings cannot silently change the sequence.
    switch scanner
        case "premier"
            gradMax  = 50;                      % mT/m
            slewMax  = 150;                     % T/m/s
            TRreq    = 3.9e-3;                  % s
            spoilMax = gradMax;                 % z spoiler not capped
        case "petmr"
            gradMax  = 0.95*33;                 % 31.35 mT/m: 95% of the console's 3.3 G/cm
            slewMax  = 150;                     % T/m/s; above the console limit, relies on zeroSlew
            % Gradient heating: at TR 3.9 ms with a full-amplitude z spoiler the PET/MR
            % console's gradient heating check reported 176%. Capping the z spoiler/kz
            % rewinder at 10 mT/m (same area, longer) and lengthening TR brings it to a
            % predicted ~95%, as heating scales with 1/TR. The two readouts alone are
            % ~68% at TR 3.9 ms, which sets the floor.
            TRreq    = 5.312e-3;                % s
            spoilMax = 10;                      % mT/m, z spoiler + kz rewinder
    end
    sys = mr.opts('maxGrad', gradMax, 'GradUnit', 'mT/m', ...
        'maxSlew', slewMax, 'SlewUnit', 'T/m/s','B0', 3.0, ...
        'rfRingdownTime', 60e-6, ...
        'rfDeadTime', 100e-6, ...
        'adcDeadTime', 0, ...
        'rfRasterTime', 2e-6, ...
        'adcRasterTime', 2e-6, ...
        'gradRasterTime', 4e-6, ...
        'blockDurationRaster', 1e-6);
    commonRasterTime = 20e-6;

    seq=mr.Sequence(sys);
    %% Sequence parameters
    fov=500e-3;                     % in-plane FOV (m)
    Nx=256;Ny=256;Nz=30;             % matrix; Nz = partitions in the prescribed slab
    alpha=12;                       % flip angle (deg)
    sliceThickness=3e-3;            % partition thickness (m); slab = Nz*sliceThickness
    TR=TRreq;                        % repetition time (s), per scanner above; [] = shortest
    TE=1.1e-3;                       % first echo time (s); runs at the minimum if shorter
    rfSpoilingInc=117;              % RF spoiling phase increment (deg)
    rfDuration=0.5e-3;              % slab-select RF duration (s)
    rfTBW=8;                        % slab-select time-bandwidth product
    radial_oversampling = pi/2;     % nSpokes = Nx*pi/2 (radial Nyquist for full spokes)
    ETL = 2;                        % echoes per TR
    unibipolar_flag = 1;            % 0 = unipolar, 1 = bipolar
    angle_flag = 0;                 % 0 = linear (strided, see nLoops), 1 = golden
    nLoops = 4;                     % linear: angles sweep 0 .. nLoops*2*pi - delta
    nspoil = 6;
    pfkz_flag = 1;                  % 1 = partial Fourier in kz (see pfkz_ratio)
    no_phase_wrap = 1.5;            % in-plane (readout) oversampling factor
    no_slice_wrap = 1.08;           % slab oversampling factor (1.08 = 8%)
    gz_slew_derate = 0.7;           % slew derate for gz_beg / gzSpoil (PNS, see below)

    % Derived values
    nSpokes=floor(Nx*radial_oversampling); % Number of radial spokes
    % The linear stride advances nLoops*2*pi/nSpokes per spoke, so nSpokes and nLoops must
    % be coprime or the passes repeat angles (402 spokes with nLoops = 4 give only 201
    % distinct angles). floor(256*pi/2) = 402 is even, so round up to the next odd value.
    nSpokes = nSpokes + (1 - mod(nSpokes,2));   % 402 -> 403
    assert(gcd(nLoops,nSpokes)==1, ...
        ['nSpokes=%d shares a factor with nLoops=%d, so spoke angles repeat ' ...
         '(%d distinct instead of %d). Choose a coprime nSpokes.'], ...
         nSpokes, nLoops, nSpokes/gcd(nLoops,nSpokes), nSpokes);
    Nx_Eff = floor(Nx*no_phase_wrap);
    fov_Eff = fov*Nx_Eff/Nx;
    delta_k = 1/fov_Eff;
    k_width = Nx_Eff * delta_k;
    readoutTime = sys.adcRasterTime * Nx_Eff;
    pfkz_ratio = 0.3;               % fraction of kz partitions skipped

    %% Slab geometry
    % The RF excites the prescribed slab; kz encodes a slightly larger FOV so the RF
    % transition bands fall in extra partitions (discarded after recon) instead of
    % wrapping into the slab. Resolution is unchanged, as with no_phase_wrap in-plane.
    slabThickness = Nz * sliceThickness;            % prescribed slab, 90 mm
    Nz_Eff        = floor(Nz * no_slice_wrap);      % encoded partitions, 32
    fov_z_Eff     = Nz_Eff * sliceThickness;        % encoded z FOV, 96 mm

    %% RF and gradients
    % Slab-selective excitation (the whole slab, not one partition)
    [rf, gz, gzReph] = mr.makeSincPulse(alpha*pi/180,'Duration',rfDuration,...
        'SliceThickness',slabThickness,'apodization',0.5,'timeBwProduct',rfTBW,'system',sys,'use','excitation');

    % Readout gradient
    gx = mr.makeTrapezoid('x', 'system',sys, 'flatArea', Nx_Eff*delta_k, 'flatTime', readoutTime);
    gy = gx; gy.channel = 'y'; gy.amplitude = eps;
    ReadoutAmplitude = gx.amplitude;

    % ADC
    adc = mr.makeAdc(Nx_Eff, 'system', sys, 'Duration', gx.flatTime, 'Delay', gx.delay + gx.riseTime);

    % Derated slew for the z encode/spoil gradients. gz_beg ramps together with gxPre and
    % gzSpoil with gxSpoil, and PNS combines the axes, so at full slew these blocks
    % reached ~87% PNS (normal-mode limit 80%). Derating z alone to 0.7 gives ~68%
    % (lower values gain little). gz_beg stays shorter than gxPre, so only the spoiler
    % block gets longer.
    sysZ = sys; sysZ.maxSlew = sys.maxSlew * gz_slew_derate;

    % kz encoding
    PEmax = 1/fov_z_Eff;                            % kz step (1/m), over the oversampled z FOV
    peSliceStep = PEmax * ((0:Nz_Eff-1) - floor(Nz_Eff/2));
    if pfkz_flag == 1
        peSliceStep = peSliceStep(1+ceil(pfkz_ratio * Nz_Eff):end);
    end
    nPart = length(peSliceStep);                    % partitions actually played
    % gz_beg carries the slab rephaser and the kz encode in one trapezoid; the loop scales
    % it per partition. mr.scaleGrad changes amplitude only, so every instance keeps the
    % same timing (as pulseg requires). The reference must therefore be the partition with
    % the largest |area|, or some partitions would exceed the design amplitude and slew.
    areaZ_beg = gzReph.area + peSliceStep;
    [~, iRefBeg] = max(abs(areaZ_beg));
    gz_beg = mr.makeTrapezoid('z','Area',areaZ_beg(iRefBeg),'system',sysZ);

    peSliceStep_beg = areaZ_beg/areaZ_beg(iRefBeg);
    assert(max(abs(peSliceStep_beg)) <= 1+1e-9, ...
        'gz_beg reference partition is not the maximum (max|scale| = %.4f)', max(abs(peSliceStep_beg)));

    % z spoiler + kz rewinder, referenced to its largest-|area| partition in the same way.
    % z moment from the RF centre to the end of TR:
    %     +gz.area/2 (slab select) + (gzReph.area + kz) + (spoilz_area - kz) = spoilz_area
    % since gzReph.area = -gz.area/2. kz cancels, so spoiling is the same for every
    % partition, as RF spoiling needs.
    spoilz_area = 2/sliceThickness;   % 2 cycles of dephasing across one partition
    areaZ_end = spoilz_area - peSliceStep;
    [~, iRefEnd] = max(abs(areaZ_end));
    sysZspoil = sysZ;                    % amplitude cap (spoilMax) for gradient heating
    sysZspoil.maxGrad = min(sysZ.maxGrad, spoilMax*1e-3*sys.gamma);
    gzSpoil=mr.makeTrapezoid('z','Area',areaZ_end(iRefEnd),'system',sysZspoil);

    peSliceStep_end = areaZ_end/areaZ_end(iRefEnd);
    assert(max(abs(peSliceStep_end)) <= 1+1e-9, ...
        'gzSpoil reference partition is not the maximum (max|scale| = %.4f)', max(abs(peSliceStep_end)));

    % Readout prephaser, delayed so it ends together with gz_beg
    gxPre = mr.makeTrapezoid('x', 'system',sys, 'Area', -gx.area/2);
    gxPre.delay = max(mr.calcDuration(gz_beg) - mr.calcDuration(gxPre),0);
    gyPre = gxPre; gyPre.channel = 'y'; gyPre.amplitude = eps;

    % Readout rephaser between echoes (unipolar mode only)
    gxRe = mr.makeTrapezoid('x', 'system',sys, 'Area', -gx.area);
    gyRe = gxRe; gyRe.channel = 'y'; gyRe.amplitude = eps;

    if unibipolar_flag == 0 %unipolar
        gxareas = gxPre.area + gx.area;
    else
        gxareas = gxPre.area + gx.area * mod(ETL,2);
    end

    % In-plane spoiler: net readout moment at the end of TR = -Nx_Eff*delta_k
    spoilx_area = -1*Nx_Eff*delta_k - gxareas;
    gxSpoil=mr.makeTrapezoid('x','Area',spoilx_area,'system',sys,'Duration',mr.calcDuration(gzSpoil));
    gySpoil = gxSpoil; gySpoil.channel = 'y'; gySpoil.amplitude = eps;

    % TE delay. TE1 runs from the RF centre to the centre of the first readout block:
    % gxPre puts k at -gx.area/2 and the trapezoid is symmetric, so k = 0 is crossed
    % at calcDuration(gx)/2.
    minTE = (mr.calcDuration(rf,gz) - (rf.delay + mr.calcRfCenter(rf))) ...  % RF centre -> end of block 1
          +  mr.calcDuration(gxPre, gz_beg) ...                             % block 2
          +  mr.calcDuration(gx)/2;                                         % half of readout 1

    delayTE = ceil((TE - minTE)/seq.gradRasterTime)*seq.gradRasterTime;
    if delayTE < 0
        warning(['StackOfStars: requested TE = %.0f us is shorter than the minimum ' ...
                 '%.0f us. Running at the minimum. Shorten the RF or the prephaser ' ...
                 'block, or raise the readout bandwidth, to reach the requested TE.'], ...
                 TE*1e6, minTE*1e6);
        delayTE = 0;
    end
    TE_actual = minTE + delayTE;

    % dTE is set by the readout: the two bipolar lobes are identical trapezoids played
    % back to back, so dTE = calcDuration(gx), which is already the minimum. To change
    % dTE, change the readout (flat time = Nx_Eff*dwell, or the amplitude).
    deltaTE   = mr.calcDuration(gx);
    TE2_actual = TE_actual + deltaTE;


    % TR delay. The minimum TR is the sum of the played blocks; mr.calcDuration(a,b,...)
    % returns the longest event, which is the block duration.
    minTR = mr.calcDuration(rf, gz) ...                    % block 1: excitation
          + mr.calcDuration(gxPre, gz_beg) ...             % block 2: prephase + kz encode
          + delayTE ...                                    % TE padding, if any
          + ETL * mr.calcDuration(gx) ...                  % readouts
          + mr.calcDuration(gxSpoil, gzSpoil);             % spoiler + kz decode
    if unibipolar_flag == 0
        % unipolar plays a rephaser block between echoes
        minTR = minTR + (ETL - 1) * mr.calcDuration(gxRe);
    end

    % delayGR_TR is a zero-amplitude trapezoid, so it needs at least one raster each of
    % rise, flat and fall; a shorter one gets a negative flat time, which pge2.validate
    % flags. The -1e-9 keeps floating-point noise from rounding an exact multiple of the
    % raster up a whole step.
    minDelayTR = 3*seq.gradRasterTime;
    if isempty(TR)
        TR = minTR + minDelayTR;
    end
    delayTR = ceil((TR - minTR)/seq.gradRasterTime - 1e-9)*seq.gradRasterTime;
    if delayTR < minDelayTR
        warning(['StackOfStars: requested TR = %.0f us is shorter than the minimum ' ...
                 '%.0f us for these blocks. Running at the minimum. Shorten the ' ...
                 'readout, the RF, or the spoiler to reach the requested TR.'], ...
                 TR*1e6, (minTR + minDelayTR)*1e6);
        delayTR = minDelayTR;   % keep the same block structure in every TR
    end
    TR_actual = minTR + delayTR;

    %% TE/TR delay blocks
    if delayTE > 0
        delayGR_TE = mr.makeTrapezoid('x', 'Duration', delayTE, 'Amplitude', 0,'system',sys);
    end
    delayGR_TR = mr.makeTrapezoid('x', 'Duration', delayTR, 'Amplitude', 0,'system',sys);

    fprintf('  TE1               : %.0f us requested, %.0f us minimum, %.0f us actual\n', ...
        TE*1e6, minTE*1e6, TE_actual*1e6);
    fprintf('  TE2 / dTE         : %.0f us / %.0f us  (dTE = readout duration, already minimal)\n', ...
        TE2_actual*1e6, deltaTE*1e6);
    % Spoke angles: spokeAngle = delta*(i_spoke-1). The linear stride covers the same angles
    % as a single 2*pi sweep, reordered so consecutive spokes are nLoops*360/nSpokes
    % (3.57 deg) apart rather than 0.89 deg. Motion, flow and eddy-current effects then
    % decorrelate between neighbouring readouts, and the scan splits into nLoops passes.
    if angle_flag == 0
        delta = nLoops*2*pi/nSpokes;
    elseif angle_flag == 1
        % 2*pi-periodic golden angle. For a full echo (spokes are pi-periodic)
        % the conventional choice is pi/phi = 111.25 deg instead.
        delta = pi*(3-5^0.5);
    else
        error('angle_flag is not set to 0 or 1');
    end


    %% Build the sequence: spokes (outer loop) x kz partitions (inner loop)
    rf_phase=0;
    rf_inc=0;
    for i_spoke = 1:nSpokes
        for i_slice = 1:nPart
            rf.phaseOffset=rf_phase/180*pi;
            adc.phaseOffset=rf_phase/180*pi;
            rf_inc=mod(rf_inc+rfSpoilingInc, 360.0);
            rf_phase=mod(rf_phase+rf_inc, 360.0);

            spokeAngle = delta*(i_spoke-1);
            rot = mr.makeRotation([0,0,1],wrapToPi(spokeAngle));

            % Every TR has the same block timing, so all TRs share one segment (TRID 1).
            segmentID = i_slice + nPart*(i_spoke-1);
            segmentID = 1;
            seq.addBlock(rf,gz,mr.makeLabel('SET','TRID',segmentID));
            seq.addBlock(gxPre,gyPre,mr.scaleGrad(gz_beg,peSliceStep_beg(i_slice)),rot);
            if delayTE > 0
                seq.addBlock(delayGR_TE);
            end
            for i_echo = 1:ETL
                if unibipolar_flag == 0 %unipolar
                    seq.addBlock(gx,gy,adc,rot);
                    if i_echo ~= ETL % add rephaser unless last echo
                        seq.addBlock(gxRe,gyRe,rot);
                    end
                elseif unibipolar_flag == 1 %bipolar
                    mag_amplitude = abs(gx.amplitude);
                    if mod(i_echo,2) == 0 %even echo
                        gx.amplitude = -mag_amplitude;
                        seq.addBlock(gx,gy,adc,rot);
                    else % odd echo
                        gx.amplitude = mag_amplitude;
                        seq.addBlock(gx,gy,adc,rot);
                    end
                else
                    error('unibipolar_flag is not set to 0 or 1')
                end
            end
            seq.addBlock(gxSpoil,gySpoil,mr.scaleGrad(gzSpoil,peSliceStep_end(i_slice)),rot);
            seq.addBlock(delayGR_TR);
        end
    end

    %% Write the .seq
    % FOV z is the encoded (oversampled) extent, which is what the kz FFT returns;
    % crop to SlabThickness after reconstruction.
    seq.setDefinition('FOV', [fov fov fov_z_Eff]);
    seq.setDefinition('Name', 'StackOfStars');
    seq.setDefinition('SlabThickness', slabThickness);
    seq.setDefinition('SlabOversampling', no_slice_wrap);
    seq.setDefinition('PartitionsEncoded', Nz_Eff);
    seq.setDefinition('PartitionsPlayed', nPart);
    seq.setDefinition('Scanner', char(scanner));

    % Written next to this script, whatever the current folder is.
    seqOutFile = fullfile(here, ['STARS_v3' sfx '.seq']);
    seq.write(seqOutFile);
    fprintf('Wrote %s\n', seqOutFile);

    fprintf('\n--- %s: %.1f mT/m, %.1f T/m/s ---\n', scanner, gradMax, slewMax);
    fprintf('  TE1 / dTE         : %.0f / %.0f us\n', TE_actual*1e6, deltaTE*1e6);
    fprintf('  readout           : %.2f mT/m, ramps %.0f us\n', abs(gx.amplitude)/sys.gamma*1e3, gx.riseTime*1e6);
    fprintf('  scan time         : %.1f s (%d spokes x %d partitions)\n', sum(seq.blockDurations), nSpokes, nPart);
    fprintf('  excited slab      : %.1f mm  (TBW %g, %.2f ms)\n', slabThickness*1e3, rfTBW, rfDuration*1e3);
    fprintf('  encoded z FOV     : %.1f mm  (%d partitions, oversampling %.2f)\n', fov_z_Eff*1e3, Nz_Eff, no_slice_wrap);
    fprintf('  partitions played : %d  (after %.0f%% partial Fourier)\n', nPart, pfkz_ratio*100);
    fprintf('  slab-select grad  : %.2f mT/m\n', gz.amplitude/42.576e6*1e3);
    fprintf('  gz slew derate    : %.2f  -> gz_beg %.1f, gzSpoil %.1f T/m/s\n', gz_slew_derate, ...
        abs(gz_beg.amplitude)/gz_beg.riseTime/42.576e6, abs(gzSpoil.amplitude)/gzSpoil.riseTime/42.576e6);
    fprintf('  kz encode         : ref partition %d/%d (gz_beg), %d/%d (gzSpoil), max|scale| %.4f / %.4f\n', ...
        iRefBeg, nPart, iRefEnd, nPart, max(abs(peSliceStep_beg)), max(abs(peSliceStep_end)));
    fprintf('  z spoiling        : %.1f 1/m = %.2f cycles per %.1f mm partition\n', ...
        spoilz_area, spoilz_area*sliceThickness, sliceThickness*1e3);
    fprintf('  TR                : %.0f us requested, %.0f us minimum, %.0f us actual\n', ...
        TR*1e6, minTR*1e6, TR_actual*1e6);
    if angle_flag == 0
        fprintf('  spokes            : %d over %d loops, delta %.3f deg, %d distinct angles\n', ...
            nSpokes, nLoops, delta*180/pi, numel(unique(round(mod(delta*(0:nSpokes-1),2*pi)*1e9))));
    end

    %% Convert to .pge
    % pulseg.fromSeq -> pge2.check -> (pge2.validate) -> pge2.serialize; the .mat and .pge
    % are written next to the .seq.
    if WRITE_PGE
        pislquant = 1;                  % ADC events used to set Rx gain in Auto Prescan
        pgeName = ['STARS_v3' sfx];
        psq    = pulseg.fromSeq(seqOutFile);
        params = pge2.check(psq, sys_ge, 'PNSwt', PNSwt);
        % With zeroSlew, the .pge header maxSlew is 0 so the console's peak-slew check
        % passes (see geScannerOpts). It is saved in the .mat too, which translateFOVrf
        % re-serializes from; the real peak slew is kept as smaxActual.
        smaxActual = params.smax;            % G/cm/ms
        if zeroSlew, params.smax = 0; end

        % Saved before any FOV translation, with the variable named 'psq': pge2's
        % translateFOVrf loads it by that name.
        save(fullfile(here, pgeName), 'psq', 'params', 'pislquant', 'smaxActual');

        if DOVALIDATE
            seqCheck = mr.Sequence();
            seqCheck.read(seqOutFile);
            pge2.validate(psq, sys_ge, seqCheck, [], 'row', [], 'plot', false);
        end

        pgeFile = fullfile(here, [pgeName '.pge']);
        pge2.serialize(psq, pgeFile, 'pislquant', pislquant, ...
            'params', params, 'checkHash', true);
        fprintf('Wrote %s  (%s, PNSwt %s)\n', pgeFile, scanner, mat2str(PNSwt));
        fprintf('  nMax %d, %d segments, %d readouts, gmax %.3f G/cm, smax %.3f G/cm/ms (.pge header %.3f)\n', ...
            psq.nMax, psq.nSegments, psq.nReadouts, params.gmax, smaxActual, params.smax);
    end
end   % scanners
