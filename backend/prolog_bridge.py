"""
prolog_bridge.py
Manages the pyswip interface to SWI-Prolog.
Loads all .pl files once on import, then exposes query methods.
"""

import threading
from pathlib import Path
from pyswip import Prolog

PROLOG_DIR = Path(__file__).parent.parent / "prolog"

# Single global Prolog instance — pyswip is not thread-safe.
prolog = Prolog()

# Mutex: ensures only one Prolog query runs at a time.
_lock = threading.Lock()


def _reset_stuck_query():
    """Force-reset pyswip 0.3.x query-open flag."""
    Prolog._queryIsOpen = False


# Initialise: load all source files.
for _pl_file in ["utils.pl", "knowledge_base.pl", "constraints.pl", "scheduler.pl"]:
    _reset_stuck_query()
    list(prolog.query(f"consult('{PROLOG_DIR / _pl_file}')"))
_reset_stuck_query()


def _query(goal: str) -> list[dict]:
    """Run a Prolog goal safely under a mutex."""
    with _lock:
        _reset_stuck_query()
        try:
            return list(prolog.query(goal))
        except Exception as exc:
            _reset_stuck_query()
            raise RuntimeError(f"Prolog query failed: {goal!r}\n{exc}") from exc


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def generate_schedule(weekly_request_terms: list[str]) -> dict:
    """
    Call scheduler:generate_schedule/3 and return parsed result.

    weekly_request_terms: Prolog term strings produced by llm_parser, e.g.
      ["add_deadline(dm_tasks, 2)", "set_weather(monday, good)"]

    Returns:
      { "schedule": [...], "warnings": [...], "stats": {...} }
    """
    request_list = "[" + ", ".join(weekly_request_terms) + "]"

    results = _query(
        f"once(scheduler:generate_schedule({request_list}, Schedule, Warnings))"
    )

    if not results:
        return {"schedule": [], "warnings": ["Prolog returned no solution."], "stats": {}}

    solution   = results[0]
    schedule   = _parse_schedule(solution.get("Schedule", []))
    warnings   = [str(w) for w in solution.get("Warnings", [])]

    # Stats — separate query so we don't pass raw Prolog terms back in
    stats = _fetch_stats(schedule)

    return {"schedule": schedule, "warnings": warnings, "stats": stats}


def all_schedules(weekly_request_terms: list[str]) -> dict:
    """
    Call scheduler:all_schedules/3 and return all valid solutions.
    Returns up to ~10 schedules for Next/Prev navigation.
    """
    request_list = "[" + ", ".join(weekly_request_terms) + "]"

    results = _query(
        f"scheduler:all_schedules({request_list}, AllSchedules, Warnings)"
    )

    if not results:
        return {"schedules": [], "warnings": ["No schedules found."], "count": 0}

    solution  = results[0]
    all_raw   = solution.get("AllSchedules", [])
    warnings  = [str(w) for w in solution.get("Warnings", [])]
    schedules = [_parse_schedule(s) for s in all_raw]

    return {"schedules": schedules, "warnings": warnings, "count": len(schedules)}


def _fetch_stats(schedule: list[dict]) -> dict:
    """
    Compute stats from the already-parsed Python schedule list,
    avoiding the need to pass Prolog terms back into Prolog.
    """
    uni_subjects = {
        "math_analysis", "linear_algebra", "discrete_math", "algorithms",
        "kotlin", "prog_paradigms", "project_seminar", "jb_horizons",
        "discrete_upsolve", "la_plus_plus",
    }
    physical_subjects = {"gym", "tennis", "hike", "food_after_gym"}
    study_subjects = {
        "ma_hw", "la_hw", "dm_tasks", "dm_theory", "ma_theory",
        "algo_hw", "kotlin_hw", "kotlin_lecture", "prog_hw", "te_jb_hw",
    }

    def minutes(ev: dict) -> int:
        try:
            sh = _time_to_decimal(ev["start"])
            eh = _time_to_decimal(ev["end"])
            return max(0, round((eh - sh) * 60))
        except Exception:
            return 0

    uni_min      = sum(minutes(e) for e in schedule if e["subject"] in uni_subjects)
    physical_min = sum(minutes(e) for e in schedule if e["subject"] in physical_subjects)
    study_min    = sum(minutes(e) for e in schedule if e["subject"] in study_subjects)
    sleep_min    = 7 * (8 * 60 + 20)
    total_min    = 7 * 24 * 60
    free_min     = max(0, total_min - sleep_min - uni_min - study_min - physical_min)

    return {
        "university_minutes": uni_min,
        "study_minutes":      study_min,
        "physical_minutes":   physical_min,
        "free_minutes":       free_min,
        "sleep_minutes":      sleep_min,
    }


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def _parse_schedule(schedule_raw) -> list[dict]:
    events = []
    if not schedule_raw:
        return events
    for term in schedule_raw:
        try:
            ev = _parse_event_term(term)
            if ev:
                events.append(ev)
        except Exception:
            continue
    return events


import re as _re

_EVENT_RE = _re.compile(
    r"event\(\s*(\w+)\s*,\s*(\w+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([^,]+?)\s*,\s*(\w+)\s*\)"
)

def _parse_event_term(term) -> dict | None:
    """
    Parse an event term.
    pyswip 0.3.x returns compound terms as strings:
      "event(math_analysis, monday, 9.0, 10.5, #4285F4, fixed)"
    """
    try:
        s = str(term)
        m = _EVENT_RE.match(s)
        if not m:
            return None

        subject = m.group(1)
        day     = m.group(2)
        start_h = float(m.group(3))
        end_h   = float(m.group(4))
        color   = m.group(5).strip("'\"")
        etype   = m.group(6)

        return {
            "subject": subject,
            "label":   _subject_label(subject),
            "day":     day,
            "start":   _decimal_to_time(start_h),
            "end":     _decimal_to_time(end_h),
            "color":   color,
            "type":    etype,
        }
    except Exception:
        return None


def _decimal_to_time(decimal_hour: float) -> str:
    """9.5  →  '09:30'"""
    h = int(decimal_hour)
    m = round((decimal_hour - h) * 60)
    return f"{h:02d}:{m:02d}"


def _time_to_decimal(time_str: str) -> float:
    """'09:30'  →  9.5"""
    h, m = time_str.split(":")
    return int(h) + int(m) / 60.0


SUBJECT_LABELS = {
    "math_analysis":    "Math Analysis",
    "linear_algebra":   "Linear Algebra",
    "discrete_math":    "Discrete Math",
    "algorithms":       "Algorithms",
    "kotlin":           "Kotlin",
    "prog_paradigms":   "Prog Paradigms",
    "project_seminar":  "Project Seminar",
    "jb_horizons":      "JB Horizons",
    "discrete_upsolve": "Discrete Upsolve",
    "la_plus_plus":     "LA++",
    "ma_hw":            "MA Homework",
    "la_hw":            "LA Homework",
    "dm_tasks":         "DM HW",
    "dm_theory":        "DM Theory",
    "ma_theory":        "MA Theory",
    "algo_hw":          "Algo HW",
    "kotlin_hw":        "Kotlin HW",
    "kotlin_lecture":   "Kotlin Lecture",
    "prog_hw":          "Prog HW",
    "te_jb_hw":         "TE/JB HW",
    "gym":              "Gym",
    "food_after_gym":   "Food",
    "tennis":           "Tennis",
    "hike":             "Hike",
    "the_hub":          "The HUB",
    "mafia":            "Mafia",
    "migration_office": "Migration Office",
}


def _subject_label(subject: str) -> str:
    return SUBJECT_LABELS.get(subject, subject.replace("_", " ").title())
