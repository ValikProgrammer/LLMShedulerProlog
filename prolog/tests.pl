% =============================================================================
% tests.pl
% Unit tests for the Smart Scheduler — SWI-Prolog plunit framework.
%
% Run from project root:
%   swipl -g run_tests -t halt prolog/tests.pl
%
% Or inside swipl:
%   ?- [prolog/tests].
%   ?- run_tests.
% =============================================================================

:- use_module(utils).
:- use_module(knowledge_base).
:- use_module(constraints).
:- use_module(scheduler).

:- use_module(library(plunit)).

% Shared test helpers (visible to all test blocks)
:- meta_predicate schedule_has_overlap(+).
schedule_has_overlap(Schedule) :-
    member(event(_, Day, S1, E1, _, _), Schedule),
    member(event(_, Day, S2, E2, _, _), Schedule),
    S1 \= S2,
    S1 < E2, S2 < E1.

% =============================================================================
% 1. UTILS — slot conversion round-trips
% =============================================================================

:- begin_tests(utils_slot_conversion).

test(hour_to_slot_nine, [true(S == 19)]) :-
    hour_to_slot(9.0, S).

test(hour_to_slot_midnight, [true(S == 1)]) :-
    hour_to_slot(0.0, S).

test(slot_to_hour_roundtrip, [true(H =:= 9.0)]) :-
    hour_to_slot(9.0, S),
    slot_to_hour(S, H).

test(day_hour_to_slot_monday_nine, [true(Slot == 19)]) :-
    day_hour_to_slot(monday, 9.0, Slot).

test(day_hour_to_slot_tuesday_noon, [true(Slot == 73)]) :-
    % Tuesday = day 2, noon = 12.0 → slot 25 within day
    % Absolute: (2-1)*48 + 25 = 73
    day_hour_to_slot(tuesday, 12.0, Slot).

test(slot_to_day_hour_roundtrip) :-
    day_hour_to_slot(wednesday, 15.0, Slot),
    slot_to_day_hour(Slot, Day, Hour),
    Day == wednesday,
    Hour =:= 15.0.

test(day_hour_end_slot_rounds_up, [true(EndSlot > StartSlot)]) :-
    % 21:15 = 21.25h, should round UP to occupy the full slot
    day_hour_to_slot(wednesday, 21.0, StartSlot),
    day_hour_to_end_slot(wednesday, 21.25, EndSlot).

test(day_hour_end_slot_exact_half_hour, [true(E1 == E2)]) :-
    % Exact 30-min boundary should give same result with both functions
    day_hour_to_slot(monday, 10.0, E1),
    day_hour_to_end_slot(monday, 10.0, E2).

test(minutes_to_slots_60, [true(S == 2)]) :-
    minutes_to_slots(60, S).

test(minutes_to_slots_90, [true(S == 3)]) :-
    minutes_to_slots(90, S).

test(minutes_to_slots_45_rounds_up, [true(S == 2)]) :-
    minutes_to_slots(45, S).

test(total_slots_is_336, [true(T == 336)]) :-
    total_slots(T).

test(slots_per_day_is_48, [true(S == 48)]) :-
    slots_per_day(S).

:- end_tests(utils_slot_conversion).

% =============================================================================
% 2. UTILS — day helpers
% =============================================================================

:- begin_tests(utils_day_helpers).

test(day_index_monday, [true(I == 1)]) :-
    day_index(monday, I).

test(day_index_sunday, [true(I == 7)]) :-
    day_index(sunday, I).

test(day_index_reverse, [true(D == friday)]) :-
    day_index(D, 5).

test(next_day_monday_tuesday) :-
    next_day(monday, tuesday).

test(next_day_sunday_wraps, [true(Next == monday)]) :-
    next_day(sunday, Next).

test(days_of_week_length, [true(Len == 7)]) :-
    days_of_week(Days),
    length(Days, Len).

test(time_of_day_morning) :-
    time_of_day(9.0, morning).

test(time_of_day_evening) :-
    time_of_day(19.0, evening).

:- end_tests(utils_day_helpers).

% =============================================================================
% 3. KNOWLEDGE BASE — facts integrity
% =============================================================================

:- begin_tests(knowledge_base_facts).

test(university_classes_count, [true(N == 11)]) :-
    findall(_, university_class(_, _, _, _), Cs),
    length(Cs, N).

test(semi_fixed_count, [true(N == 1)]) :-
    findall(_, semi_fixed(_, _, _, _), Cs),
    length(Cs, N).

