% =============================================================================
% scheduler.pl
% Core scheduling engine — greedy slot placement with priority ordering.
%
% Main entry points (called from Python via pyswip):
%   generate_schedule(+WeeklyRequest, -Schedule, -Warnings)
%   all_schedules(+WeeklyRequest, -AllSchedules, -Warnings)
%   schedule_stats(+Schedule, -Stats)
%
% WeeklyRequest = list of terms produced by the Python LLM parser:
%   add_task(Id, Activity, DurationMinutes)
%   add_deadline(Activity, DaysUntil)
%   add_oneoff(Id, Label, Day, StartHour, DurationMinutes, Priority)
%   set_weather(Day, good|bad)
%   skip_activity(Activity)
%
% Schedule = list of event(Subject, Day, StartHour, EndHour, Color, Type)
%   Type = fixed | semi_fixed | flexible
% =============================================================================

:- module(scheduler, [
    generate_schedule/3,
    all_schedules/3,
    schedule_stats/2
]).

:- use_module(knowledge_base).
:- use_module(constraints).
:- use_module(utils).

% =============================================================================
% COLOR MAP
% =============================================================================

% Google Calendar color palette
% Sage (#33B679)      — university lectures/labs
% Flamingo (#E67C73)  — programming homework
% Tangerine (#F4511E) — TE / startups
% Banana (#F6BF26)    — sports (gym, tennis, hike)
% Basil (#0B8043)     — additional DM/LA classes
% Grape (#8E24AA)     — self-study math homework
% Graphite (#616161)  — food / misc time
% Peacock (#039BE5)   — default / admin
% Blueberry (#3F51B5) — HUB, social, tutor

% Sage — university lectures
subject_color(math_analysis,    '#33B679').
subject_color(linear_algebra,   '#33B679').
subject_color(discrete_math,    '#33B679').
subject_color(algorithms,       '#33B679').
subject_color(kotlin,           '#33B679').
subject_color(prog_paradigms,   '#33B679').
subject_color(project_seminar,  '#33B679').

% Tangerine — TE / startups (JB Horizons = TE)
subject_color(jb_horizons,      '#F4511E').
subject_color(te_jb_hw,         '#F4511E').

% Flamingo — programming homework
subject_color(prog_hw,          '#E67C73').
subject_color(algo_hw,          '#E67C73').
subject_color(kotlin_hw,        '#E67C73').
subject_color(kotlin_lecture,   '#E67C73').

% Banana — sports
subject_color(gym,              '#F6BF26').
subject_color(tennis,           '#F6BF26').
subject_color(hike,             '#F6BF26').

% Basil — additional DM / LA classes
subject_color(discrete_upsolve, '#0B8043').
subject_color(la_plus_plus,     '#0B8043').

% Grape — self-study / homework math
subject_color(ma_hw,            '#8E24AA').
subject_color(la_hw,            '#8E24AA').
subject_color(dm_tasks,         '#8E24AA').
subject_color(dm_theory,        '#8E24AA').
subject_color(ma_theory,        '#8E24AA').

% Graphite — food
subject_color(food_after_gym,   '#616161').

% Blueberry — HUB, social, tutor
subject_color(the_hub,          '#3F51B5').
subject_color(mafia,            '#3F51B5').

% Peacock — default / admin
subject_color(migration_office, '#039BE5').

% Deterministic color lookup — avoids catch-all doubling events in findall.
get_color(Subject, Color) :-
    ( subject_color(Subject, Color) -> true ; Color = '#039BE5' ).

% =============================================================================
% GENERATE SCHEDULE
% No dynamic facts — weather is passed as a list Day-Condition pairs.
% This keeps generate_schedule a pure predicate with no side effects,
% which avoids pyswip NestedQueryError from retractall/assertz inside queries.
% =============================================================================

generate_schedule(WeeklyRequest, Schedule, Warnings) :-
    findall(Day-Hour-Cond,
            member(set_weather(Day, Hour, Cond), WeeklyRequest),
            HourlyWeather),
    findall(Day-Cond,
            member(set_weather(Day, Cond), WeeklyRequest),
            DayWeather),
    append(HourlyWeather, DayWeather, WeatherList),
    collect_flexible_tasks(WeeklyRequest, Tasks),
    sort_tasks_by_priority(Tasks, Sorted),
    fixed_events(FixedEvents),
    place_tasks(Sorted, FixedEvents, [], WeatherList, PlacedEvents, Dropped),
    append(FixedEvents, PlacedEvents, Schedule),
    dropped_warnings(Dropped, Warnings).

% =============================================================================
% ALL SCHEDULES  (Next/Prev browsing)
% =============================================================================

all_schedules(WeeklyRequest, AllSchedules, Warnings) :-
    findall(Day-Hour-Cond,
            member(set_weather(Day, Hour, Cond), WeeklyRequest),
            HourlyWeather),
    findall(Day-Cond,
            member(set_weather(Day, Cond), WeeklyRequest),
            DayWeather),
    append(HourlyWeather, DayWeather, WeatherList),
    collect_flexible_tasks(WeeklyRequest, Tasks),
    sort_tasks_by_priority(Tasks, Sorted),
    fixed_events(FixedEvents),
    events_to_ranges(FixedEvents, FixedRanges),
    findall(Sched,
        ( member(BiasDay, [0,1,2,3,4,5,6]),
          place_tasks_offset(Sorted, FixedRanges, FixedEvents, [], [], WeatherList,
                             PlacedEvents, _, BiasDay),
          append(FixedEvents, PlacedEvents, Sched)
        ),
        AllRaw),
    sort(AllRaw, AllSchedules),
    ( AllSchedules = []
    ->  Warnings = ['No valid schedule found.']
    ;   Warnings = []
    ).

% =============================================================================
% FIXED EVENTS (university blocks — never moved)
% =============================================================================

fixed_events(Events) :-
    findall(event(Subj, Day, Start, End, Color, fixed),
        ( university_class(Subj, Day, Start, End),
          get_color(Subj, Color) ),
        UniEvents),
    findall(event(Subj, Day, Start, End, Color, semi_fixed),
        ( semi_fixed(Subj, Day, Start, End),
          get_color(Subj, Color) ),
        SemiEvents),
    append(UniEvents, SemiEvents, Events).

% =============================================================================
% FLEXIBLE TASK COLLECTION
% Builds list of task(Id, Activity, DurationMinutes, Priority, DayConstraint, HourConstraint)
%   DayConstraint: any | monday | tuesday | ...
%   HourConstraint: any | flexible | float (decimal hour like 10.5)
% from weekly budget facts + weekly request additions.
% =============================================================================

collect_flexible_tasks(WeeklyRequest, Tasks) :-
    % Collect deadlines from request
    findall(deadline(Act, D),
            member(add_deadline(Act, D), WeeklyRequest),
            Deadlines),
    % Collect skip instructions — auto-skip food_after_gym when gym is skipped
    findall(Act, member(skip_activity(Act), WeeklyRequest), SkippedRaw),
    ( member(gym, SkippedRaw)
    ->  union(SkippedRaw, [food_after_gym], Skipped)
    ;   Skipped = SkippedRaw
    ),
    % Collect pin_to_day instructions (force one session to a specific day)
    findall(Act-Day, member(pin_to_day(Act, Day), WeeklyRequest), Pins),
    % Collect avoid_day instructions (prevent scheduling on a specific day)
    findall(Act-Day, member(avoid_day(Act, Day), WeeklyRequest), Avoids),
    % Collect priority overrides
    findall(Act-P, member(set_priority(Act, P), WeeklyRequest), PrioOverrides),

    % Base recurring tasks — apply pins and avoids
    findall(task(Id, Act, Mins, EP, DayC, any),
        ( base_flexible_task(Id, Act, Mins),
          \+ member(Act, Skipped),
          effective_priority_with_override(Act, Deadlines, PrioOverrides, EP),
          resolve_day_constraint(Id, Act, Pins, Avoids, DayC)
        ),
        BaseTasks),

    % One-off tasks from LLM request (with day/hour constraints)
    findall(task(Id, Act, Mins, P, Day, StartH),
        ( member(add_oneoff(Id, Act, Day, StartH, Mins, P), WeeklyRequest) ),
        OneoffTasks),

    append(BaseTasks, OneoffTasks, Tasks).

% Resolve day constraint for a base task:
%   - If activity has a pin_to_day, ALL sessions get pinned to that day
%   - If activity has an avoid_day, block that day
resolve_day_constraint(_Id, Act, Pins, Avoids, DayC) :-
    ( member(Act-PinDay, Pins)
    ->  DayC = PinDay
    ; member(Act-AvoidDay, Avoids)
    ->  DayC = avoid(AvoidDay)
    ;   DayC = any
    ).

% Priority with optional override from set_priority
effective_priority_with_override(Act, Deadlines, PrioOverrides, EP) :-
    ( member(Act-OverrideP, PrioOverrides)
    ->  EP = OverrideP
    ;   effective_priority(Act, Deadlines, EP)
    ).

% base_flexible_task(+Id, +Activity, +DurationMinutes)
% Each entry is one session that needs to be placed.
% Tasks with >2h weekly budget are split into separate sessions here.

base_flexible_task(ma_hw_1,      ma_hw,          120).
base_flexible_task(ma_hw_2,      ma_hw,          120).
base_flexible_task(ma_theory_1,  ma_theory,       60).
base_flexible_task(la_hw_1,      la_hw,          120).
base_flexible_task(la_hw_2,      la_hw,          120).
base_flexible_task(dm_tasks_1,   dm_tasks,       120).
base_flexible_task(dm_tasks_2,   dm_tasks,        60).
base_flexible_task(dm_theory_1,  dm_theory,      120).
base_flexible_task(dm_theory_2,  dm_theory,       60).
base_flexible_task(algo_hw_1,    algo_hw,        120).
base_flexible_task(kotlin_hw_1,  kotlin_hw,       90).
base_flexible_task(kotlin_hw_2,  kotlin_hw,       60).
base_flexible_task(kotlin_lec_1, kotlin_lecture,  90).
base_flexible_task(prog_hw_1,    prog_hw,         90).
base_flexible_task(te_jb_hw_1,   te_jb_hw,        90).
base_flexible_task(gym_1,        gym,             60).
base_flexible_task(gym_2,        gym,             60).
base_flexible_task(gym_3,        gym,             60).
base_flexible_task(food_1,       food_after_gym,  30).
base_flexible_task(food_2,       food_after_gym,  30).
base_flexible_task(food_3,       food_after_gym,  30).
base_flexible_task(tennis_1,     tennis,          90).
base_flexible_task(tennis_2,     tennis,          90).

% =============================================================================
% PRIORITY + DEADLINE BOOST
% =============================================================================

effective_priority(Activity, Deadlines, EP) :-
    ( priority(Activity, Base) -> true ; Base = 3 ),
    ( member(deadline(Activity, Days), Deadlines), Days =< 2
    ->  EP is min(Base + 3, 9)
    ;   EP = Base
    ).

% =============================================================================
% SORT BY PRIORITY (descending — highest priority first)
% =============================================================================

sort_tasks_by_priority(Tasks, Sorted) :-
    map_list_to_pairs(task_priority_key, Tasks, Pairs),
    keysort(Pairs, Ascending),
    pairs_values(Ascending, Sorted).  % already descending: high priority (low key) first

task_priority_key(task(_, Activity, _, P, _, _), Key) :-
    time_window_bonus(Activity, Bonus),
    Key is (100 - P) * 10 - Bonus.
    % Primary: priority (higher P → lower key → scheduled first).
    % Secondary: time-constrained tasks get a bonus (lower key → earlier).
    % E.g. gym (P5, bonus 3) → key 947 < algo_hw (P5, bonus 0) → key 950.

% Bonus for activities with narrow scheduling windows.
% Higher bonus = scheduled earlier among same-priority tasks.
% Gym/tennis have very narrow windows (9-18, 16-20) and must be placed before
% homework that could fill those gaps. food_after_gym must be placed AFTER gym
% (enforced by food_gym_ok), so it gets a smaller bonus.
time_window_bonus(gym,           35).  % 9:00-18:00 only, non-consecutive days — must beat P8 homework
time_window_bonus(tennis,        42).  % 16:00-20:00, buddy + weather
time_window_bonus(hike,          20).  % weather-dependent weekends
time_window_bonus(food_after_gym,30).  % must follow gym — scheduled right after gym
time_window_bonus(_,              0).

% =============================================================================
% PLACE TASKS
% Precomputes fixed slot ranges ONCE, then passes them through.
% This avoids recomputing day_hour_to_slot for every slot attempt.
% =============================================================================

place_tasks(Tasks, FixedEvents, Already, WeatherList, Placed, Dropped) :-
    events_to_ranges(FixedEvents, FixedRanges),
    place_tasks_offset(Tasks, FixedRanges, FixedEvents, Already, [], WeatherList,
                       Placed, Dropped, 0).

place_tasks_offset([], _, _, Already, _, _, Already, [], _).
place_tasks_offset([Task | Rest], FixedRanges, FixedEvents, Already, AlreadyRanges,
                   WeatherList, AllPlaced, Dropped, Offset) :-
    Task = task(_Id, Activity, DurMins, _P, DayConstraint, HourConstraint),
    DurSlots is ceiling(DurMins / 30),
    user_pinned(DayConstraint, Pinned),
    ( find_slot(Activity, DurSlots, FixedRanges, AlreadyRanges, Already,
                WeatherList, Offset, DayConstraint, HourConstraint, Pinned, StartSlot)
    ->  slot_to_day_hour(StartSlot, Day, StartH),
        EndSlot is StartSlot + DurSlots,
        slot_to_day_hour(EndSlot, Day, EndH),
        get_color(Activity, Color),
        Ev = event(Activity, Day, StartH, EndH, Color, flexible),
        NewRanges = [range(StartSlot, EndSlot) | AlreadyRanges],
        place_tasks_offset(Rest, FixedRanges, FixedEvents, [Ev | Already], NewRanges,
                           WeatherList, AllPlaced, Dropped, Offset)
    ;   place_tasks_offset(Rest, FixedRanges, FixedEvents, Already, AlreadyRanges,
                           WeatherList, AllPlaced, RestDropped, Offset),
        Dropped = [Activity | RestDropped]
    ).

% events_to_ranges(+Events, -Ranges)
% Precompute slot ranges from event terms (called once per scheduling run).
events_to_ranges(Events, Ranges) :-
    findall(range(S, E),
        ( member(event(_, Day, StartH, EndH, _, _), Events),
          day_hour_to_slot(Day, StartH, S),
          day_hour_to_end_slot(Day, EndH, E)
        ),
        Ranges).

% =============================================================================
% SLOT FINDER
% Morning-preferred activities try morning slots first, then fall back.
% =============================================================================

% user_pinned(+DayConstraint, -Pinned)
% Pinned = true if user explicitly placed this task on a specific day.
% When pinned, buddy/tennis-window constraints are relaxed.
user_pinned(any, false) :- !.
user_pinned(avoid(_), false) :- !.
user_pinned(_, true).

% find_slot with day/hour constraints.
% DayConstraint = any | avoid(Day) | specific_day_atom
% HourConstraint = any | flexible | float
% Pinned = true | false — relaxes buddy/window checks for user-requested placements.

find_slot(Activity, DurSlots, FixedRanges, PlacedRanges, PlacedEvents,
          WeatherList, BiasDay, DayConstraint, HourConstraint, Pinned, StartSlot) :-
    total_slots(Total),
    ( DayConstraint = avoid(_)
    ->  find_best_slot(Activity, DurSlots, FixedRanges, PlacedRanges, PlacedEvents,
                       WeatherList, BiasDay, Total, DayConstraint, Pinned, StartSlot)
    ; DayConstraint \= any, number(HourConstraint)
    ->  day_hour_to_slot(DayConstraint, HourConstraint, PinnedSlot),
        EndSlot is PinnedSlot + DurSlots,
        ( slot_valid(Activity, PinnedSlot, EndSlot, FixedRanges, PlacedRanges,
                     PlacedEvents, WeatherList, Pinned)
        ->  StartSlot = PinnedSlot
        ;   find_best_slot(Activity, DurSlots, FixedRanges, PlacedRanges, PlacedEvents,
                           WeatherList, BiasDay, Total, DayConstraint, Pinned, StartSlot)
        )
    ; DayConstraint \= any
    ->  find_best_slot(Activity, DurSlots, FixedRanges, PlacedRanges, PlacedEvents,
                       WeatherList, BiasDay, Total, DayConstraint, Pinned, StartSlot)
    ;   find_best_slot(Activity, DurSlots, FixedRanges, PlacedRanges, PlacedEvents,
                       WeatherList, BiasDay, Total, any, Pinned, StartSlot)
    ).

% find_best_slot: morning preference → try morning window first, then any.
find_best_slot(Activity, DurSlots, FixedRanges, PlacedRanges, PlacedEvents,
               WeatherList, BiasDay, Total, DayFilter, Pinned, StartSlot) :-
    prefers_time(Activity, morning),
    !,
    ( find_slot_in_window(Activity, DurSlots, FixedRanges, PlacedRanges,
                          PlacedEvents, WeatherList, BiasDay, Total,
                          8.333, 13.0, DayFilter, Pinned, StartSlot)
    ->  true
    ;   find_slot_any(Activity, DurSlots, FixedRanges, PlacedRanges,
                      PlacedEvents, WeatherList, BiasDay, Total, DayFilter, Pinned, StartSlot)
    ).
find_best_slot(Activity, DurSlots, FixedRanges, PlacedRanges, PlacedEvents,
               WeatherList, BiasDay, Total, DayFilter, Pinned, StartSlot) :-
    find_slot_any(Activity, DurSlots, FixedRanges, PlacedRanges,
                  PlacedEvents, WeatherList, BiasDay, Total, DayFilter, Pinned, StartSlot).

% Find a slot within a time-of-day window, least-loaded days first.
find_slot_in_window(Activity, DurSlots, FixedRanges, PlacedRanges, PlacedEvents,
                    WeatherList, BiasDay, _Total, MinH, MaxH, DayFilter, Pinned, StartSlot) :-
    candidate_days(PlacedEvents, BiasDay, DayFilter, CandidateDays),
    member(Day, CandidateDays),
    day_index(Day, DayIdx),
    slots_per_day(SPD),
    DayStart is (DayIdx - 1) * SPD + 1,
    DayEnd is DayIdx * SPD,
    between(DayStart, DayEnd, StartSlot),
    EndSlot is StartSlot + DurSlots,
    EndSlot =< DayEnd + 1,
    slot_to_day_hour(StartSlot, _, H),
    H >= MinH, H < MaxH,
    slot_valid(Activity, StartSlot, EndSlot, FixedRanges, PlacedRanges,
               PlacedEvents, WeatherList, Pinned),
    !.

% Find any valid slot, least-loaded days first.
find_slot_any(Activity, DurSlots, FixedRanges, PlacedRanges, PlacedEvents,
              WeatherList, BiasDay, _Total, DayFilter, Pinned, StartSlot) :-
    candidate_days(PlacedEvents, BiasDay, DayFilter, CandidateDays),
    member(Day, CandidateDays),
    day_index(Day, DayIdx),
    slots_per_day(SPD),
    DayStart is (DayIdx - 1) * SPD + 1,
    DayEnd is DayIdx * SPD,
    between(DayStart, DayEnd, StartSlot),
    EndSlot is StartSlot + DurSlots,
    EndSlot =< DayEnd + 1,
    slot_valid(Activity, StartSlot, EndSlot, FixedRanges, PlacedRanges,
               PlacedEvents, WeatherList, Pinned),
    !.

% candidate_days: dispatch based on DayFilter type.
%   avoid(Day) → all days except the avoided one, sorted by load.
%   specific day atom → just that day.
%   any → all days sorted by load.
candidate_days(PlacedEvents, BiasDay, avoid(AvoidDay), FilteredDays) :-
    !,
    biased_least_loaded_days(PlacedEvents, BiasDay, SortedDays),
    exclude(=(AvoidDay), SortedDays, FilteredDays).
candidate_days(_, _, DayFilter, [DayFilter]) :-
    DayFilter \= any, !.
candidate_days(PlacedEvents, BiasDay, any, SortedDays) :-
    biased_least_loaded_days(PlacedEvents, BiasDay, SortedDays).

% Sort days by load count + bias. BiasDay (0-6) rotates tie-breaking order
% so that equal-load days are tried in different sequences → different schedules.
biased_least_loaded_days(PlacedEvents, BiasDay, SortedDays) :-
    days_of_week(Days),
    findall(Key-Day,
        ( member(Day, Days),
          findall(_, member(event(_, Day, _, _, _, _), PlacedEvents), Es),
          length(Es, Count),
          day_index(Day, DayIdx),
          % Rotate tie-breaking: days starting from BiasDay+1 get lower secondary key
          RotatedIdx is (DayIdx + BiasDay) mod 7,
          Key is Count * 10 + RotatedIdx ),
        Pairs),
    keysort(Pairs, Sorted),
    pairs_values(Sorted, SortedDays).

% slot_valid/7 — backward-compatible wrapper (Pinned = false).
slot_valid(Activity, StartSlot, EndSlot, FixedRanges, PlacedRanges,
           PlacedEvents, WeatherList) :-
    slot_valid(Activity, StartSlot, EndSlot, FixedRanges, PlacedRanges,
               PlacedEvents, WeatherList, false).

% slot_valid/8 — all constraints checked.
% Pinned = true relaxes buddy availability and tennis time-window constraints
% (user explicitly requested this day, so they know what they're doing).
slot_valid(Activity, StartSlot, EndSlot, FixedRanges, PlacedRanges,
           PlacedEvents, WeatherList, Pinned) :-
    slot_to_day_hour(StartSlot, Day, StartH),
    slot_to_day_hour(EndSlot,   Day, EndH),     % must be same day (no midnight overflow)
    sleep_block(_, SleepEnd),

    StartH >= SleepEnd,
    EndH   =< 22.0,                             % nothing past 22:00

    day_allowed(Activity, Day),

    \+ ranges_overlap(StartSlot, EndSlot, FixedRanges),
    \+ ranges_overlap(StartSlot, EndSlot, PlacedRanges),
    \+ physical_conflict(Activity, Day, PlacedEvents),

    \+ already_on_day(Activity, Day, PlacedEvents),
    \+ gym_consecutive(Activity, Day, PlacedEvents),
    gym_hours_ok(Activity, StartH, EndH),

    % Daily limits, buddy, tennis-window relaxed when user explicitly pinned to this day
    ( Pinned == true -> true ; daily_limits_ok(Activity, Day, PlacedEvents) ),
    ( Pinned == true -> true ; buddy_ok(Activity, Day, StartH) ),
    weather_ok(Activity, Day, StartH, WeatherList),
    ( Pinned == true -> true ; tennis_window_ok(Activity, StartH, EndH) ),
    food_gym_ok(Activity, Day, StartH, PlacedEvents).

% day_allowed(+Activity, +Day)
% Mon-Fri: anything. Saturday: anything. Sunday: no gym (closed).
% Weekdays are naturally preferred because slot scan starts from Monday.
day_allowed(gym, sunday) :- !, fail.
day_allowed(food_after_gym, sunday) :- !, fail.
day_allowed(_, _).

% =============================================================================
% DAILY LIMITS
% Max 2 math-related flexible tasks per day.
% Max 3 university-related (homework + self-study) flexible tasks per day.
% Fixed university lectures don't count — they can't be moved anyway.
% =============================================================================

math_flex(ma_hw).
math_flex(la_hw).
math_flex(dm_tasks).
math_flex(dm_theory).
math_flex(ma_theory).

study_flex(A) :- activity(A, homework, _).
study_flex(A) :- activity(A, self_study, _).

daily_limits_ok(Activity, Day, Placed) :-
    check_math_limit(Activity, Day, Placed),
    check_study_limit(Activity, Day, Placed).

% Max 2 math flex tasks per day
check_math_limit(Activity, Day, Placed) :-
    math_flex(Activity),
    !,
    findall(_, (member(event(A, Day, _, _, _, _), Placed), math_flex(A)), L),
    length(L, N),
    N < 2.
check_math_limit(_, _, _).

% Max 3 study flex tasks (homework + self-study) per day
check_study_limit(Activity, Day, Placed) :-
    study_flex(Activity),
    !,
    findall(_, (member(event(A, Day, _, _, _, _), Placed), study_flex(A)), L),
    length(L, N),
    N < 3.
check_study_limit(_, _, _).

% gym_consecutive(+Activity, +Day, +PlacedEvents)
% Succeeds (= blocks) if gym was already placed on the day before or after.
gym_consecutive(gym, Day, Placed) :-
    ( next_day(Prev, Day) ; next_day(Day, Prev) ),
    member(event(gym, Prev, _, _, _, _), Placed).
gym_consecutive(food_after_gym, Day, Placed) :-
    gym_consecutive(gym, Day, Placed).

% gym_hours_ok(+Activity, +StartH, +EndH)
% Gym is open 9:00–18:00.
gym_hours_ok(gym, StartH, EndH) :- !, StartH >= 9.0, EndH =< 18.0.
gym_hours_ok(food_after_gym, _, _) :- !.   % food can be outside gym hours
gym_hours_ok(_, _, _).

% already_on_day(+Activity, +Day, +PlacedEvents)
% Prevent scheduling the same physical activity twice on one day.
already_on_day(Activity, Day, Placed) :-
    member(Activity, [gym, tennis, food_after_gym]),
    member(event(Activity, Day, _, _, _, _), Placed).

% food_gym_ok(+Activity, +Day, +StartH, +PlacedEvents)
% food_after_gym must be scheduled AFTER gym on the same day (within 2h).
food_gym_ok(food_after_gym, Day, StartH, Placed) :-
    !,
    member(event(gym, Day, _, GymEnd, _, _), Placed),
    StartH >= GymEnd,
    StartH =< GymEnd + 2.0.
food_gym_ok(_, _, _, _).

% ranges_overlap(+S, +E, +Ranges)
% O(n) check against precomputed range(Start,End) pairs.
ranges_overlap(S, E, Ranges) :-
    member(range(RS, RE), Ranges),
    S < RE,
    E > RS.

% physical_conflict(+Activity, +Day, +PlacedEvents)
% Succeeds if Activity is incompatible with something already on Day.
physical_conflict(Activity, Day, Placed) :-
    incompatible_same_day(Activity, Other),
    member(event(Other, Day, _, _, _, _), Placed).

% buddy_ok(+Activity, +Day, +StartH)
buddy_ok(tennis, Day, StartH) :-
    !,
    buddy_available(dmitri, Day, BuddyStart, BuddyEnd),
    StartH >= BuddyStart,
    StartH <  BuddyEnd.
buddy_ok(_, _, _).

% weather_ok(+Activity, +Day, +StartH, +WeatherList)
% WeatherList contains both:
%   Day-Hour-Condition  (hourly, from 3-hour forecast slots)
%   Day-Condition       (day-level fallback)
% For weather-sensitive activities, checks the 3-hour slot covering StartH.
% Slot hour H covers the range [H, H+3).
weather_ok(Activity, Day, StartH, WeatherList) :-
    needs_good_weather(Activity),
    !,
    weather_slot_ok(Day, StartH, WeatherList).
weather_ok(_, _, _, _).

% Find the 3-hour weather slot that covers the activity start time.
% A slot with hour H covers [H, H+3).
weather_slot_ok(Day, StartH, WeatherList) :-
    % Try to find an hourly entry covering this time
    StartHInt is truncate(StartH),
    ( member(Day-SlotH-Cond, WeatherList),
      SlotH =< StartHInt,
      StartHInt < SlotH + 3
    ->  Cond = good
    ;   % No hourly data for this slot — fall back to day-level
        ( member(Day-good, WeatherList) -> true
        ; \+ member(Day-_, WeatherList)   % no data at all = optimistic
        )
    ).

% tennis_window_ok(+Activity, +StartH, +EndH)
tennis_window_ok(tennis, StartH, EndH) :-
    !,
    StartH >= 16.0,
    EndH   =< 20.0.
tennis_window_ok(_, _, _).

% =============================================================================
% DROPPED WARNINGS
% =============================================================================

dropped_warnings([], []).
dropped_warnings([Act | Rest], [W | Ws]) :-
    format(atom(W), 'Could not schedule ~w — no valid slot found', [Act]),
    dropped_warnings(Rest, Ws).

% =============================================================================
% STATISTICS
% schedule_stats(+Schedule, -Stats)
% Stats = stats(UniMin, StudyMin, PhysMin, FreeMin, SleepMin)
% =============================================================================

schedule_stats(Schedule, Stats) :-
    sum_event_minutes(Schedule, fixed,    UniMin),
    sum_event_minutes(Schedule, semi_fixed, SemiMin),
    UniTotal is UniMin + SemiMin,

    findall(M,
        ( member(event(Act, _, SH, EH, _, flexible), Schedule),
          activity(Act, Type, _),
          member(Type, [homework, self_study]),
          M is round((EH - SH) * 60)
        ),
        StudyMins),
    sumlist(StudyMins, StudyMin),

    findall(M,
        ( member(event(Act, _, SH, EH, _, flexible), Schedule),
          activity(Act, physical, _),
          M is round((EH - SH) * 60)
        ),
        PhysMins),
    sumlist(PhysMins, PhysMin),

    SleepMin is 7 * (8 * 60 + 20),
    TotalMin is 7 * 24 * 60,
    FlexTotal is TotalMin - UniTotal - SleepMin,
    FreeMin is max(0, FlexTotal - StudyMin - PhysMin),

    Stats = stats(UniTotal, StudyMin, PhysMin, FreeMin, SleepMin).

sum_event_minutes(Schedule, Type, Total) :-
    findall(M,
        ( member(event(_, _, SH, EH, _, Type), Schedule),
          M is round((EH - SH) * 60)
        ),
        Mins),
    sumlist(Mins, Total).

% sumlist/2 — sum a list of numbers (tail-recursive with accumulator)
sumlist(List, Sum) :- sumlist(List, 0, Sum).
sumlist([], Acc, Acc).
sumlist([H|T], Acc, Sum) :-
    NewAcc is Acc + H,
    sumlist(T, NewAcc, Sum).
