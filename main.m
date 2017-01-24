function exit_stat = main(varargin)

exit_stat = 1; % assume that we exited badly if ever exit before this gets reassigned

if Screen('NominalFrameRate', max(Screen('Screens'))) ~= 60
    errordlg('Monitor refresh rate must be set to 60hz');
    return;
end

% use the inputParser class to deal with arguments
ip = inputParser;
%#ok<*NVREPL> dont warn about addParamValue
addParamValue(ip,'email', 'will@fake.com', @validate_email);
addParamValue(ip,'sessions_completed', 0, @(x) x <= 3);% # sessions must be kept in sync with constants.n_sessions
addParamValue(ip,'debugLevel',1, @isnumeric);
addParamValue(ip,'robotType', 'Good', @(x) sum(strcmp(x, {'Good','Bad','Chaotic'}))==1)
parse(ip,varargin{:}); 
input = ip.Results;
defaults = ip.UsingDefaults;

constants.exp_onset = GetSecs; % record the time the experiment began
KbName('UnifyKeyNames') % use a standard set of keyname/key positions
rng('shuffle'); % set up and seed the randon number generator, so lists get properly permuted

% Get full path to the directory the function lives in, and add it to the path
constants.root_dir = fileparts(mfilename('fullpath'));
path(path,constants.root_dir);
constants.lib_dir = fullfile(constants.root_dir, 'lib');
path(path, genpath(constants.lib_dir));

% Make the data directory if it doesn't exist (but it should!)
if ~exist(fullfile(constants.root_dir, 'data'), 'dir')
    mkdir(fullfile(constants.root_dir, 'data'));
end

% Define the location of some directories we might want to use
constants.stimDir=fullfile(constants.root_dir,'db');
constants.savePath=fullfile(constants.root_dir,'data');

%% Set up the experimental design %%
constants.list_length = 18;
constants.conditions = {'S', 'T', 'N'};
constants.n_sessions = 3;
constants.practiceCountdown = 3;
constants.finalTestCountdown = 5;
constants.finalTestBreakCountdown = 10;
constants.studyNewListCountdown = 5;
constants.gamebreakCountdown = 5;

assert(mod(constants.list_length, length(constants.conditions)) == 0, ...
       strcat('List length (', num2str(constants.list_length), ') is not a multiple of 3'));

%% Set the font size for dialog boxes
old_font_size = get(0, 'DefaultUIControlFontSize');
set(0, 'DefaultUIControlFontSize', 14);
old_image_visiblity = get(0,'DefaultImageVisible');
set(0,'DefaultImageVisible','off')

%% Debug Levels
% Level 0: normal experiment
if input.debugLevel >= 0
    constants.cueDur = 3; % Length of time to study each cue-target pair
    constants.testDur = 10;
    constants.readtime=10;
    constants.countdownSpeed = 1;
    constants.ISI = .5;
    inputHandler = makeInputHandlerFcn('KbQueue');
end

% Level 1: Fast Stim durations, readtimes & breaks
if input.debugLevel >= 1
    hertz = Screen('NominalFrameRate', max(Screen('Screens'))); % hertz = 1/ifi
    constants.cueDur = (30/hertz); % pairs on screen for the length of 30 flip intervals
    constants.testDur = 3;
    constants.readtime = constants.cueDur;
end

% Level 2: Fast countdowns & Game
if input.debugLevel >= 2
    constants.countdownSpeed = constants.cueDur;
end

% Level 4: Robot input
if input.debugLevel >= 4
    inputHandler = makeInputHandlerFcn([input.robotType,'Robot']);
    constants.Robot = java.awt.Robot;
end

% Level 4: Extreme debugging, useful for knowing if flips are timed ok.
if input.debugLevel >= 5
    constants.cueDur = (1/hertz); % pairs on screen for only 1 flip
    constants.countdownSpeed = constants.cueDur;
    constants.readtime = constants.cueDur;
    constants.ISI = constants.cueDur;
end

%% Connect to the database

setdbprefs('DataReturnFormat', 'dataset'); % Retrieved data should be a dataset object
setdbprefs('ErrorHandling', 'report'); % Throw runtime errors when a db error occurs

try
    % instance must be a predefined datasource at the OS level
    db_conn = database.ODBCConnection('fam_sarp', 'will', ''); % Connect to the db
catch db_error
    database_error(db_error)
end
% When cleanupObj is destroyed, it will execute the close(db_conn) statement
% This ensures we don't leave open db connections lying around somehow
cleanupObj = onCleanup(@() on_exit_function(db_conn,old_font_size,old_image_visiblity));

