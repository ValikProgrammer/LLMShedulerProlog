% =============================================================================
% knowledge_base.pl
% Static facts: university schedule, activities, priorities, weekly budgets,
% buddy availability, and weather requirements.
% =============================================================================

:- module(knowledge_base, [
    university_class/4,
    semi_fixed/4,
    sleep_block/2,
    activity/3,
    priority/2,
    weekly_budget/3,
    incompatible_same_day/2,
    recovery_time/2,
    requires_after/3,
    needs_good_weather/1,
    buddy_available/4,
    buddy_unavailable/2,
    prefers_time/2,
    daily_cognitive_limit/2,
    max_session_duration/1
]).

% =============================================================================
% UNIVERSITY FIXED BLOCKS
% university_class(Subject, Day, StartHour, EndHour)
% Days: monday, tuesday, wednesday, thursday, friday, saturday, sunday
% Times in decimal hours (e.g. 9.0, 10.5, 12.0)
% =============================================================================

university_class(math_analysis,       monday,    9.0,  10.5).
university_class(prog_paradigms,      monday,    12.0, 15.0).
university_class(algorithms,          tuesday,   12.0, 15.0).
university_class(kotlin,              wednesday, 9.0,  12.0).
university_class(linear_algebra,      wednesday, 12.0, 15.0).
university_class(jb_horizons,         wednesday, 18.25, 21.25).
university_class(discrete_math,       thursday,  9.0,  12.0).
university_class(discrete_upsolve,    thursday,  12.0, 12.5).
university_class(project_seminar,     thursday,  15.0, 18.0).
university_class(math_analysis,       friday,    9.0,  10.5).
university_class(math_analysis,       saturday,  10.5, 12.0).

% Semi-fixed: student-taught, high but not mandatory priority
semi_fixed(la_plus_plus, friday, 15.0, 17.0).

% =============================================================================
% SLEEP BLOCK (hard constraint, every day)
% sleep_block(StartHour, EndHour)
% =============================================================================

sleep_block(0.0, 8.333).  % 00:00 - 08:20

% =============================================================================
% FLEXIBLE ACTIVITIES
% activity(Id, Type, CognitiveLoad)
% Types: homework, self_study, physical, social, admin
% CognitiveLoad: high, medium, low, none
% =============================================================================

activity(ma_hw,           homework,   high).
activity(ma_theory,       self_study, high).
activity(la_hw,           homework,   high).
activity(dm_tasks,        homework,   high).
activity(dm_theory,       self_study, high).
activity(algo_hw,         homework,   medium).
activity(kotlin_hw,       homework,   medium).
activity(kotlin_lecture,  self_study, medium).
activity(prog_hw,         homework,   medium).
activity(te_jb_hw,        homework,   low).
activity(gym,             physical,   none).
activity(food_after_gym,  physical,   none).
activity(tennis,          physical,   none).
activity(hike,            physical,   none).
activity(the_hub,         social,     low).
activity(mafia,           social,     none).
activity(migration_office, admin,     none).

% =============================================================================
% PRIORITIES (1-10, higher = more important)
% If the scheduler cannot fit everything, lower-priority tasks are dropped first.
% =============================================================================

% Admin / critical
priority(migration_office,  10).

% Core math homework
priority(ma_hw,              8).
priority(la_hw,              8).

% University classes (all fixed, but priority used if semi-fixed conflicts arise)
priority(math_analysis,      8).
priority(linear_algebra,     8).
priority(algorithms,         8).
priority(kotlin,             8).
priority(prog_paradigms,     8).
priority(project_seminar,    8).
priority(jb_horizons,        8).
priority(discrete_math,      6).   % lower by user preference
priority(discrete_upsolve,   6).

% Semi-fixed
priority(la_plus_plus,       6).

% Self-study
priority(ma_theory,          7).
priority(dm_tasks,           6).
priority(kotlin_hw,          6).
priority(prog_hw,            6).
priority(dm_theory,          5).
priority(algo_hw,            5).
priority(te_jb_hw,           5).
priority(kotlin_lecture,     5).

