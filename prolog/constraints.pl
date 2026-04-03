% =============================================================================
% constraints.pl
% Constraint checking predicates:
%   - fixed block collision detection
%   - sleep block enforcement
%   - physical incompatibilities
%   - recovery time after gym / hike
%   - post-gym food requirement
%   - weather checks
%   - buddy availability for tennis
%   - daily cognitive load limits
%   - deadline boost calculation
% =============================================================================

:- module(constraints, [
    blocks_overlap/4,
    slot_in_sleep_block/1,
    slot_in_university_block/1,
    same_day_slots/2,
    check_incompatible/3,
    check_recovery/3,
    check_buddy_available/2,
    check_weather/2,
    cognitive_load_ok/3,
    slot_day/2,
    slot_hour/2
]).

:- use_module(knowledge_base).
:- use_module(utils).

% =============================================================================
% OVERLAP CHECK
% blocks_overlap(+Start1, +End1, +Start2, +End2)
% Succeeds if two time intervals (in absolute slots) overlap.
% =============================================================================

blocks_overlap(S1, E1, S2, E2) :-
    S1 < E2,
    S2 < E1.

% =============================================================================
% SLEEP BLOCK
% slot_in_sleep_block(+AbsoluteSlot)
% Succeeds if the slot falls within the daily 00:00-08:20 sleep window.
% =============================================================================

slot_in_sleep_block(Slot) :-
    sleep_block(SleepStart, SleepEnd),
    slot_to_day_hour(Slot, _, Hour),
    ( Hour >= SleepStart ; Hour < SleepEnd ),
    % handle midnight wrap: sleep is 0.0 -> 8.333
    ( Hour >= 0.0, Hour < SleepEnd
    ; Hour >= SleepStart  % covers 23.x+ but sleep is 0-8.3, so this catches nothing
    ),
    Hour < SleepEnd.

% Simpler version used by scheduler — checks the hour directly
slot_in_sleep_window(Hour) :-
    sleep_block(_, SleepEnd),
    Hour < SleepEnd.

% =============================================================================
% UNIVERSITY BLOCK COLLISION
% slot_in_university_block(+AbsoluteSlot)
% Succeeds if the slot is occupied by a fixed university class.
% =============================================================================

slot_in_university_block(Slot) :-
    university_class(_, Day, ClassStart, ClassEnd),
    day_hour_to_slot(Day, ClassStart, BlockStart),
    day_hour_to_slot(Day, ClassEnd,   BlockEnd),
    Slot >= BlockStart,
    Slot <  BlockEnd.

slot_in_university_block(Slot) :-
    semi_fixed(_, Day, ClassStart, ClassEnd),
    day_hour_to_slot(Day, ClassStart, BlockStart),
    day_hour_to_slot(Day, ClassEnd,   BlockEnd),
    Slot >= BlockStart,
    Slot <  BlockEnd.

% =============================================================================
% DAY / HOUR HELPERS (thin wrappers used throughout this module)
% =============================================================================

slot_day(Slot, Day)  :- slot_to_day_hour(Slot, Day, _).
slot_hour(Slot, Hour) :- slot_to_day_hour(Slot, _, Hour).

% same_day_slots(+Slot1, +Slot2) — both slots fall on the same calendar day
same_day_slots(S1, S2) :-
    slot_day(S1, Day),
    slot_day(S2, Day).

% =============================================================================
% PHYSICAL INCOMPATIBILITY CHECK
% check_incompatible(+Activity1, +StartSlot1, +ScheduledEvents)
% Fails if Activity1 is incompatible with any already-scheduled activity
% that occurs on the same day.
% ScheduledEvents = list of event(Activity, StartSlot, EndSlot)
% =============================================================================

check_incompatible(_, _, []).
check_incompatible(Activity, Slot, [event(Other, OtherSlot, _) | Rest]) :-
    (   incompatible_same_day(Activity, Other),
        same_day_slots(Slot, OtherSlot)
    ->  fail
    ;   check_incompatible(Activity, Slot, Rest)
    ).

% =============================================================================
% RECOVERY TIME CHECK
% check_recovery(+Activity, +StartSlot, +ScheduledEvents)
% Fails if Activity requires high cognitive load but is scheduled too soon
% after a gym or hike session.
% =============================================================================

check_recovery(Activity, Slot, ScheduledEvents) :-
    activity(Activity, _, CogLoad),
    ( CogLoad = high ; CogLoad = medium ),
    !,
    \+ recovery_violation(Slot, ScheduledEvents).
check_recovery(_, _, _).  % non-cognitive activities always pass

recovery_violation(Slot, [event(PhysActivity, _, PhysEnd) | _]) :-
    recovery_time(PhysActivity, RecoveryMins),
    minutes_to_slots(RecoveryMins, RecSlots),
    Slot >= PhysEnd,
    Slot < PhysEnd + RecSlots.
recovery_violation(Slot, [_ | Rest]) :-
    recovery_violation(Slot, Rest).

% =============================================================================
% BUDDY AVAILABILITY CHECK
% check_buddy_available(+Activity, +StartSlot)
% For tennis: verifies Dmitri is available at the given slot.
% =============================================================================

check_buddy_available(tennis, Slot) :-
    !,
    slot_to_day_hour(Slot, Day, Hour),
    buddy_available(dmitri, Day, BuddyStart, BuddyEnd),
    Hour >= BuddyStart,
    Hour < BuddyEnd.
check_buddy_available(_, _).  % non-tennis activities always pass

% =============================================================================
% WEATHER CHECK
% check_weather(+Activity, +Day)
% Fails if the activity needs good weather but the forecast is bad.
% Weather facts are asserted dynamically by the Python backend:
%   weather_forecast(Day, Condition)   Condition: good | bad
% =============================================================================

:- dynamic weather_forecast/2.

check_weather(Activity, Day) :-
    needs_good_weather(Activity),
    !,
    ( weather_forecast(Day, good)
    ->  true
    ;   weather_forecast(Day, _)
    ->  fail               % forecast exists but is bad
    ;   true               % no forecast available — optimistically allow
    ).
check_weather(_, _).       % non-weather-sensitive activities always pass

% =============================================================================
% COGNITIVE LOAD CHECK
% cognitive_load_ok(+Activity, +Day, +DayLoad)
% DayLoad = load(MathMinutes, ProgrammingMinutes) accumulated on that day.
% Returns soft violation (true but emits warning) rather than hard failure.
% =============================================================================

math_subject(math_analysis).
math_subject(linear_algebra).
math_subject(discrete_math).
math_subject(ma_hw).
math_subject(la_hw).
math_subject(dm_tasks).
math_subject(dm_theory).
math_subject(ma_theory).

programming_subject(kotlin).
programming_subject(prog_paradigms).
programming_subject(algorithms).
programming_subject(kotlin_hw).
programming_subject(prog_hw).
programming_subject(algo_hw).
programming_subject(kotlin_lecture).

cognitive_load_ok(Activity, _Day, load(MathMin, _ProgMin)) :-
    math_subject(Activity),
    !,
    daily_cognitive_limit(math, Limit),
    MathMin =< Limit.
cognitive_load_ok(Activity, _Day, load(_MathMin, ProgMin)) :-
    programming_subject(Activity),
    !,
    daily_cognitive_limit(programming, Limit),
    ProgMin =< Limit.
cognitive_load_ok(_, _, _).  % non-cognitive activities always pass
