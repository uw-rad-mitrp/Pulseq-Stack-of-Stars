%% Stack-of-Stars Sequence
clear; clc; close all;

% set system limits (WIMRMR1/2)
sys = mr.opts('maxGrad', 50, 'GradUnit', 'mT/m', ...
    'maxSlew', 150, 'SlewUnit', 'T/m/s','B0', 3.0, ...
    'rfRingdownTime', 60e-6, ...
    'rfDeadTime', 100e-6, ...
    'adcDeadTime', 0, ...
    'rfRasterTime', 2e-6, ...
    'adcRasterTime', 2e-6, ...
    'gradRasterTime', 4e-6, ...
    'blockDurationRaster', 1e-6); 
commonRasterTime = 20e-6;

seq=mr.Sequence(sys);           % Create a new sequence object
%% - Customizable Variables
fov=500e-3;                     % FOV
Nx=256;Ny=256;Nz=30;             % Resolution
alpha=12;                       % flip angle
sliceThickness=3e-3;            % slice thickness
TR=4e-3;                       % repetition time TR
TE=1.3e-3;                       % echo time TE  
rfSpoilingInc=117;              % RF spoiling increment
rfDuration=4e-3;      
radial_oversampling = pi/2;     % Typical oversampling for radial
ETL = 2;                        % Echo Train Length
unibipolar_flag = 1;            % 0 = unipolar, 1 = bipolar
angle_flag = 0;                 % 0 = linear, 1 = golden
nspoil = 6;
pfkz_flag = 1;                  % partial fourier flag
no_phase_wrap = 1.5;
no_slice_wrap = 0;              % 

% Extra Variables
nSpokes=floor(Nx*radial_oversampling); % Number of radial spokes
Nx_Eff = floor(Nx*no_phase_wrap);
fov_Eff = fov*Nx_Eff/Nx;
delta_k = 1/fov_Eff;
k_width = Nx_Eff * delta_k;
readoutTime = sys.adcRasterTime * Nx_Eff;
pfkz_ratio = 0.3;

%% - Define Gradients
% RF pulse
[rf, gz, gzReph] = mr.makeSincPulse(alpha*pi/180,'Duration',348e-6,...
    'SliceThickness',sliceThickness,'apodization',0.5,'timeBwProduct',1,'system',sys,'use','excitation');

% ReadoutGradient
gx = mr.makeTrapezoid('x', 'system',sys, 'flatArea', Nx_Eff*delta_k, 'flatTime', readoutTime);
ReadoutAmplitude = gx.amplitude;

% ADC
adc = mr.makeAdc(Nx_Eff, 'system', sys, 'Duration', gx.flatTime, 'Delay', gx.delay + gx.riseTime);

% Combine gzReph and gzPE
PEmax = 1/(Nz*sliceThickness*(1+no_slice_wrap)); %delta k in z
peSliceStep = PEmax * ((0:Nz-1) - floor(Nz/2));
if pfkz_flag == 1
    peSliceStep = peSliceStep(1+ceil(pfkz_ratio * Nz):end);
    Nz = length(peSliceStep);
end
gz_beg = mr.makeTrapezoid('z','Area',gzReph.area + peSliceStep(1),'system',sys);

peSliceStep_beg = (gzReph.area + peSliceStep)/(gzReph.area + peSliceStep(1));

% Slice Spoil z + decoding
spoilz_area = 2/sliceThickness - gz.area/2; 
gzSpoil=mr.makeTrapezoid('z','Area',spoilz_area - peSliceStep(1),'system',sys);

peSliceStep_end = (spoilz_area - peSliceStep) / (spoilz_area - peSliceStep(1));

% Calculate prewinder for readout
gxPre = mr.makeTrapezoid('x', 'system',sys, 'Area', -gx.area/2);
gxPre.delay = max(mr.calcDuration(gz_beg) - mr.calcDuration(gxPre),0);

% Calculate rephaser for readout
gxRe = mr.makeTrapezoid('x', 'system',sys, 'Area', -gx.area);

if unibipolar_flag == 0 %unipolar
    gxareas = gxPre.area + gx.area;
else
    gxareas = gxPre.area + gx.area * mod(ETL,2);
end

% Spoil x/y
spoilx_area = -1*Nx_Eff*delta_k - gxareas; %-gxareas-pi/(2.675*fov_Eff/Nx_Eff);
gxSpoil=mr.makeTrapezoid('x','Area',spoilx_area,'system',sys,'Duration',mr.calcDuration(gzSpoil));