test(sleep_block_exists) :-
    sleep_block(Start, End),
    Start =:= 0.0,
    End =:= 8.333.

test(activity_types_valid) :-
    findall(Type, activity(_, Type, _), Types),
    ValidTypes = [homework, self_study, physical, social, admin],
    forall(member(T, Types), member(T, ValidTypes)).

test(priorities_in_range) :-
    findall(P, priority(_, P), Ps),
    forall(member(P, Ps), (P >= 1, P =< 10)).

test(incompatible_symmetric) :-
    forall(
        incompatible_same_day(A, B),
        incompatible_same_day(B, A)
    ).

test(buddy_dmitri_three_days, [true(N == 3)]) :-
    findall(D, buddy_available(dmitri, D, _, _), Ds),
    length(Ds, N).

test(weather_sensitive_activities, [true(Sorted == [hike, tennis])]) :-
    findall(A, needs_good_weather(A), As),
    msort(As, Sorted).

:- end_tests(knowledge_base_facts).

% =============================================================================
% 4. CONSTRAINTS — overlap detection
% =============================================================================

:- begin_tests(constraints_overlap).

test(overlap_basic) :-
    blocks_overlap(1, 5, 3, 8).

test(no_overlap_adjacent, [fail]) :-
    blocks_overlap(1, 5, 5, 10).

test(no_overlap_disjoint, [fail]) :-
    blocks_overlap(1, 3, 5, 8).

test(overlap_contained) :-
    blocks_overlap(1, 10, 3, 7).

test(sleep_block_slot_at_3am) :-
    % 3am Monday = hour 3.0, slot within day = 7
    % Absolute slot = 7 (Monday day 1)
    day_hour_to_slot(monday, 3.0, Slot),
    slot_in_sleep_block(Slot).

test(no_sleep_at_noon, [fail]) :-
    day_hour_to_slot(monday, 12.0, Slot),
    slot_in_sleep_block(Slot).

test(university_block_monday_9am) :-
    day_hour_to_slot(monday, 9.5, Slot),
    slot_in_university_block(Slot).

test(no_uni_block_monday_8am, [fail]) :-
    day_hour_to_slot(monday, 8.0, Slot),
    slot_in_university_block(Slot).

:- end_tests(constraints_overlap).

% =============================================================================
% 5. CONSTRAINTS — incompatibility and recovery
% =============================================================================

:- begin_tests(constraints_incompatibility).

test(gym_hike_incompatible) :-
    incompatible_same_day(gym, hike).

test(gym_tennis_incompatible) :-
    incompatible_same_day(gym, tennis).

test(gym_homework_compatible, [fail]) :-
    incompatible_same_day(gym, ma_hw).

test(recovery_after_gym, [true(R == 90)]) :-
    recovery_time(gym, R).

test(buddy_available_monday) :-
    buddy_available(dmitri, monday, Start, End),
    Start =:= 16.0,
    End =:= 20.0.

test(buddy_not_available_thursday, [fail]) :-
    buddy_available(dmitri, thursday, _, _).

:- end_tests(constraints_incompatibility).

% =============================================================================
% 6. SCHEDULER — color mapping
% =============================================================================

:- begin_tests(scheduler_colors).

test(sage_for_lectures, [true(C == '#33B679')]) :-
    scheduler:get_color(math_analysis, C).

test(banana_for_gym, [true(C == '#F6BF26')]) :-
    scheduler:get_color(gym, C).

test(grape_for_math_hw, [true(C == '#8E24AA')]) :-
    scheduler:get_color(ma_hw, C).

test(flamingo_for_prog_hw, [true(C == '#E67C73')]) :-
    scheduler:get_color(prog_hw, C).

test(tangerine_for_te, [true(C == '#F4511E')]) :-
    scheduler:get_color(te_jb_hw, C).

test(default_peacock_for_unknown, [true(C == '#039BE5')]) :-
    scheduler:get_color(nonexistent_subject, C).

:- end_tests(scheduler_colors).

% =============================================================================
% 7. SCHEDULER — fixed events
% =============================================================================

:- begin_tests(scheduler_fixed_events).

test(fixed_events_count, [true(N == 12)]) :-
    % 11 university_class + 1 semi_fixed = 12
    scheduler:fixed_events(Events),
    length(Events, N).

test(fixed_events_have_correct_type) :-
    scheduler:fixed_events(Events),
    forall(
        member(event(_, _, _, _, _, Type), Events),
        member(Type, [fixed, semi_fixed])
    ).

test(fixed_events_no_overlap) :-
    scheduler:fixed_events(Events),
    \+ has_overlap(Events).

