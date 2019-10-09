%% Example LN models
clear; close all;

%% Set params

packagePath = '/Users/pmardoum/Dropbox/Scripts/cascade_pack';
addpath([packagePath '/util']);

p.dataFile = '/Users/pmardoum/Desktop/Store/LN_modeling_Adree/041317Ac3.mat';

p.samplingInterval = 1e-4;
p.frequencyCutoff  = 20;
p.prePts           = 3000;  
p.stimPts          = 50000;

% for filter
p.filterPts        = 12500;  % length of ONE SIDE of filter (causal or anti-causal side)
p.useAnticausal    = true;
p.correctStimPower = false;

% for nonlinearity
p.numBins          = 100;
p.binningType      = 'equalN';

% for polynomial fit of nonlinearity
p.polyFitDegree    = 3;

%% Load data
S = load(p.dataFile);
responseComplete = S.BlueDataExc;
stimComplete = S.BlueStimuliExc;

% Baseline correction, filtering, etc
%   - note these steps do not affect the the output of computeFilter, assuming
%     constant frequency cutoff
responseComplete = applyFrequencyCutoff(responseComplete, p.frequencyCutoff, p.samplingInterval);
responseComplete = baselineSubtract(responseComplete, p.prePts);

% Trim pre and tail points
response = responseComplete(:, p.prePts+1:p.prePts+p.stimPts);
stim = stimComplete(:, p.prePts+1:p.prePts+p.stimPts);

clear S responseComplete stimComplete

%% compute filter
[filterCausal, filterAnticausal] = computeFilter(stim, response, p.filterPts, ...
    p.correctStimPower, p.frequencyCutoff, p.samplingInterval);

if p.useAnticausal
    filter = [filterCausal filterAnticausal];
else
    filter = filterCausal;
end
filter = filter/max(abs(filter));
clear filterCausal filterAnticausal

%% Compute model prediction (without computation graph)
generatorSignal = convolveFilterWithStim(filter, stim, p.useAnticausal);

[nlX, nlY] = sampleNl(generatorSignal, response, p.numBins, p.binningType); 

[fitNL.coeff, ~, fitNL.mu] = polyfit(nlX, nlY, p.polyFitDegree);
prediction = computeLnPrediction(filter, stim, @polyval, fitNL, p.useAnticausal);

% Evaluate performance
rSquared = computeVarianceExplained(prediction, response);
rSquaredAll = computeVarianceExplained(reshape(prediction',1,[]), reshape(response',1,[]));
disp(['Overall R^2: ' num2str(rSquaredAll) '   Mean R^2: ' num2str(mean(rSquared))])

% Plot
figure; subplot(2,2,1); plot(filter);
xlabel('time'); ylabel('amp');

subplot(2,2,3); plot(nlX, nlY, 'bo');
hold on; plot(nlX, polyval(fitNL.coeff, nlX, [], fitNL.mu));
xlabel('generator signal'); ylabel('data');

subplot(2,2,2); plot(rSquared, 'bo');
hold on; plot(mean(rSquared) .* ones(1,length(rSquared)));
xlabel('epoch'); ylabel('r^2 value');

%% Compute model prediction (with computation graph)
% Use cascade_pack to compare LN models that use two different methods of
% fitting a nonlinearity

dataNodeInstance = DataNode(stim);
filterNodeInstance = FilterNode(filter, p.useAnticausal);
filterNodeInstance.upstream.add(dataNodeInstance);

% Try polynomial fit nonlinearity
polyfitNlNodeInstance = PolyfitNlNode();
polyfitNlNodeInstance.optimizeParams(nlX, nlY, p.polyFitDegree);
polyfitNlNodeInstance.upstream.add(filterNodeInstance);

predictionPolyfitNl = polyfitNlNodeInstance.processUpstream();

% Try sigmoidal nonlinearity
sigmoidNlNodeInstance = SigmoidNlNode();
sigmoidNlNodeInstance.optimizeParams(nlX, nlY);
sigmoidNlNodeInstance.upstream.add(filterNodeInstance);