%% -------- GUI input option ----------------------------------------------------
% list of input parameters while may be exposed to the gui
% any input parameters not listed here will ONLY be able to be set via the
% command line
expose = {'email'};
valid_input = false;
while ~valid_input
    if any(ismember(defaults, expose))
    % call gui for input
        guiInput = getSubjectInfo('email', struct('title', 'E-Mail', ...
                                                   'type', 'textinput', ...
                                                   'validationFcn', @validate_email));
        if isempty(guiInput)
            exit(exit_stat);
        else   
            input = filterStructs(guiInput,input);
        end
    end

    session = get(fetch(exec(db_conn, ...
                             sprintf('select * from participants where email like ''%s''', ...
                                     input.email))), ...
                  'Data');

    if strcmp(session, 'No Data')
        valid_input = confirmation_dialog(input.email, 0);
        if valid_input
            new_subject = true;
            rng('shuffle');
            rng_state = rng;
            try
                insert(db_conn, 'participants', ...
                       {'email', 'sessions_completed', 'rng_seed'}, ...
                       {input.email, 0, double(rng_state.Seed)});
               % Retrieve the info the database assigns
                session = get(fetch(exec(db_conn, ...
                                         sprintf('select * from participants where email like ''%s''', ...
                                                 input.email))), ...
                              'Data');
            catch db_error
               database_error(db_error)
            end
        end

    else
        valid_input = confirmation_dialog(input.email, session.sessions_completed);
        new_subject = false;
    end
end



%% Add the fields from input and session to the constants struct
constants.subject = session.subject;
constants.email = session.email;
constants.sessions_completed = session.sessions_completed;
constants.current_session = session.sessions_completed + 1;
constants.debugLevel = input.debugLevel;
clear input session

%% Get or create the lists for the subject
if new_subject

    try
        stimuli = get(fetch(exec(db_conn, 'select * from stimuli')), 'Data');
    catch db_error
       database_error(db_error)
    end

    lists = create_lists(stimuli, constants);
    lists.subject = repmat(constants.subject, size(lists,1), 1);
    insert(db_conn, 'lists', ...
           lists.Properties.VarNames, ...
           lists);
else
    lists = get(fetch(exec(db_conn, ...
                           sprintf('select * from lists where subject = ''%d''', ...
                                   constants.subject))), ...
                'Data');
end

%% Construct the datasets that will govern stimulus presentation 
% and have responses stored in them
episodic_lists = lists(lists.session == constants.current_session, ...
                    {'list', 'id', 'episodic_cue', 'target'});
semantic_lists = lists(lists.session == constants.current_session, ...
                       {'list','id','semantic_cue_1', 'semantic_cue_2', ...
                        'semantic_cue_3', 'target', 'practice'});
semantic_lists = stack(semantic_lists, {'semantic_cue_1', 'semantic_cue_2', 'semantic_cue_3'}, ...
                       'newDataVarName','semantic_cue', 'IndVarName', 'cue_number');
semantic_lists.cue_number = cellfun(@(x) str2double(x(end)), cellstr(semantic_lists.cue_number));
semantic_lists = semantic_lists(:, {'list','id','cue_number','semantic_cue','target','practice'});

study_lists = [episodic_lists, dataset(nan(size(episodic_lists, 1), 1), 'VarNames', {'onset'})];

restudy_pairs = strcmp(semantic_lists.practice, 'S');
study_practice_lists = [semantic_lists(restudy_pairs,:), ... 
                        dataset(nan(sum(restudy_pairs), 1),'VarNames', {'onset'})];

test_pairs = strcmp(semantic_lists.practice, 'T');
test_practice_lists = [semantic_lists(test_pairs,:), response_schema(sum(test_pairs))];

final_test_lists = [episodic_lists,  response_schema(size(episodic_lists, 1))];

% Shuffle items within lists, so that pairs aren't given in the same order
% in all phases
for i = 1:unique(study_lists.list)

    [new_rows, old_rows] = shuffle_list(study_practice_lists.list, i);
    study_practice_lists(old_rows,:) = sortrows(study_practice_lists(new_rows,:), 'cue_number');

    [new_rows, old_rows] = shuffle_list(test_practice_lists.list, i);
    test_practice_lists(old_rows,:) = sortrows(test_practice_lists(new_rows,:), 'cue_number');

    [new_rows, old_rows] = shuffle_list(final_test_lists.list, i);
    final_test_lists(old_rows,:) = final_test_lists(new_rows,:);
end

[window, constants] = windowSetup(constants);

%% end of the experiment %%
windowCleanup(constants)
exit_stat=0;
end % end main()