% Delay TE
delayTE = ceil((TE - mr.calcDuration(rf) + mr.calcRfCenter(rf) + rf.delay - mr.calcDuration(gxPre)  ...
    - mr.calcDuration(gx)/2)/seq.gradRasterTime)*seq.gradRasterTime;
minTE = mr.calcDuration(rf) - mr.calcRfCenter(rf) - rf.delay + gxPre.delay + mr.calcDuration(gxPre) + mr.calcDuration(gx)/2

minTE2 = mr.calcDuration(rf) - mr.calcRfCenter(rf) - rf.delay + gxPre.delay + mr.calcDuration(gxPre) + 3*mr.calcDuration(gx)/2


% Delay TR
delayTR=ceil((TR - mr.calcDuration(gz) - mr.calcDuration(gzReph) - (mr.calcDuration(gx)*ETL - mr.calcDuration(gzSpoil)))/seq.gradRasterTime)*seq.gradRasterTime;
if unibipolar_flag == 0
    delayTR = delayTR + (ETL - 1) * mr.calcDuration(gxRe);
end

%% Delay TR/TE Gradient
%delayGR_TE = mr.makeTrapezoid('x', 'Duration', delayTE, 'Amplitude', 0,'system',sys);
delayGR_TR = mr.makeTrapezoid('x', 'Duration', delayTR, 'Amplitude', 0,'system',sys);

% Spoke Angles
if angle_flag == 0
    delta=2*pi/nSpokes;
elseif angle_flag == 1
    delta=pi*(3-5^0.5);
else
    error('angle_flag is not set to 0 or 1');
end


rf_phase=0;
rf_inc=0;
for i_spoke = 1:nSpokes
    for i_slice = 1:Nz
        rf.phaseOffset=rf_phase/180*pi;
        adc.phaseOffset=rf_phase/180*pi;
        rf_inc=mod(rf_inc+rfSpoilingInc, 360.0);
        rf_phase=mod(rf_phase+rf_inc, 360.0);

        spokeAngle=delta*(i_spoke);
        
        segmentID = 1;
        seq.addBlock(rf,gz,mr.makeLabel('SET','TRID',segmentID));
        seq.addBlock(mr.rotate('z',spokeAngle,gxPre,mr.scaleGrad(gz_beg,peSliceStep_beg(i_slice))));
        %seq.addBlock(delayGR_TE);
        for i_echo = 1:ETL
            if unibipolar_flag == 0 %unipolar
                seq.addBlock(mr.rotate('z',spokeAngle,gx,adc));
                if i_echo ~= ETL % add rephaser unless last echo
                    seq.addBlock(mr.rotate('z',spokeAngle,gxRe));
                end
            elseif unibipolar_flag == 1 %bipolar
                mag_amplitude = abs(gx.amplitude);
                if mod(i_echo,2) == 0 %even echo
                    gx.amplitude = -mag_amplitude;
                    seq.addBlock(mr.rotate('z',spokeAngle,gx,adc));
                else % odd echo
                    gx.amplitude = mag_amplitude;
                    seq.addBlock(mr.rotate('z',spokeAngle,gx,adc));
                end
            else
                error('unibipolar_flag is not set to 0 or 1')
            end
        end
        seq.addBlock(mr.rotate('z',spokeAngle,gxSpoil,mr.scaleGrad(gzSpoil,peSliceStep_end(i_slice))));
        seq.addBlock(delayGR_TR); %seq.addBlock(mr.makeDelay(delayTR));
    end
end

%% prepare sequence export
seq.setDefinition('FOV', [fov fov sliceThickness*Nz]);
seq.setDefinition('Name', 'StackOfStars');
seq.write('STARS.seq')       % Write to pulseq file

%% Visualise sequence and output for execution
Ndummy=50;
seq.plot('timeRange', [0 1]*TR);
%{
seq.plot('timeRange', [0 10]*TR);

% % k-space trajectory calculation
[ktraj_adc, t_adc, ktraj, t_ktraj, t_excitation, t_refocusing] = seq.calculateKspacePP();
% 
% % plot k-spaces
figure; plot(t_ktraj, ktraj'); % plot the entire k-space trajectory
hold; plot(t_adc,ktraj_adc(1,:),'.'); % and sampling points on the kx-axis
figure; plot(ktraj(1,:),ktraj(2,:),'b'); % a 2D plot
axis('equal'); % enforce aspect ratio for the correct trajectory display
hold;plot(ktraj_adc(1,:),ktraj_adc(2,:),'r.'); % plot the sampling points

%% very optional slow step, but useful for testing during development e.g. for the real TE, TR or for staying within slewrate limits  
%rep = seq.testReport;
%fprintf([rep{:}]);
%}