predictionSigmoidNl = sigmoidNlNodeInstance.processUpstream();

% Evaluate performance
rSquaredPoly = computeVarianceExplained(predictionPolyfitNl, response);
rSquaredSig = computeVarianceExplained(predictionSigmoidNl, response);
rSquaredAllPoly = computeVarianceExplained(reshape(predictionPolyfitNl',1,[]), reshape(response',1,[]));
rSquaredAllSig  = computeVarianceExplained(reshape(predictionSigmoidNl',1,[]), reshape(response',1,[]));
disp(['PolyFit - Overall R^2: ' num2str(rSquaredAllPoly) '   Mean R^2: ' num2str(mean(rSquaredPoly))])
disp(['Sigmoid - Overall R^2: ' num2str(rSquaredAllSig) '   Mean R^2: ' num2str(mean(rSquaredSig))])

% Plot
figure; subplot(2,2,1); plot(filter);
xlabel('time'); ylabel('amp');

subplot(2,2,3); hold on;
plot(nlX, nlY, 'ko');
plot(nlX, polyfitNlNodeInstance.process(nlX));
plot(nlX, sigmoidNlNodeInstance.process(nlX));
xlabel('generator signal'); ylabel('data');

subplot(2,2,4); hold on;

subplot(2,2,2); hold on;
plot(rSquaredPoly, 'bo');
plot(rSquaredSig, 'ro');
plot(mean(rSquaredPoly) .* ones(1,length(rSquaredPoly)), 'b');
plot(mean(rSquaredSig) .* ones(1,length(rSquaredSig)), 'r');
xlabel('epoch'); ylabel('r^2 value');
legend('polyfit NL','sigmoid NL');

figure; hold on; 
plot(predictionPolyfitNl(1,:)); 
plot(predictionSigmoidNl(1,:));

%% Jointly fit parameterized filter and nonlinearity
clearvars -except stim response p

% Subsample to speed optimization
DECIMATE_INTERVAL = 10;

response = decimateMatrix(response, DECIMATE_INTERVAL);
stim = decimateMatrix(stim, DECIMATE_INTERVAL);
dt = p.samplingInterval * DECIMATE_INTERVAL;

stimNode = DataNode(stim);
model = LnHyperNode();
model.upstream.add(stimNode);
model.dt_stored = dt;

% Initialize LnHyperNode params
p0 = [8.5192
    2.0558
    0.0048
    1.1097
  615.3925
       770
     0.002
       0.6
      -600];

optimIters = 5;
for ii = 1:optimIters
    model.optimizeParams(p0, stim, response, dt);
    p0 = model.getFreeParams;
    
    % Compute prediction
    prediction = model.processUpstream();
    
    rSquaredAll = computeVarianceExplained(reshape(prediction',1,[]), reshape(response',1,[]));
    disp(['param LN iter ' num2str(ii) ' R^2: ' num2str(rSquaredAll)])
end

% Evaluate and visualize
t = ((1:p.filterPts/DECIMATE_INTERVAL) * dt)';
figure; 
plot(t, model.subnodes.filter.getFilter(p.filterPts/DECIMATE_INTERVAL, dt), 'linewidth', 2);

generatorSignal = model.subnodes.filter.process(stimNode.data, dt);
[nlX, nlY] = sampleNl(generatorSignal, response, p.numBins, p.binningType);

figure; hold on;
plot(nlX, model.subnodes.nonlinearity.process(nlX), 'linewidth', 2);
plot(nlX, nlY, '.');

%% local functions

function decimated = decimateMatrix(data, factor)
% decimate(vector, factor) for every vector in input matrix.  Return matrix with result. Decimate
% operates along whichever dimension is longer.
if size(data, 2) > size(data, 1)
    data = data';
    transpose = true;
else
    transpose = false;
end
numVecs = size(data,2);
tempCell = cell(0);
for ii = 1:numVecs
    tempCell{ii} = decimate(data(:,ii), factor);
end
decimated = horzcat(tempCell{:});
if transpose
    decimated = decimated';
end
end