function overwriteCheck = makeSubjectDataChecker(directory, extension, debugLevel) %#ok<DEFNU>
    % makeSubjectDataChecker function closer factory, used for the purpose
    % of enclosing the directory where data will be stored. This way, the
    % function handle it returns can be used as a validation function with getSubjectInfo to 
    % prevent accidentally overwritting any data. 
    function [valid, msg] = subjectDataChecker(value, ~)
        % the actual validation logic
        
        subnum = str2double(value);        
        if (~isnumeric(subnum) || isnan(subnum)) && ~isnumeric(value);
            valid = false;
            msg = 'Subject Number must be greater than 0';
            return
        end
        
        filePathGlobUpper = fullfile(directory, ['*Subject', value, '*', extension]);
        filePathGlobLower = fullfile(directory, ['*subject', value, '*', extension]);
        if ~isempty(dir(filePathGlobUpper)) || ~isempty(dir(filePathGlobLower)) && debugLevel <= 2
            valid= false;
            msg = strjoin({'Data file for Subject',  value, 'already exists!'}, ' ');                   
        else
            valid= true;
            msg = 'ok';
        end
    end

overwriteCheck = @subjectDataChecker;
end

function windowCleanup(constants)
    sca; % alias for screen('CloseAll')
    rmpath(constants.lib_dir,constants.root_dir);
end

function [window, constants] = windowSetup(constants)
    PsychDefaultSetup(2); % assert OpenGL install, unify keys, fix color range
    constants.screenNumber = max(Screen('Screens')); % Choose a monitor to display on
    constants.res=Screen('Resolution',constants.screenNumber); % get screen resolution
    constants.dims = [constants.res.width constants.res.height];
    if any(constants.debugLevel == [0 1])
    % Set the size of the PTB window based on screen size and debug level
        constants.screen_scale = [];
    else
        constants.screen_scale = reshape(round(constants.dims' * [(1/8),(7/8)]), 1, []);
    end

    try
        [window, constants.winRect] = Screen('OpenWindow', constants.screenNumber, ...
                                             (2/3)*WhiteIndex(constants.screenNumber), ...
                                             constants.screen_scale);
    % define some landmark locations to be used throughout
        [constants.xCenter, constants.yCenter] = RectCenter(constants.winRect);
        constants.center = [constants.xCenter, constants.yCenter];
        constants.left_half=[constants.winRect(1),constants.winRect(2),constants.winRect(3)/2,constants.winRect(4)];
        constants.right_half=[constants.winRect(3)/2,constants.winRect(2),constants.winRect(3),constants.winRect(4)];
        constants.top_half=[constants.winRect(1),constants.winRect(2),constants.winRect(3),constants.winRect(4)/2];
        constants.bottom_half=[constants.winRect(1),constants.winRect(4)/2,constants.winRect(3),constants.winRect(4)];

    % Get some the inter-frame interval, refresh rate, and the size of our window
        constants.ifi = Screen('GetFlipInterval', window);
        constants.hertz = FrameRate(window); % hertz = 1 / ifi
        constants.nominalHertz = Screen('NominalFrameRate', window);
        [constants.width, constants.height] = Screen('DisplaySize', constants.screenNumber); %in mm

    % Font Configuration
        Screen('TextFont',window, 'Arial');  % Set font to Arial
        Screen('TextSize',window, 28);       % Set font size to 28
        Screen('TextStyle', window, 1);      % 1 = bold font
        Screen('TextColor', window, [0 0 0]); % Black text
    catch
        psychrethrow(psychlasterror);
        windowCleanup(constants)
    end
end

function [valid_email, msg] = validate_email(email_address, ~)
    valid_email = ~isempty(regexpi(email_address, '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'));
    if ~valid_email
        msg = 'Invalid E-Mail Address';
    else
        msg = '';
    end

end

function [] = database_error(error)
   errordlg({'Unable to connect to database. Specific error was:', ...
            '', ...
            error.message}, ...
            'Database Connection Error', ...
            'modal')
   rethrow(error)
end

function on_exit_function(db_conn,old_font_size,old_image_visiblity)
    close(db_conn)
    set(0, 'DefaultUIControlFontSize', old_font_size);
    set(0,'DefaultImageVisible', old_image_visiblity)
end

function accept = confirmation_dialog(email, sessions_completed)

    session_msg = {'first','second', 'third'};
    resp = questdlg({['Your e-mail address is: ' email], ...
                     ['This is your ' session_msg{sessions_completed + 1} ' session.'], ...
                     '', ...
                     'Is this correct?'}, ...
                     'Confirm Subject Info', ...
                     'No', 'Yes', 'No');
    accept = strcmp(resp, 'Yes');
end

function ds = response_schema(n_rows)
   ds = [mat2dataset(nan(n_rows, 6), 'VarNames', {'onset', 'recalled', 'latency', 'FP', 'LP', 'advance'}), ...
         dataset(cellstr(repmat(char(0), n_rows, 1)), 'VarNames', {'response'})];
end

function [ new_row_ind, old_row_ind ] = shuffle_list(x, list)
    old_row_ind = find(x == list);
    new_row_ind = old_row_ind(randperm(numel(old_row_ind)));
end