% Helper: check no pair of events on the same day overlap
has_overlap(Events) :-
    member(event(_, Day, S1, E1, _, _), Events),
    member(event(_, Day, S2, E2, _, _), Events),
    S1 \= S2,  % different events
    S1 < E2, S2 < E1.

test(all_fixed_have_colors) :-
    scheduler:fixed_events(Events),
    forall(
        member(event(_, _, _, _, Color, _), Events),
        atom(Color)
    ).

:- end_tests(scheduler_fixed_events).

% =============================================================================
% 8. SCHEDULER — flexible task collection
% =============================================================================

:- begin_tests(scheduler_tasks).

test(base_tasks_count, [true(N == 23)]) :-
    findall(_, scheduler:base_flexible_task(_, _, _), Ts),
    length(Ts, N).

test(collect_tasks_no_request, [true(N == 23)]) :-
    scheduler:collect_flexible_tasks([], Tasks),
    length(Tasks, N).

test(collect_tasks_with_skip, [true(N < 23)]) :-
    scheduler:collect_flexible_tasks([skip_activity(gym)], Tasks),
    length(Tasks, N),
    \+ member(task(_, gym, _, _, _, _), Tasks).

test(deadline_boost_increases_priority) :-
    scheduler:collect_flexible_tasks(
        [add_deadline(ma_hw, 1)],  % deadline in 1 day
        Tasks
    ),
    member(task(_, ma_hw, _, P, _, _), Tasks),
    P > 8.  % base priority is 8, should boost to 9

test(all_sessions_under_120_min) :-
    findall(M, scheduler:base_flexible_task(_, _, M), Mins),
    forall(member(M, Mins), M =< 120).

:- end_tests(scheduler_tasks).

% =============================================================================
% 9. SCHEDULER — priority sorting
% =============================================================================

:- begin_tests(scheduler_priority_sort).

test(higher_priority_first) :-
    Tasks = [
        task(a, algo_hw, 120, 5, any, any),    % priority 5
        task(b, ma_hw,   120, 8, any, any),     % priority 8
        task(c, tennis,   90, 4, any, any)      % priority 4
    ],
    scheduler:sort_tasks_by_priority(Tasks, Sorted),
    Sorted = [task(_, First, _, _, _, _) | _],
    First == ma_hw.  % highest priority = 8

test(gym_before_same_priority_homework) :-
    % gym (P5, bonus 35) should sort before algo_hw (P5, bonus 0)
    Tasks = [
        task(a, algo_hw, 120, 5, any, any),
        task(b, gym,      60, 5, any, any)
    ],
    scheduler:sort_tasks_by_priority(Tasks, [task(_, First, _, _, _, _) | _]),
    First == gym.

test(tennis_before_regular_homework) :-
    % tennis (P4, bonus 42) → key=918; kotlin_hw (P6, bonus 0) → key=940
    Tasks = [
        task(a, kotlin_hw, 90, 6, any, any),
        task(b, tennis,    90, 4, any, any)
    ],
    scheduler:sort_tasks_by_priority(Tasks, [task(_, First, _, _, _, _) | _]),
    First == tennis.

:- end_tests(scheduler_priority_sort).

% =============================================================================
% 10. SCHEDULER — slot validation constraints
% =============================================================================

:- begin_tests(scheduler_slot_valid).

test(gym_blocked_on_sunday, [fail]) :-
    % Sunday 10:00 = day 7, hour 10.0
    day_hour_to_slot(sunday, 10.0, StartSlot),
    EndSlot is StartSlot + 2,  % 1 hour = 2 slots
    scheduler:slot_valid(gym, StartSlot, EndSlot, [], [], [], []).

test(gym_ok_on_saturday) :-
    day_hour_to_slot(saturday, 10.0, StartSlot),
    EndSlot is StartSlot + 2,
    scheduler:slot_valid(gym, StartSlot, EndSlot, [], [], [], []).

test(gym_blocked_outside_hours, [fail]) :-
    % Gym at 19:00 — outside 9:00-18:00 window
    day_hour_to_slot(monday, 19.0, StartSlot),
    EndSlot is StartSlot + 2,
    scheduler:slot_valid(gym, StartSlot, EndSlot, [], [], [], []).

test(gym_consecutive_day_blocked, [fail]) :-
    % Gym on Tuesday with gym already on Monday
    day_hour_to_slot(tuesday, 10.0, StartSlot),
    EndSlot is StartSlot + 2,
    Placed = [event(gym, monday, 10.0, 11.0, '#F6BF26', flexible)],
    scheduler:slot_valid(gym, StartSlot, EndSlot, [], [], Placed, []).

