% =============================================================================
% utils.pl
% Time arithmetic helpers, day ordering, slot conversion utilities.
% =============================================================================

:- module(utils, [
    day_index/2,
    hour_to_slot/2,
    slot_to_hour/2,
    slot_to_day_hour/3,
    day_hour_to_slot/3,
    day_hour_to_end_slot/3,
    slots_per_day/1,
    total_slots/1,
    time_of_day/2,
    minutes_to_slots/2,
    slots_to_minutes/2,
    format_time/2,
    days_of_week/1,
    next_day/2
]).

% =============================================================================
% TIME SLOT SYSTEM
% The week is divided into 30-minute slots.
% Slots 1..336 cover Mon 00:00 through Sun 23:30.
% Slot = (DayIndex - 1) * 48 + HalfHourIndex
% where HalfHourIndex counts 30-min blocks from midnight (1-indexed).
% =============================================================================

slots_per_day(48).   % 24 hours * 2 slots/hour
total_slots(336).    % 7 days * 48 slots

% day_index(?Day, ?Index)
day_index(monday,    1).
day_index(tuesday,   2).
day_index(wednesday, 3).
day_index(thursday,  4).
day_index(friday,    5).
day_index(saturday,  6).
day_index(sunday,    7).

days_of_week([monday, tuesday, wednesday, thursday, friday, saturday, sunday]).

next_day(monday,    tuesday).
next_day(tuesday,   wednesday).
next_day(wednesday, thursday).
next_day(thursday,  friday).
next_day(friday,    saturday).
next_day(saturday,  sunday).
next_day(sunday,    monday).

% hour_to_slot(+DecimalHour, -SlotWithinDay)
% e.g. 9.0 -> 19 (slot 19 = 9:00, since 9*2+1 = 19)
hour_to_slot(Hour, Slot) :-
    Slot is truncate(Hour * 2) + 1.

% slot_to_hour(+SlotWithinDay, -DecimalHour)
slot_to_hour(Slot, Hour) :-
    Hour is (Slot - 1) / 2.0.

% day_hour_to_slot(+Day, +DecimalHour, -AbsoluteSlot)
day_hour_to_slot(Day, Hour, Slot) :-
    day_index(Day, DayIdx),
    slots_per_day(SPD),
    hour_to_slot(Hour, HourSlot),
    Slot is (DayIdx - 1) * SPD + HourSlot.

% day_hour_to_end_slot(+Day, +DecimalHour, -AbsoluteSlot)
% Like day_hour_to_slot but rounds UP so partial slot occupation counts as full.
% e.g. 21:15 (21.25) -> ceiling(21.25*2)+1 = 44 instead of truncate -> 43.
% This prevents events from being placed in slots partially occupied by fixed events.
day_hour_to_end_slot(Day, Hour, Slot) :-
    day_index(Day, DayIdx),
    slots_per_day(SPD),
    HourSlot is ceiling(Hour * 2) + 1,
    Slot is (DayIdx - 1) * SPD + HourSlot.

% slot_to_day_hour(+AbsoluteSlot, -Day, -DecimalHour)
slot_to_day_hour(Slot, Day, Hour) :-
    slots_per_day(SPD),
    DayIdx is (Slot - 1) // SPD + 1,
    day_index(Day, DayIdx),
    SlotWithinDay is (Slot - 1) mod SPD + 1,
    slot_to_hour(SlotWithinDay, Hour).

% minutes_to_slots(+Minutes, -Slots)
minutes_to_slots(Minutes, Slots) :-
    Slots is ceiling(Minutes / 30).

% slots_to_minutes(+Slots, -Minutes)
slots_to_minutes(Slots, Minutes) :-
    Minutes is Slots * 30.

% time_of_day(+DecimalHour, -Period)
% Classifies an hour into morning / afternoon / evening
time_of_day(Hour, morning)   :- Hour >= 8.0,  Hour < 12.0.
time_of_day(Hour, afternoon) :- Hour >= 12.0, Hour < 17.0.
time_of_day(Hour, evening)   :- Hour >= 17.0, Hour < 23.0.
time_of_day(Hour, night)     :- ( Hour >= 23.0 ; Hour < 8.0 ).

% format_time(+DecimalHour, -String)
% e.g. 9.5 -> "09:30"
format_time(Hour, String) :-
    H is truncate(Hour),
    M is round((Hour - H) * 60),
    format(atom(String), '~`0t~d~2|:~`0t~d~2|', [H, M]).
