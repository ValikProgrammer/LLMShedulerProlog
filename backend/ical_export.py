"""
ical_export.py
Converts a schedule (list of event dicts) to an iCalendar (.ics) file.
The exported file can be imported directly into Google Calendar, Apple Calendar, etc.

Color mapping follows the user's Google Calendar color scheme:
  Sage       — university lectures/labs
  Flamingo   — programming homework
  Tangerine  — TE / startups
  Banana     — sports (gym, tennis, hike)
  Basil      — additional DM/LA classes
  Grape      — self-study math homework
  Graphite   — food / misc time
  Peacock    — default / admin
  Blueberry  — HUB, social, tutor

NOTE: Google Calendar does NOT honor per-event COLOR in .ics imports.
      All imported events get the calendar's default color.
      The COLOR property (RFC 7986) is included for Apple Calendar and
      other clients that support it. CATEGORIES are set for organization.
"""

import datetime
from icalendar import Calendar, Event
from pathlib import Path

# Map day names to weekday integers (Monday=0)
DAY_TO_WEEKDAY = {
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
    "friday": 4, "saturday": 5, "sunday": 6,
}

# Google Calendar named colors → hex
GCAL_COLORS = {
    "Sage":       "#33B679",
    "Flamingo":   "#E67C73",
    "Tangerine":  "#F4511E",
    "Banana":     "#F6BF26",
    "Basil":      "#0B8043",
    "Grape":      "#8E24AA",
    "Graphite":   "#616161",
    "Peacock":    "#039BE5",
    "Blueberry":  "#3F51B5",
}

# Subject → Google Calendar color category name
SUBJECT_GCAL_CATEGORY = {
    # Sage — university lectures (official classes only)
    "math_analysis":    "Sage",
    "linear_algebra":   "Sage",
    "discrete_math":    "Sage",
    "algorithms":       "Sage",
    "kotlin":           "Sage",
    "prog_paradigms":   "Sage",
    "project_seminar":  "Sage",

    # Tangerine — TE / startups
    "jb_horizons":      "Tangerine",
    "te_jb_hw":         "Tangerine",

    # Flamingo — programming homework
    "prog_hw":          "Flamingo",
    "algo_hw":          "Flamingo",
    "kotlin_hw":        "Flamingo",
    "kotlin_lecture":   "Flamingo",

    # Banana — sports
    "gym":              "Banana",
    "tennis":           "Banana",
    "hike":             "Banana",

    # Basil — additional DM / LA classes
    "discrete_upsolve": "Basil",
    "la_plus_plus":     "Basil",

    # Grape — self-study / homework math
    "ma_hw":            "Grape",
    "la_hw":            "Grape",
    "dm_tasks":         "Grape",
    "dm_theory":        "Grape",
    "ma_theory":        "Grape",

    # Graphite — food
    "food_after_gym":   "Graphite",

    # Blueberry — HUB, social, tutor
    "the_hub":          "Blueberry",
    "mafia":            "Blueberry",

    # Peacock — default / admin
    "migration_office": "Peacock",
}


def _get_gcal_category(subject: str) -> str:
    """Return the Google Calendar color category name for a subject."""
    return SUBJECT_GCAL_CATEGORY.get(subject, "Peacock")


def _parse_time(time_str: str) -> tuple[int, int]:
    """Parse 'HH:MM' into (hour, minute)."""
    h, m = time_str.split(":")
    return int(h), int(m)


def schedule_to_ical(schedule: list[dict], week_start: datetime.date | None = None) -> bytes:
    """
    Convert a schedule list to iCal bytes.

    Args:
        schedule:   List of event dicts with keys:
                    subject, label, day, start (HH:MM), end (HH:MM), color, type
        week_start: Monday of the target week. Defaults to the current week's Monday.

    Returns:
        .ics file content as bytes.
    """
    if week_start is None:
        today = datetime.date.today()
        week_start = today - datetime.timedelta(days=today.weekday())

    cal = Calendar()
    cal.add("prodid", "-//Smart Scheduler//PrologPlanner//EN")
    cal.add("version", "2.0")
    cal.add("calscale", "GREGORIAN")
    cal.add("x-wr-calname", "Smart Schedule")
    cal.add("x-wr-timezone", "Europe/Nicosia")

    for ev in schedule:
        day_date = week_start + datetime.timedelta(days=DAY_TO_WEEKDAY[ev["day"]])

        start_h, start_m = _parse_time(ev["start"])
        end_h,   end_m   = _parse_time(ev["end"])

        dtstart = datetime.datetime(
            day_date.year, day_date.month, day_date.day, start_h, start_m,
            tzinfo=datetime.timezone.utc
        )
        dtend = datetime.datetime(
            day_date.year, day_date.month, day_date.day, end_h, end_m,
            tzinfo=datetime.timezone.utc
        )

        subject = ev.get("subject", "")
        gcal_cat = _get_gcal_category(subject)
        gcal_hex = GCAL_COLORS.get(gcal_cat, "#039BE5")

        cal_event = Event()
        cal_event.add("summary", ev.get("label", subject))
        cal_event.add("dtstart", dtstart)
        cal_event.add("dtend",   dtend)
        cal_event.add("description",
                       f"Type: {ev.get('type', 'flexible')}\n"
                       f"Subject: {subject}\n"
                       f"Color: {gcal_cat}")
        cal_event.add("categories", [gcal_cat, ev.get("type", "flexible")])

        # RFC 7986 COLOR property (Apple Calendar honors this)
        cal_event.add("color", gcal_hex)

        # Apple Calendar specific
        cal_event.add("x-apple-calendar-color", gcal_hex)

        cal.add_component(cal_event)

    return cal.to_ical()


def save_ical(schedule: list[dict], path: str | Path,
              week_start: datetime.date | None = None) -> None:
    """Write iCal bytes to a file."""
    content = schedule_to_ical(schedule, week_start)
    Path(path).write_bytes(content)