% Physical
priority(gym,                5).
priority(food_after_gym,     5).
priority(tennis,             4).
priority(hike,               2).

% Social
priority(the_hub,            2).
priority(mafia,              1).

% =============================================================================
% WEEKLY TIME BUDGETS
% weekly_budget(Subject, SessionType, TotalMinutes)
% =============================================================================

weekly_budget(math_analysis,  theory,   60).    % 1h theory
weekly_budget(math_analysis,  homework, 240).   % 2 x 2h HW
weekly_budget(discrete_math,  tasks,    180).   % 3h tasks
weekly_budget(discrete_math,  theory,   180).   % 3h theory
weekly_budget(linear_algebra, homework, 240).   % 4h HW
weekly_budget(kotlin,         homework, 150).   % 2.5h HW
weekly_budget(kotlin,         lecture,  90).    % optional self-lecture
weekly_budget(prog_paradigms, homework, 90).    % 1.5h HW
weekly_budget(algorithms,     homework, 120).   % 2h HW
weekly_budget(te_jb,          homework, 90).    % 1.5h HW

% Physical weekly targets (sessions per week)
weekly_sessions(gym,    3).
weekly_sessions(tennis, 2).

% =============================================================================
% PHYSICAL INCOMPATIBILITIES (same day)
% incompatible_same_day(A, B) means A and B cannot both appear on the same day.
% Relation is symmetric.
% =============================================================================

incompatible_same_day(hike,   gym).
incompatible_same_day(gym,    hike).
incompatible_same_day(hike,   tennis).
incompatible_same_day(tennis, hike).
incompatible_same_day(gym,    tennis).
incompatible_same_day(tennis, gym).

% =============================================================================
% RECOVERY TIMES
% recovery_time(Activity, MinutesOfLightTasksOnly)
% After Activity, no high-cognitive tasks for this many minutes.
% =============================================================================

recovery_time(gym,  90).
recovery_time(hike, 180).

% =============================================================================
% POST-ACTIVITY REQUIREMENTS
% requires_after(Activity, RequiredActivity, MaxDelayMinutes)
% =============================================================================

requires_after(gym, food_after_gym, 120).  % eat within 2h after gym

% =============================================================================
% WEATHER-DEPENDENT ACTIVITIES
% needs_good_weather(Activity)
% =============================================================================

needs_good_weather(tennis).
needs_good_weather(hike).

% =============================================================================
% TENNIS BUDDY — DMITRI
% buddy_available(Buddy, Day, StartHour, EndHour)
% buddy_unavailable(Buddy, Day)
% =============================================================================

buddy_available(dmitri, monday,    16.0, 20.0).
buddy_available(dmitri, wednesday, 16.0, 20.0).
buddy_available(dmitri, friday,    16.0, 20.0).

buddy_unavailable(dmitri, thursday). 
buddy_unavailable(dmitri, sunday).   

% =============================================================================
% TIME PREFERENCES
% prefers_time(Activity, TimeOfDay)
% TimeOfDay: morning (8-12), afternoon (12-17), evening (17-23)
% Used as soft constraints — Prolog tries to satisfy, does not enforce.
% =============================================================================

prefers_time(gym,           morning).
prefers_time(tennis,        afternoon).
prefers_time(ma_hw,         morning).    % hard subjects when fresh
prefers_time(la_hw,         morning).
prefers_time(dm_tasks,      morning).
prefers_time(ma_theory,     morning).
prefers_time(te_jb_hw,      evening).    % light tasks in the evening
prefers_time(mafia,         evening).
prefers_time(the_hub,       evening).

% =============================================================================
% DAILY COGNITIVE LIMITS (soft constraints)
% daily_cognitive_limit(Category, MaxMinutes)
% =============================================================================

daily_cognitive_limit(math,        240).  % 4h of math per day
daily_cognitive_limit(programming, 300).  % 5h of coding per day

% =============================================================================
% SESSION DURATION
% max_session_duration(MaxMinutes)
% No minimum — tasks can be as short as needed (e.g. 40min upsolve).
% =============================================================================

max_session_duration(120).  % no single session longer than 2 hours