test(gym_non_consecutive_ok) :-
    % Gym on Wednesday with gym on Monday (not consecutive)
    day_hour_to_slot(wednesday, 15.5, StartSlot),
    EndSlot is StartSlot + 2,
    Placed = [event(gym, monday, 10.0, 11.0, '#F6BF26', flexible)],
    scheduler:slot_valid(gym, StartSlot, EndSlot, [], [], Placed, []).

test(food_requires_gym_same_day, [fail]) :-
    % food_after_gym on Monday but no gym on Monday
    day_hour_to_slot(monday, 12.0, StartSlot),
    EndSlot is StartSlot + 1,
    scheduler:slot_valid(food_after_gym, StartSlot, EndSlot, [], [], [], []).

test(food_ok_after_gym) :-
    day_hour_to_slot(monday, 11.5, StartSlot),
    EndSlot is StartSlot + 1,
    Placed = [event(gym, monday, 10.0, 11.0, '#F6BF26', flexible)],
    scheduler:slot_valid(food_after_gym, StartSlot, EndSlot, [], [], Placed, []).

test(overlap_with_fixed_blocked, [fail]) :-
    % Try to place at Monday 9:00-10:00, which overlaps with math_analysis 9:00-10:30
    day_hour_to_slot(monday, 9.0, StartSlot),
    EndSlot is StartSlot + 2,
    % Create range for math_analysis
    day_hour_to_slot(monday, 9.0, FixedS),
    day_hour_to_end_slot(monday, 10.5, FixedE),
    FixedRanges = [range(FixedS, FixedE)],
    scheduler:slot_valid(ma_hw, StartSlot, EndSlot, FixedRanges, [], [], []).

test(math_daily_limit_blocks_third, [fail]) :-
    % Already 2 math tasks on Monday, trying to add a third
    day_hour_to_slot(monday, 18.0, StartSlot),
    EndSlot is StartSlot + 2,
    Placed = [
        event(ma_hw, monday, 10.0, 11.0, '#8E24AA', flexible),
        event(la_hw, monday, 15.0, 16.0, '#8E24AA', flexible)
    ],
    scheduler:slot_valid(dm_tasks, StartSlot, EndSlot, [], [], Placed, []).

test(non_math_ignores_math_limit) :-
    % Kotlin (not math) should be ok even with 2 math tasks already
    day_hour_to_slot(monday, 18.0, StartSlot),
    EndSlot is StartSlot + 2,
    Placed = [
        event(ma_hw, monday, 10.0, 11.0, '#8E24AA', flexible),
        event(la_hw, monday, 15.0, 16.0, '#8E24AA', flexible)
    ],
    scheduler:slot_valid(kotlin_hw, StartSlot, EndSlot, [], [], Placed, []).

:- end_tests(scheduler_slot_valid).

% =============================================================================
% 11. SCHEDULER — full schedule generation
% =============================================================================

:- begin_tests(scheduler_generation).

test(generates_nonempty_schedule) :-
    generate_schedule([], Schedule, _),
    length(Schedule, N),
    N > 0.

test(schedule_includes_all_fixed, [true(FixedCount == 12)]) :-
    generate_schedule([], Schedule, _),
    include([E]>>(E = event(_, _, _, _, _, Type), member(Type, [fixed, semi_fixed])), Schedule, Fixed),
    length(Fixed, FixedCount).

test(schedule_has_no_overlaps) :-
    generate_schedule([], Schedule, _),
    \+ schedule_has_overlap(Schedule).

test(schedule_respects_sleep_block) :-
    generate_schedule([], Schedule, _),
    sleep_block(_, SleepEnd),
    forall(
        member(event(_, _, StartH, _, _, _), Schedule),
        StartH >= SleepEnd
    ).

test(no_gym_on_sunday) :-
    generate_schedule([], Schedule, _),
    \+ member(event(gym, sunday, _, _, _, _), Schedule).

test(gym_non_consecutive_days) :-
    generate_schedule([], Schedule, _),
    findall(Day, member(event(gym, Day, _, _, _, _), Schedule), GymDays),
    no_consecutive_days(GymDays).

% Helper: verify no two days in list are consecutive
no_consecutive_days([]).
no_consecutive_days([_]).
no_consecutive_days([D1, D2 | Rest]) :-
    \+ next_day(D1, D2),
    \+ next_day(D2, D1),
    no_consecutive_days([D2 | Rest]).

test(food_always_after_gym) :-
    generate_schedule([], Schedule, _),
    forall(
        member(event(food_after_gym, Day, FoodStart, _, _, _), Schedule),
        ( member(event(gym, Day, _, GymEnd, _, _), Schedule),
          FoodStart >= GymEnd )
    ).

test(all_events_before_22) :-
    generate_schedule([], Schedule, _),
    forall(
        member(event(_, _, _, EndH, _, _), Schedule),
        EndH =< 22.0
    ).

:- end_tests(scheduler_generation).

% =============================================================================
% 12. SCHEDULER — all_schedules alternatives
% =============================================================================

:- begin_tests(scheduler_alternatives).

test(multiple_alternatives, [true(N > 1)]) :-
    all_schedules([], AllSchedules, _),
    length(AllSchedules, N).

test(all_alternatives_valid) :-
    all_schedules([], AllSchedules, _),
    forall(
        member(Sched, AllSchedules),
        \+ schedule_has_overlap(Sched)
    ).

test(alternatives_differ) :-
    all_schedules([], AllSchedules, _),
    AllSchedules = [First, Second | _],
    First \= Second.

:- end_tests(scheduler_alternatives).

% =============================================================================
% 13. SCHEDULER — statistics
% =============================================================================

:- begin_tests(scheduler_stats).

test(stats_structure) :-
    generate_schedule([], Schedule, _),
    schedule_stats(Schedule, Stats),
    Stats = stats(UniMin, StudyMin, PhysMin, FreeMin, SleepMin),
    UniMin > 0,
    StudyMin > 0,
    PhysMin >= 0,
    FreeMin >= 0,
    SleepMin > 0.

test(sleep_is_7_days, [true(SleepMin =:= 7 * (8*60+20))]) :-
    generate_schedule([], Schedule, _),
    schedule_stats(Schedule, stats(_, _, _, _, SleepMin)).

test(stats_sum_reasonable) :-
    generate_schedule([], Schedule, _),
    schedule_stats(Schedule, stats(Uni, Study, Phys, Free, Sleep)),
    Total is Uni + Study + Phys + Free + Sleep,
    WeekMins is 7 * 24 * 60,
    Total =:= WeekMins.

:- end_tests(scheduler_stats).

% =============================================================================
% 14. SCHEDULER — dropped warnings (tail-recursive)
% =============================================================================

:- begin_tests(scheduler_warnings).

test(no_drops_empty_warnings, [true(W == [])]) :-
    scheduler:dropped_warnings([], W).

test(one_drop_one_warning, [true(Len == 1)]) :-
    scheduler:dropped_warnings([gym], W),
    length(W, Len).

test(multiple_drops, [true(Len == 3)]) :-
    scheduler:dropped_warnings([gym, tennis, hike], W),
    length(W, Len).

test(warning_text_format) :-
    scheduler:dropped_warnings([gym], [W]),
    sub_atom(W, _, _, _, 'gym').

:- end_tests(scheduler_warnings).

% =============================================================================
% 15. SCHEDULER — sumlist (tail recursion)
% =============================================================================

:- begin_tests(scheduler_sumlist).

test(sumlist_empty, [true(S == 0)]) :-
    scheduler:sumlist([], S).

test(sumlist_single, [true(S == 42)]) :-
    scheduler:sumlist([42], S).

test(sumlist_many, [true(S == 15)]) :-
    scheduler:sumlist([1, 2, 3, 4, 5], S).

:- end_tests(scheduler_sumlist).

% =============================================================================
% 16. EDGE CASES
% =============================================================================

:- begin_tests(edge_cases).

test(skip_all_gym_sessions) :-
    generate_schedule([skip_activity(gym)], Schedule, _),
    \+ member(event(gym, _, _, _, _, _), Schedule).

test(skip_reduces_event_count) :-
    generate_schedule([], Full, _),
    generate_schedule([skip_activity(gym), skip_activity(food_after_gym)], Reduced, _),
    length(Full, N1),
    length(Reduced, N2),
    N2 < N1.

test(deadline_boost_capped_at_9) :-
    scheduler:effective_priority(ma_hw, [deadline(ma_hw, 1)], P),
    P =< 9.

test(oneoff_task_added) :-
    Request = [add_oneoff(custom1, meeting, tuesday, 10.0, 60, 7)],
    scheduler:collect_flexible_tasks(Request, Tasks),
    member(task(custom1, meeting, 60, 7, tuesday, 10.0), Tasks).

:- end_tests(edge_cases).
